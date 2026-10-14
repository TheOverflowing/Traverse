import Foundation

public struct ApplicationLaunchSession: Codable, Sendable {
    public let id: String
    public let applicationID: String
    public let applicationName: String
    public let startedAt: Date
    public let prefixPath: String
    public let launcherPID: Int32
    public let logPath: String
    public let msync: Bool?
    public let graphicsBackend: GraphicsBackend?
}

public actor WindowsApplicationRuntime {
    private let steam: SteamRuntime
    private let graphics: GraphicsProfiles
    private let java: JavaRuntime
    private let dotnet: DotNetRuntime
    public nonisolated let paths: TraversePaths
    private var processes: [String: Process] = [:]
    private var preparations: [String: Task<Void, Error>] = [:]

    public init(steam: SteamRuntime = SteamRuntime()) {
        self.steam = steam
        paths = steam.paths
        graphics = GraphicsProfiles(paths: steam.paths)
        java = JavaRuntime(paths: steam.paths)
        dotnet = DotNetRuntime(paths: steam.paths)
    }

    public func graphicsProfile(for application: LauncherApplication) async throws -> GraphicsProfile? {
        try await graphics.profile(for: application)
    }

    public func directKeyboardInput(for application: LauncherApplication) throws -> Bool {
        try TraverseSettings.load(from: paths).directKeyboardApplications.contains(application.id)
    }

    public func setDirectKeyboardInput(_ enabled: Bool, for application: LauncherApplication) throws {
        var settings = try TraverseSettings.load(from: paths)
        if enabled { settings.directKeyboardApplications.insert(application.id) }
        else { settings.directKeyboardApplications.remove(application.id) }
        try settings.save(to: paths)
    }

    public func setGraphicsBackend(_ backend: GraphicsBackend, for application: LauncherApplication,
                                   targetExecutable: URL? = nil,
                                   progress: @escaping @Sendable (String) async -> Void = { _ in }) async throws -> GraphicsProfile {
        let status = try await steam.status()
        let engine = WineEngine(wine: URL(fileURLWithPath: status.enginePath), msync: status.msync)
        guard engine.installed else { throw TraverseError.message("Install or select a Wine engine first.") }
        try GraphicsSupport.validate(backend: backend, engine: engine)
        try await prepare(prefix: URL(fileURLWithPath: application.prefixPath, isDirectory: true), engine: engine, progress: progress)
        return try await graphics.setBackend(backend, for: application, targetExecutable: targetExecutable,
            engine: engine, progress: progress)
    }

    public func launch(_ application: LauncherApplication, debug: Bool = false, requireNewProcess: Bool = false,
                       progress: @escaping @Sendable (String) async -> Void = { _ in },
                       onExit: @escaping @Sendable (Int32, String) async -> Void = { _, _ in }) async throws -> ApplicationLaunchSession {
        try paths.prepare()
        guard let executablePath = application.executablePath,
              FileManager.default.fileExists(atPath: executablePath) else {
            throw TraverseError.message("This application could not be found. Add its current location to the launcher.")
        }
        var status = try await steam.status()
        if !status.engineInstalled {
            try await steam.installEngine(progress: progress)
            status = try await steam.status()
        }
        let engine = WineEngine(wine: URL(fileURLWithPath: status.enginePath), msync: status.msync)
        let prefix = URL(fileURLWithPath: application.prefixPath, isDirectory: true)
        try await prepare(prefix: prefix, engine: engine, progress: progress)
        try await steam.prepareDisplayCompatibility(for: application, engine: engine)
        if let activation = try await ApplicationActivation.activate(application, engine: engine, paths: paths) {
            if requireNewProcess {
                throw TraverseError.message("This application is already running. Close it before launching with --wait.")
            }
            let session = ApplicationLaunchSession(id: UUID().uuidString.lowercased(), applicationID: application.id,
                applicationName: application.name, startedAt: Date(), prefixPath: prefix.path,
                launcherPID: activation.result.pid, logPath: activation.log.path, msync: engine.msync,
                graphicsBackend: nil)
            try save(session)
            return session
        }
        let graphicsProfile = try await graphics.launchProfile(for: application, engine: engine)
        let javaExecutable = URL(fileURLWithPath: executablePath).pathExtension.lowercased() == "jar"
            ? try await java.executable(progress: progress) : nil
        if (application.kind == .steam || application.kind == .steamGame),
           application.prefixPath == paths.prefix.path {
            let session = try await steam.launch(arguments: application.arguments, debug: debug,
                graphicsBackend: graphicsProfile?.backend, progress: progress)
            return ApplicationLaunchSession(id: session.id, applicationID: application.id,
                applicationName: application.name, startedAt: session.startedAt,
                prefixPath: session.prefixPath, launcherPID: session.launcherPID, logPath: session.logPath,
                msync: session.msync, graphicsBackend: graphicsProfile?.backend)
        }
        let dotnetDirectory = DotNetRuntime.isSupportedApplication(URL(fileURLWithPath: executablePath))
            ? try await dotnet.prepare(progress: progress) : nil
        await progress("Opening \(application.name)…")
        let id = UUID().uuidString.lowercased()
        let log = paths.logs.appendingPathComponent("application-\(id).log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let output = try FileHandle(forWritingTo: log)
        defer { try? output.close() }
        let process = Process()
        process.executableURL = engine.wine
        if let javaExecutable {
            process.arguments = try JavaRuntime.arguments(java: javaExecutable,
                archive: URL(fileURLWithPath: executablePath), prefix: prefix, arguments: application.arguments,
                fontDirectory: engine.wine.deletingLastPathComponent().deletingLastPathComponent()
                    .appendingPathComponent("share/wine/fonts", isDirectory: true),
                textFont: try WindowsTextFont.resolve(TraverseSettings.load(from: paths).windowsTextFont))
        } else {
            process.arguments = Self.arguments(for: application)
        }
        var environment = engine.environment(prefix: prefix, debug: debug)
        if let dotnetDirectory {
            guard let windowsDirectory = ApplicationActivation.windowsPath(for: dotnetDirectory, prefix: prefix) else {
                throw TraverseError.message("The .NET runtime is outside this Windows environment's mapped drives.")
            }
            environment["DOTNET_ROOT_X64"] = windowsDirectory
        }
        environment.merge(try await ApplicationDockIdentity.environment(for: application, engine: engine,
            paths: paths)) { _, identity in identity }
        // Desktop launchers can create a rendering process beside their own executable.
        // Keep the override within this application family; Steam uses target AppDefaults.
        if let graphicsProfile, application.kind == .executable || application.kind == .shortcut {
            environment["WINEDLLOVERRIDES"] = graphicsProfile.backend.environmentOverrides
        }
        FrameRateLimit.apply(status.frameRateLimit, to: &environment)
        process.environment = environment
        process.currentDirectoryURL = application.workingDirectory.map { URL(fileURLWithPath: $0) }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
        process.terminationHandler = { finished in
            let status = finished.terminationStatus
            Task {
                await self.finished(id)
                await onExit(status, log.path)
            }
        }
        try process.run()
        processes[id] = process
        let session = ApplicationLaunchSession(id: id, applicationID: application.id,
            applicationName: application.name, startedAt: Date(), prefixPath: prefix.path,
            launcherPID: process.processIdentifier, logPath: log.path, msync: engine.msync,
            graphicsBackend: graphicsProfile?.backend)
        try save(session)
        return session
    }

    static func arguments(for application: LauncherApplication) -> [String] {
        guard let path = application.executablePath else { return [] }
        if application.kind == .shortcut { return ["start", "/unix", path] + application.arguments }
        if URL(fileURLWithPath: path).pathExtension.lowercased() == "msi" {
            return ["msiexec", "/i", path] + application.arguments
        }
        return [path] + application.arguments
    }

    private func finished(_ id: String) { processes.removeValue(forKey: id) }

    private func save(_ session: ApplicationLaunchSession) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(session).write(to: URL(fileURLWithPath: session.logPath)
            .deletingPathExtension().appendingPathExtension("json"), options: .atomic)
    }

    private func prepare(prefix: URL, engine: WineEngine,
                         progress: @escaping @Sendable (String) async -> Void) async throws {
        try await MSyncEngine.prepareGraphics(for: engine, progress: progress)
        if let preparation = preparations[prefix.path] { return try await preparation.value }
        let ready = prefix.appendingPathComponent(".traverse-ready")
        let needsInitialization = !FileManager.default.fileExists(atPath: ready.path)
            && !FileManager.default.fileExists(atPath: prefix.appendingPathComponent("system.reg").path)
        let log = paths.logs.appendingPathComponent("windows-environment-\(UUID().uuidString).log")
        let preparation = Task {
            try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
            if needsInitialization {
                for arguments in [["wineboot", "--init"],
                                  ["reg", "add", "HKCU\\Software\\Wine", "/v", "Version", "/t", "REG_SZ", "/d", "win10", "/f"]] {
                    let result = try await ProcessRunner.run(executable: engine.wine, arguments: arguments,
                        environment: engine.environment(prefix: prefix), log: log)
                    guard result.status == 0 else {
                        throw TraverseError.message("The Windows environment could not be prepared (exit \(result.status)). Open \(log.lastPathComponent) for details.")
                    }
                }
                // Wine can defer writing system.reg until its processes exit.
                try Data("Windows environment initialized\n".utf8).write(to: ready, options: .atomic)
            }
            try await steam.prepareWindowsSupport(prefix: prefix, engine: engine, progress: progress)
        }
        // Publish the shared task before yielding to a progress callback or another launch.
        preparations[prefix.path] = preparation
        defer { preparations.removeValue(forKey: prefix.path) }
        await progress("Preparing the Windows environment…")
        try await preparation.value
    }
}
