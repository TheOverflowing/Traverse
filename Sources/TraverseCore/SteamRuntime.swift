import Foundation

public struct RuntimeStatus: Codable, Sendable {
    public let engineInstalled: Bool
    public let steamInstalled: Bool
    public let enginePath: String
    public let prefixPath: String
    public let rendering: SteamRendering
    public let msync: Bool
    public var graphicsBackend: GraphicsBackend = .automatic
    public var frameRateLimit: Int? = nil
    public var windowsTextFont: String? = nil
    public var retinaMode = false
}

public struct LaunchSession: Codable, Sendable {
    public let id: String
    public let startedAt: Date
    public let engineVersion: String
    public let enginePath: String
    public let prefixPath: String
    public let rendering: SteamRendering
    public let arguments: [String]
    public let launcherPID: Int32
    public let logPath: String
    public let msync: Bool?
    public let graphicsBackend: GraphicsBackend?
}

public actor SteamRuntime {
    public nonisolated let paths: TraversePaths
    private var launchedProcess: Process?
    private var enginePreparation: Task<Void, Error>?
    private var gamePreparation: Task<Void, Error>?
    private let textSupport: WindowsTextSupport
    private let displaySupport: WindowsDisplaySupport

    public init(paths: TraversePaths = TraversePaths()) {
        self.paths = paths
        textSupport = WindowsTextSupport(paths: paths)
        displaySupport = WindowsDisplaySupport(paths: paths)
    }

    public func setFusionMode(_ enabled: Bool) throws {
        var settings = try TraverseSettings.load(from: paths)
        settings.fusionMode = enabled
        try settings.save(to: paths)
    }

    func prepareWindowsSupport(prefix: URL, engine: WineEngine,
                            progress: @escaping @Sendable (String) async -> Void) async throws {
        let settings = try TraverseSettings.load(from: paths)
        try await displaySupport.prepare(prefix: prefix, engine: engine, retinaMode: settings.retinaMode)
        let font = try WindowsTextFont.resolve(settings.windowsTextFont)
        try await textSupport.prepare(prefix: prefix, engine: engine, font: font, progress: progress)
    }

    public func setRetinaMode(_ enabled: Bool) throws {
        var settings = try TraverseSettings.load(from: paths)
        settings.retinaMode = enabled
        try settings.save(to: paths)
    }

    func prepareDisplayCompatibility(for application: LauncherApplication, engine: WineEngine) async throws {
        try await displaySupport.prepareApplication(application, engine: engine)
    }

    public func setWindowsTextFont(_ identifier: String?,
                                   progress: @escaping @Sendable (String) async -> Void = { _ in }) async throws {
        _ = try WindowsTextFont.resolve(identifier)
        var settings = try TraverseSettings.load(from: paths)
        settings.windowsTextFont = identifier
        try settings.save(to: paths)
        if selectedEngine(settings).installed { try await prepareChineseText(progress: progress) }
    }

    public func prepareChineseText(progress: @escaping @Sendable (String) async -> Void = { _ in }) async throws {
        try paths.prepare()
        let engine = selectedEngine(try TraverseSettings.load(from: paths))
        guard engine.installed else { throw TraverseError.message("Install the Wine engine first.") }
        let library = ApplicationLibrary(paths: paths)
        let prefixes = Set(try library.applications().map { $0.prefixPath })
            .union(library.managedPrefixes().map { $0.path })
        for path in prefixes.sorted() {
            let prefix = URL(fileURLWithPath: path, isDirectory: true)
            guard FileManager.default.fileExists(atPath: prefix.appendingPathComponent("system.reg").path) else { continue }
            try await prepareWindowsSupport(prefix: prefix, engine: engine, progress: progress)
        }
    }

    public func status() throws -> RuntimeStatus {
        let settings = try TraverseSettings.load(from: paths)
        let engine = selectedEngine(settings)
        return RuntimeStatus(engineInstalled: engine.installed,
            steamInstalled: FileManager.default.fileExists(atPath: paths.steam.path),
            enginePath: engine.wine.path, prefixPath: paths.prefix.path, rendering: settings.rendering,
            msync: settings.msync, graphicsBackend: settings.graphicsBackend,
            frameRateLimit: settings.frameRateLimit, windowsTextFont: settings.windowsTextFont,
            retinaMode: settings.retinaMode)
    }

    public func setRendering(_ rendering: SteamRendering) throws {
        var settings = try TraverseSettings.load(from: paths)
        settings.rendering = rendering
        try settings.save(to: paths)
    }

    public func setGraphicsBackend(_ backend: GraphicsBackend) throws {
        var settings = try TraverseSettings.load(from: paths)
        try GraphicsSupport.validate(backend: backend, engine: selectedEngine(settings))
        settings.graphicsBackend = backend
        try settings.save(to: paths)
    }

    public func setFrameRateLimit(_ limit: Int?) throws {
        try FrameRateLimit.validate(limit)
        var settings = try TraverseSettings.load(from: paths)
        settings.frameRateLimit = limit
        try settings.save(to: paths)
    }

    public func gameSupportStatus() -> GameSupportStatus {
        BadEndTheaterSupport.status(in: paths)
    }

    public func installGameSupport(progress: @Sendable (String) async -> Void = { _ in }) async throws {
        let engine = selectedEngine(try TraverseSettings.load(from: paths))
        try await BadEndTheaterSupport.install(in: paths, engine: engine, progress: progress)
    }

    func prepareGameCompatibility(engine: WineEngine,
                                  progress: @escaping @Sendable (String) async -> Void) async throws {
        if let gamePreparation { return try await gamePreparation.value }
        let status = BadEndTheaterSupport.status(in: paths)
        guard status.gameInstalled, !status.supportInstalled else { return }
        let preparation = Task {
            let executable = BadEndTheaterSupport.gameDirectory(in: paths).appendingPathComponent("badendtheater.exe")
            let profiles = GraphicsProfiles(paths: paths)
            // A manually selected backend takes precedence over the default game fix.
            guard try await !profiles.hasAlternateGameBackend(executable: executable, prefix: paths.prefix) else { return }
            try await BadEndTheaterSupport.install(in: paths, engine: engine, progress: progress)
        }
        gamePreparation = preparation
        defer { gamePreparation = nil }
        try await preparation.value
    }

    public func setEngine(_ wine: URL?) throws {
        let engine = wine.map { WineEngine(wine: $0) }
        if let engine, !engine.installed {
            throw TraverseError.message("Choose a Wine executable with wineserver in the same folder.")
        }
        var settings = try TraverseSettings.load(from: paths)
        settings.customWine = wine?.path
        settings.msync = engine?.supportsMSync ?? true
        try settings.save(to: paths)
    }

    public func setMSync(_ enabled: Bool) throws {
        var settings = try TraverseSettings.load(from: paths)
        if enabled && !selectedEngine(settings).supportsMSync {
            throw TraverseError.message("Install an MSync engine before enabling fast synchronization.")
        }
        settings.msync = enabled
        try settings.save(to: paths)
    }

    public func installMSyncEngine(progress: @Sendable (String) async -> Void) async throws {
        let engine = try await MSyncEngine.install(in: paths, progress: progress)
        var settings = try TraverseSettings.load(from: paths)
        settings.customWine = engine.wine.path
        settings.msync = true
        try settings.save(to: paths)
    }

    public func installEngine(progress: @escaping @Sendable (String) async -> Void) async throws {
        if let preparation = enginePreparation { return try await preparation.value }
        let preparation = Task {
            let settings = try TraverseSettings.load(from: paths)
            if let customWine = settings.customWine {
                guard WineEngine(wine: URL(fileURLWithPath: customWine)).installed else {
                    throw TraverseError.message("The selected Wine engine is missing. Choose another engine.")
                }
                try await MSyncEngine.prepareGraphics(for: selectedEngine(settings), progress: progress)
            } else {
                _ = try await MSyncEngine.install(in: paths, progress: progress)
            }
            try await checkRosetta()
            let engine = selectedEngine(settings)
            _ = try await version(of: engine)
        }
        enginePreparation = preparation
        defer { enginePreparation = nil }
        try await preparation.value
    }

    public func installSteam(progress: @escaping @Sendable (String) async -> Void) async throws {
        try await installEngine(progress: progress)
        if FileManager.default.fileExists(atPath: paths.steam.path) { return }
        let engine = selectedEngine(try TraverseSettings.load(from: paths))
        try FileManager.default.createDirectory(at: paths.prefix, withIntermediateDirectories: true)
        await progress("Creating Steam’s Windows environment…")
        try await checkedWine(engine, arguments: ["wineboot", "--init"], name: "steam-prefix")
        try await checkedWine(engine,
            arguments: ["reg", "add", "HKCU\\Software\\Wine", "/v", "Version", "/t", "REG_SZ", "/d", "win10", "/f"],
            name: "steam-windows-version")
        try await prepareWindowsSupport(prefix: paths.prefix, engine: engine, progress: progress)
        let installer = paths.downloads.appendingPathComponent("SteamSetup.exe")
        if !FileManager.default.fileExists(atPath: installer.path) {
            await progress("Downloading Steam…")
            try await WineEngine.download(
                URL(string: "https://cdn.akamai.steamstatic.com/client/installer/SteamSetup.exe")!,
                to: installer)
        }
        await progress("Installing Steam…")
        try await checkedWine(engine, arguments: [installer.path, "/S"], name: "steam-install")
        guard FileManager.default.fileExists(atPath: paths.steam.path) else {
            throw TraverseError.message("Steam setup finished without installing Steam. Open the install log for details.")
        }
        await progress("Steam is installed")
    }

    public func launch(arguments additionalArguments: [String] = [], debug: Bool = false,
                       graphicsBackend: GraphicsBackend? = nil,
                       progress: @escaping @Sendable (String) async -> Void = { _ in }) async throws -> LaunchSession {
        try paths.prepare()
        let settings = try TraverseSettings.load(from: paths)
        let engine = selectedEngine(settings)
        guard engine.installed else { throw TraverseError.message("Install the Wine engine first.") }
        guard FileManager.default.fileExists(atPath: paths.steam.path) else {
            throw TraverseError.message("Install Steam first.")
        }
        try await MSyncEngine.prepareGraphics(for: engine, progress: progress)
        try await prepareWindowsSupport(prefix: paths.prefix, engine: engine, progress: progress)
        try await prepareGameCompatibility(engine: engine, progress: progress)
        let running = try await isRunning(engine: engine)
        if running {
            await progress("Opening Steam…")
        } else if settings.rendering == .software {
            await progress("Checking Steam updates…")
            try restoreSteamHelper()
            let bootstrapOffset = (try? Data(contentsOf: bootstrapLog).count) ?? 0
            let update = try await ProcessRunner.run(executable: engine.wine,
                arguments: [paths.steam.path, "-exitsteam"],
                environment: engine.environment(prefix: paths.prefix),
                directory: paths.steam.deletingLastPathComponent(),
                log: paths.logs.appendingPathComponent("steam-update.log"))
            // Steam uses exit 254 for the successful -exitsteam path.
            guard update.status == 0 || update.status == 254 else {
                throw TraverseError.message("Steam's update check failed (exit \(update.status)). Open steam-update.log for details.")
            }
            await progress("Preparing Steam’s interface…")
            try await waitForSteamHelper(bootstrapOffset: bootstrapOffset)
            try installSteamHelper()
        } else {
            try restoreSteamHelper()
        }
        let engineVersion = try await version(of: engine)
        let id = UUID().uuidString.lowercased()
        let log = paths.logs.appendingPathComponent("steam-\(id).log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let output = try FileHandle(forWritingTo: log)
        defer { try? output.close() }
        let arguments = running
            ? [paths.steam.path] + (additionalArguments.isEmpty ? ["steam://open/main"] : additionalArguments)
            : [paths.steam.path] + settings.rendering.arguments
                + (settings.rendering == .software ? ["-skipinitialbootstrap"] : []) + additionalArguments
        let process = Process()
        process.executableURL = engine.wine
        process.arguments = arguments
        var environment = engine.environment(prefix: paths.prefix, debug: debug)
        let application = LauncherApplication(id: "steam", name: "Steam", kind: .steam,
            executablePath: paths.steam.path, prefixPath: paths.prefix.path)
        environment.merge(try await ApplicationDockIdentity.environment(for: application, engine: engine,
            paths: paths)) { _, identity in identity }
        // Games started from Steam inherit this environment.
        FrameRateLimit.apply(settings.frameRateLimit, to: &environment)
        process.environment = environment
        process.currentDirectoryURL = paths.steam.deletingLastPathComponent()
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice
        try process.run()
        launchedProcess = process
        let session = LaunchSession(id: id, startedAt: Date(), engineVersion: engineVersion,
            enginePath: engine.wine.path, prefixPath: paths.prefix.path,
            rendering: settings.rendering, arguments: arguments,
            launcherPID: process.processIdentifier, logPath: log.path, msync: engine.msync,
            graphicsBackend: graphicsBackend)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(session)
        try data.write(to: paths.logs.appendingPathComponent("steam-\(id).json"), options: .atomic)
        try data.write(to: paths.logs.appendingPathComponent("latest-session.json"), options: .atomic)
        return session
    }

    private func isRunning(engine: WineEngine) async throws -> Bool {
        if let launchedProcess, launchedProcess.isRunning { return true }
        let log = paths.logs.appendingPathComponent("steam-processes.log")
        let result = try await ProcessRunner.run(executable: engine.wine,
            arguments: ["tasklist", "/fi", "IMAGENAME eq steam.exe", "/fo", "csv", "/nh"],
            environment: engine.environment(prefix: paths.prefix), log: log)
        guard result.status == 0 else {
            throw TraverseError.message("Could not check whether Steam is running. Open steam-processes.log for details.")
        }
        let output = try String(contentsOf: log, encoding: .utf8)
        return output.split(whereSeparator: \.isNewline).contains {
            $0.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("\"steam.exe\",")
        }
    }

    private var helper: URL {
        paths.steam.deletingLastPathComponent()
            .appendingPathComponent("bin/cef/cef.win64/steamwebhelper.exe")
    }

    private var originalHelper: URL {
        helper.deletingLastPathComponent().appendingPathComponent("steamwebhelper_original.exe")
    }

    private func restoreSteamHelper() throws {
        let files = FileManager.default
        if files.fileExists(atPath: originalHelper.path) {
            // The original is restored before Valve's updater verifies or changes files.
            try files.copyItem(at: originalHelper, to: helper.appendingPathExtension("restore"))
            _ = try files.replaceItemAt(helper, withItemAt: helper.appendingPathExtension("restore"))
            try files.removeItem(at: originalHelper)
        }
    }

    private var bootstrapLog: URL {
        paths.steam.deletingLastPathComponent().appendingPathComponent("logs/bootstrap_log.txt")
    }

    private func waitForSteamHelper(bootstrapOffset: Int) async throws {
        // The small Steam installer can restart into the full updater. Its first
        // process may exit while the child is still extracting the client.
        let deadline = ContinuousClock.now.advanced(by: .seconds(600))
        while true {
            if let data = try? Data(contentsOf: bootstrapLog) {
                let newData = data.count >= bootstrapOffset ? data.dropFirst(bootstrapOffset) : data[...]
                var phase = String(decoding: newData, as: UTF8.self)
                if let startup = phase.range(of: "Startup - Steam Client launched", options: .backwards) {
                    phase = String(phase[startup.lowerBound...])
                }
                if let verification = phase.range(of: "Verification complete", options: .backwards),
                   phase[verification.upperBound...].contains("Shutdown"),
                   FileManager.default.fileExists(atPath: helper.path) { return }
            }
            guard ContinuousClock.now < deadline else {
                throw TraverseError.message("Steam is still preparing its client. Check steam-update.log, then launch again.")
            }
            try await Task.sleep(for: .seconds(1))
        }
    }

    private func installSteamHelper() throws {
        guard let bridge = Bundle.module.url(forResource: "steamwebhelper-bridge", withExtension: "exe",
                                              subdirectory: "Resources") else {
            throw TraverseError.message("The Steam interface helper is missing. Rebuild Traverse with scripts/build-app.sh.")
        }
        let files = FileManager.default
        try files.copyItem(at: helper, to: originalHelper)
        do {
            let replacement = helper.appendingPathExtension("new")
            try files.copyItem(at: bridge, to: replacement)
            _ = try files.replaceItemAt(helper, withItemAt: replacement)
        } catch {
            try? files.removeItem(at: originalHelper)
            throw error
        }
    }

    public func stop() async throws {
        guard FileManager.default.fileExists(atPath: paths.prefix.path) else { return }
        let engine = selectedEngine(try TraverseSettings.load(from: paths))
        guard engine.installed else { throw TraverseError.message("The selected engine is missing.") }
        // WINEPREFIX scopes wineserver -k to Traverse's Steam environment.
        let result = try await ProcessRunner.run(executable: engine.server, arguments: ["-k"],
            environment: engine.environment(prefix: paths.prefix),
            log: paths.logs.appendingPathComponent("steam-stop.log"))
        guard result.status == 0 else {
            throw TraverseError.message("Steam could not be stopped. Open the stop log for details.")
        }
        launchedProcess = nil
    }

    public func doctor() async throws -> [String: String] {
        try paths.prepare()
        let status = try status()
        var values = ["platform": "\(ProcessInfo.processInfo.operatingSystemVersionString)",
                      "engine": status.enginePath, "prefix": status.prefixPath,
                      "engineInstalled": String(status.engineInstalled),
                      "steamInstalled": String(status.steamInstalled),
                      "steamRendering": status.rendering.rawValue]
        #if arch(arm64)
        values["architecture"] = "arm64"
        #else
        values["architecture"] = "x86_64"
        #endif
        do { try await checkRosetta(); values["x86_64Execution"] = "available" }
        catch { values["x86_64Execution"] = error.localizedDescription }
        if status.engineInstalled {
            let engine = selectedEngine(try TraverseSettings.load(from: paths))
            values["wineVersion"] = try await version(of: engine)
        }
        return values
    }

    private func selectedEngine(_ settings: TraverseSettings) -> WineEngine {
        let wine = settings.customWine.map { URL(fileURLWithPath: $0) } ?? MSyncEngine.engine(in: paths).wine
        return WineEngine(wine: wine, msync: settings.msync)
    }

    private func checkRosetta() async throws {
        let result = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/arch"),
            arguments: ["-x86_64", "/usr/bin/true"], log: paths.logs.appendingPathComponent("rosetta.log"))
        guard result.status == 0 else {
            throw TraverseError.message("Install Rosetta in Terminal: softwareupdate --install-rosetta")
        }
    }

    private func version(of engine: WineEngine) async throws -> String {
        let log = paths.logs.appendingPathComponent("wine-version.log")
        let result = try await ProcessRunner.run(executable: engine.wine, arguments: ["--version"],
            environment: engine.environment(prefix: paths.prefix), log: log)
        guard result.status == 0 else {
            let detail = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            throw TraverseError.message("Wine could not start. \(detail.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return try String(contentsOf: log, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func checkedWine(_ engine: WineEngine, arguments: [String], name: String) async throws {
        let log = paths.logs.appendingPathComponent("\(name).log")
        let result = try await ProcessRunner.run(executable: engine.wine, arguments: arguments,
            environment: engine.environment(prefix: paths.prefix), log: log)
        guard result.status == 0 else {
            throw TraverseError.message("\(name) failed (exit \(result.status)). Open \(log.lastPathComponent) for details.")
        }
    }
}
