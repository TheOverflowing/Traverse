import CryptoKit
import Foundation

public enum GraphicsBackend: String, Codable, CaseIterable, Sendable {
    case automatic = "auto"
    case d3dmetal
    case dxmt
    case dxvk
    case wine

    public var title: String {
        switch self {
        case .automatic: "Auto"
        case .wine: "Wine"
        case .dxvk: "DXVK"
        case .dxmt: "DXMT"
        case .d3dmetal: "D3DMetal"
        }
    }

    var libraryNames: [String] {
        switch self {
        case .automatic, .wine: []
        case .dxvk: ["d3d11.dll", "d3d10core.dll"]
        case .dxmt: ["d3d11.dll", "d3d10core.dll", "dxgi.dll", "winemetal.dll"]
        case .d3dmetal: ["d3d10.dll", "d3d11.dll", "d3d12.dll", "dxgi.dll", "tdxg.dll"]
        }
    }

    var environmentOverrides: String {
        switch self {
        case .automatic, .wine: "d3d11,d3d10core,dxgi,winemetal=b"
        case .dxvk: "d3d11,d3d10core=n,b;dxgi,winemetal=b"
        case .dxmt: "d3d11,d3d10core,dxgi=n,b;winemetal=b"
        case .d3dmetal: "d3d10,d3d11,d3d12,dxgi=n,b;d3d10core,winemetal=b"
        }
    }
}

public struct GraphicsProfile: Codable, Sendable, Equatable {
    public let applicationID: String
    public let backend: GraphicsBackend
    public let executablePath: String
    public let prefixPath: String
    public let fileHashes: [String: String]
    public let graphicsOverlayID: String?
    public let requestedBackend: GraphicsBackend?
    public var selection: GraphicsBackend { requestedBackend ?? backend }

    public init(applicationID: String, backend: GraphicsBackend, executablePath: String,
                prefixPath: String, fileHashes: [String: String], graphicsOverlayID: String? = nil,
                requestedBackend: GraphicsBackend? = nil) {
        self.applicationID = applicationID
        self.backend = backend
        self.executablePath = executablePath
        self.prefixPath = prefixPath
        self.fileHashes = fileHashes
        self.graphicsOverlayID = graphicsOverlayID
        self.requestedBackend = requestedBackend
    }
}

public actor GraphicsProfiles {
    public let paths: TraversePaths
    var store: URL { paths.root.appendingPathComponent("graphics-profiles.json") }

    public init(paths: TraversePaths) { self.paths = paths }

    public func profile(for application: LauncherApplication) throws -> GraphicsProfile? {
        try load()[application.id] ?? legacyProfile(for: application)
    }

    func compatibilityDXVKProfileUpdate(executable: URL, prefix: URL,
                                        previousHashes: [String: String], fileHashes: [String: String]) throws -> Data? {
        var profiles = try load()
        var changed = false
        let executablePath = canonical(executable).path
        let prefixPath = canonical(prefix).path
        for (id, profile) in profiles where profile.executablePath == executablePath && profile.prefixPath == prefixPath {
            guard profile.backend == .dxvk else {
                throw TraverseError.message("BAD END THEATER uses another graphics backend. Choose DXVK in Application Settings before enabling compatibility.")
            }
            guard profile.fileHashes == previousHashes else {
                throw TraverseError.message("BAD END THEATER's graphics files have changed. Reapply its graphics backend in Application Settings.")
            }
            // An Auto profile keeps its selection even if the global default
            // changed; this operation only upgrades its recorded DXVK files.
            profiles[id] = GraphicsProfile(applicationID: profile.applicationID, backend: .dxvk,
                executablePath: profile.executablePath, prefixPath: profile.prefixPath,
                fileHashes: fileHashes, graphicsOverlayID: DXVKSupport.id,
                requestedBackend: profile.requestedBackend)
            changed = true
        }
        guard changed else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(profiles)
    }

    public func setBackend(_ selection: GraphicsBackend, for application: LauncherApplication,
                           targetExecutable: URL? = nil, engine: WineEngine,
                           progress: @Sendable (String) async -> Void = { _ in }) async throws -> GraphicsProfile {
        try paths.prepare()
        guard engine.installed else { throw TraverseError.message("Install or select a Wine engine first.") }
        guard application.kind != .steam else {
            throw TraverseError.message("Choose a Windows application or game to configure its graphics backend.")
        }
        let previous = try profile(for: application)
        let executable = try target(for: application, requested: targetExecutable, previous: previous)
        let globalBackend = try TraverseSettings.load(from: paths).graphicsBackend
        let backend = try GraphicsSupport.resolve(selection, executable: executable, engine: engine, globalBackend: globalBackend)
        let prefix = canonical(URL(fileURLWithPath: application.prefixPath, isDirectory: true))
        let profiles = try load()
        let legacyExecutable = canonical(BadEndTheaterSupport.gameDirectory(in: paths).appendingPathComponent("badendtheater.exe"))
        if prefix == canonical(paths.prefix), executable != legacyExecutable,
           executable.lastPathComponent.lowercased() == legacyExecutable.lastPathComponent.lowercased(),
           FileManager.default.fileExists(atPath: legacyExecutable.path), legacyRecord() != nil {
            throw TraverseError.message("Another application in this Windows environment uses the same executable name. Configure it in a separate environment.")
        }
        for other in profiles.values where other.applicationID != application.id
            && other.prefixPath == prefix.path
            && URL(fileURLWithPath: other.executablePath).lastPathComponent.lowercased() == executable.lastPathComponent.lowercased() {
            if other.executablePath != executable.path || other.backend != backend {
                throw TraverseError.message("Another application in this Windows environment uses the same executable name. Configure it in a separate environment.")
            }
        }
        let payloads = try await GraphicsSupport.payloads(backend: backend, executable: executable,
            engine: engine, paths: paths, progress: progress)
        let adopted = previous ?? legacyProfile(for: application, target: executable)
        if let adopted, adopted.executablePath != executable.path, !adopted.fileHashes.isEmpty {
            throw TraverseError.message("Switch this application's graphics backend to Wine before choosing another executable.")
        }
        let directory = executable.deletingLastPathComponent()
        let previousHashes = adopted?.fileHashes ?? [:]
        let names = Set(previousHashes.keys).union(payloads.keys)
        var originalFiles: [String: Data] = [:]
        for name in names {
            let file = directory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            let current = try Data(contentsOf: file)
            originalFiles[name] = current
            if let desired = payloads[name], current == desired { continue }
            guard previousHashes[name] == Self.digest(current) else {
                throw TraverseError.message("\(application.name) has a different \(name). Its existing file was kept.")
            }
        }
        var overrides: [String: String]
        switch backend {
        case .automatic, .wine: overrides = ["d3d11": "builtin", "d3d10core": "builtin", "dxgi": "builtin", "winemetal": "builtin"]
        case .dxvk: overrides = ["d3d11": "native,builtin", "d3d10core": "native,builtin", "dxgi": "builtin", "winemetal": "builtin"]
        case .dxmt: overrides = ["d3d11": "native,builtin", "d3d10core": "native,builtin", "dxgi": "native,builtin", "winemetal": "builtin"]
        case .d3dmetal: overrides = ["d3d10": "native,builtin", "d3d11": "native,builtin", "d3d12": "native,builtin", "dxgi": "native,builtin", "d3d10core": "builtin", "winemetal": "builtin"]
        }
        if backend != .d3dmetal { overrides.merge(["d3d10": "builtin", "d3d12": "builtin"]) { _, new in new } }
        let key = "HKCU\\Software\\Wine\\AppDefaults\\\(executable.lastPathComponent)\\DllOverrides"
        var originalOverrides: [String: String] = [:]
        for name in overrides.keys.sorted() {
            originalOverrides[name] = try await registryValue(name, key: key, engine: engine, prefix: prefix)
        }
        let compatibilityURL = BadEndTheaterSupport.recordURL(in: paths)
        var compatibilityRecord: GameSupportRecord?
        var originalCompatibilityRecord: Data?
        var compatibilityRecordWritten = false
        if backend == .dxvk, prefix == canonical(paths.prefix), executable == legacyExecutable,
           let record = legacyRecord(), let environmentHash = record.fileHashes["environment.txt"],
           let environment = try? Data(contentsOf: directory.appendingPathComponent("environment.txt")),
           BadEndTheaterSupport.digest(environment) == environmentHash {
            originalCompatibilityRecord = try Data(contentsOf: compatibilityURL)
            var hashes = payloads.mapValues(Self.digest)
            hashes["environment.txt"] = environmentHash
            compatibilityRecord = GameSupportRecord(appID: record.appID, backendVersion: record.backendVersion,
                installedAt: Date(), fileHashes: hashes, graphicsOverlayID: DXVKSupport.id)
        }
        do {
            await progress("Configuring \(application.name)…")
            for name in names.sorted() {
                let file = directory.appendingPathComponent(name)
                if let data = payloads[name] { try data.write(to: file, options: .atomic) }
                else if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            }
            for (name, value) in overrides.sorted(by: { $0.key < $1.key }) {
                try await setRegistryValue(value, name: name, key: key, engine: engine, prefix: prefix)
            }
            let profile = GraphicsProfile(applicationID: application.id, backend: backend,
                executablePath: executable.path, prefixPath: prefix.path, fileHashes: payloads.mapValues(Self.digest),
                graphicsOverlayID: backend == .dxmt ? MSyncGraphicsOverlay.id
                    : backend == .d3dmetal ? D3DMetalSupport.overlayID
                    : backend == .dxvk ? DXVKSupport.id : nil,
                requestedBackend: selection == .automatic ? .automatic : nil)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let compatibilityRecord {
                try encoder.encode(compatibilityRecord).write(to: compatibilityURL, options: .atomic)
                compatibilityRecordWritten = true
            }
            var saved = try load()
            saved[application.id] = profile
            try encoder.encode(saved).write(to: store, options: .atomic)
            return profile
        } catch {
            let failure = error
            do {
                if compatibilityRecordWritten, let originalCompatibilityRecord {
                    try originalCompatibilityRecord.write(to: compatibilityURL, options: .atomic)
                }
                for name in names.sorted() {
                    let file = directory.appendingPathComponent(name)
                    if let data = originalFiles[name] { try data.write(to: file, options: .atomic) }
                    else if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
                }
                for name in overrides.keys.sorted() {
                    try await setRegistryValue(originalOverrides[name], name: name, key: key, engine: engine, prefix: prefix)
                }
            } catch {
                throw TraverseError.message("The graphics changes could not be fully restored. Reapply \(application.name)'s previous backend in Application Settings.")
            }
            throw failure
        }
    }

    public func launchProfile(for application: LauncherApplication, engine: WineEngine) async throws -> GraphicsProfile? {
        guard let profile = try profile(for: application) else {
            guard application.kind != .steam else { return nil }
            let global = try TraverseSettings.load(from: paths).graphicsBackend
            if global == .wine || (global == .automatic && !GraphicsSupport.supportsDXMT(engine: engine)) { return nil }
            let hasExecutable = application.kind == .executable
                && URL(fileURLWithPath: application.executablePath ?? "").pathExtension.lowercased() == "exe"
            guard hasExecutable || (application.kind == .steamGame && application.steamAppID == BadEndTheaterSupport.appID) else { return nil }
            let executable = try target(for: application, requested: nil, previous: nil)
            let backend = try GraphicsSupport.resolve(.automatic, executable: executable, engine: engine, globalBackend: global)
            if backend == .wine { return nil }
            return try await setBackend(.automatic, for: application, targetExecutable: executable, engine: engine)
        }
        guard profile.prefixPath == canonical(URL(fileURLWithPath: application.prefixPath)).path,
              FileManager.default.fileExists(atPath: profile.executablePath) else {
            throw TraverseError.message("Choose this application's current executable in Application Settings.")
        }
        let executable = URL(fileURLWithPath: profile.executablePath)
        let global = try TraverseSettings.load(from: paths).graphicsBackend
        if profile.selection == .automatic,
           try GraphicsSupport.resolve(.automatic, executable: executable, engine: engine, globalBackend: global) != profile.backend {
            return try await setBackend(.automatic, for: application, targetExecutable: executable, engine: engine)
        }
        try GraphicsSupport.validate(backend: profile.backend, engine: engine)
        let directory = URL(fileURLWithPath: profile.executablePath).deletingLastPathComponent()
        for (name, expected) in profile.fileHashes {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)), Self.digest(data) == expected else {
                throw TraverseError.message("\(application.name)'s graphics files have changed. Reapply its graphics backend in Application Settings.")
            }
        }
        if profile.backend == .dxmt && profile.graphicsOverlayID != MSyncGraphicsOverlay.id {
            return try await setBackend(profile.selection, for: application,
                targetExecutable: URL(fileURLWithPath: profile.executablePath), engine: engine)
        }
        if profile.backend == .dxvk && profile.graphicsOverlayID != DXVKSupport.id {
            return try await setBackend(profile.selection, for: application,
                targetExecutable: URL(fileURLWithPath: profile.executablePath), engine: engine)
        }
        if profile.backend == .d3dmetal && (profile.graphicsOverlayID != D3DMetalSupport.overlayID || !D3DMetalSupport.prepared(for: engine)) {
            return try await setBackend(profile.selection, for: application,
                targetExecutable: URL(fileURLWithPath: profile.executablePath), engine: engine)
        }
        return profile
    }

    private func target(for application: LauncherApplication, requested: URL?, previous: GraphicsProfile?) throws -> URL {
        let source: URL
        if let requested { source = requested }
        else if let previous { source = URL(fileURLWithPath: previous.executablePath) }
        else if application.kind == .executable, let path = application.executablePath,
                URL(fileURLWithPath: path).pathExtension.lowercased() == "exe" { source = URL(fileURLWithPath: path) }
        else if application.kind == .steamGame, application.steamAppID == BadEndTheaterSupport.appID {
            let directory = application.activationDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? BadEndTheaterSupport.gameDirectory(in: paths)
            source = directory.appendingPathComponent("badendtheater.exe")
        } else { throw TraverseError.message("Choose the application's executable to configure its graphics backend.") }
        let executable = canonical(source)
        guard executable.pathExtension.lowercased() == "exe",
              (try? executable.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            throw TraverseError.message("Choose an existing Windows executable (.exe).")
        }
        if application.kind == .steamGame {
            let directory = application.activationDirectory.map { canonical(URL(fileURLWithPath: $0, isDirectory: true)) }
                ?? (application.steamAppID == BadEndTheaterSupport.appID ? canonical(BadEndTheaterSupport.gameDirectory(in: paths)) : nil)
            guard let directory, executable.path.hasPrefix(directory.path + "/") else {
                throw TraverseError.message("Choose the game's executable inside its Steam installation folder.")
            }
        } else if application.kind == .executable, let path = application.executablePath,
                  URL(fileURLWithPath: path).pathExtension.lowercased() == "exe",
                  canonical(URL(fileURLWithPath: path)) != executable {
            throw TraverseError.message("Configure the executable added to this application's launcher entry.")
        }
        return executable
    }

    private func legacyProfile(for application: LauncherApplication, target: URL? = nil) -> GraphicsProfile? {
        guard canonical(URL(fileURLWithPath: application.prefixPath)) == canonical(paths.prefix),
              let record = legacyRecord() else { return nil }
        let executable = canonical(BadEndTheaterSupport.gameDirectory(in: paths).appendingPathComponent("badendtheater.exe"))
        let selected = target ?? application.executablePath.map { canonical(URL(fileURLWithPath: $0)) }
        guard (application.kind == .steamGame && application.steamAppID == BadEndTheaterSupport.appID)
                || selected == executable else { return nil }
        let hashes = record.fileHashes.filter { BadEndTheaterSupport.libraryNames.contains($0.key) }
        guard hashes.count == BadEndTheaterSupport.libraryNames.count else { return nil }
        return GraphicsProfile(applicationID: application.id, backend: .dxvk,
            executablePath: executable.path, prefixPath: canonical(paths.prefix).path, fileHashes: hashes,
            graphicsOverlayID: record.graphicsOverlayID)
    }

    private func legacyRecord() -> GameSupportRecord? {
        guard let data = try? Data(contentsOf: BadEndTheaterSupport.recordURL(in: paths)),
              let record = try? JSONDecoder().decode(GameSupportRecord.self, from: data),
              record.appID == BadEndTheaterSupport.appID, record.backendVersion == BadEndTheaterSupport.backendVersion,
              BadEndTheaterSupport.libraryNames.allSatisfy({ record.fileHashes[$0] != nil }) else { return nil }
        return record
    }

    private func load() throws -> [String: GraphicsProfile] {
        guard FileManager.default.fileExists(atPath: store.path) else { return [:] }
        let profiles = try JSONDecoder().decode([String: GraphicsProfile].self, from: Data(contentsOf: store))
        guard profiles.allSatisfy({ id, profile in
            profile.applicationID == id && profile.backend != .automatic
                && Set(profile.fileHashes.keys) == Set(profile.backend.libraryNames)
        }) else { throw TraverseError.message("The saved graphics profiles are invalid. Check graphics-profiles.json in the Traverse folder.") }
        return profiles
    }

    private func registryValue(_ name: String, key: String, engine: WineEngine, prefix: URL) async throws -> String? {
        let log = paths.logs.appendingPathComponent("graphics-\(UUID().uuidString.lowercased()).log")
        let result = try await ProcessRunner.run(executable: engine.wine,
            arguments: ["reg", "query", key, "/v", name], environment: engine.environment(prefix: prefix), log: log)
        if result.status == 1 { return nil }
        guard result.status == 0 else {
            throw TraverseError.message("The current graphics settings could not be read. Check \(log.lastPathComponent) in Logs.")
        }
        let output = try String(contentsOf: log, encoding: .utf8)
        for line in output.components(separatedBy: .newlines) {
            guard let type = line.range(of: "REG_SZ"),
                  line[..<type.lowerBound].trimmingCharacters(in: .whitespaces).lowercased() == name.lowercased() else { continue }
            return line[type.upperBound...].trimmingCharacters(in: .whitespaces)
        }
        throw TraverseError.message("The current graphics settings could not be read. Check \(log.lastPathComponent) in Logs.")
    }

    private func setRegistryValue(_ value: String?, name: String, key: String, engine: WineEngine, prefix: URL) async throws {
        let log = paths.logs.appendingPathComponent("graphics-\(UUID().uuidString.lowercased()).log")
        let arguments = value.map { ["reg", "add", key, "/v", name, "/t", "REG_SZ", "/d", $0, "/f"] }
            ?? ["reg", "delete", key, "/v", name, "/f"]
        let result = try await ProcessRunner.run(executable: engine.wine, arguments: arguments,
            environment: engine.environment(prefix: prefix), log: log)
        guard result.status == 0 || (value == nil && result.status == 1) else {
            throw TraverseError.message("The graphics settings could not be saved. Check \(log.lastPathComponent) in Logs.")
        }
    }

    private func canonical(_ url: URL) -> URL { url.standardizedFileURL.resolvingSymlinksInPath() }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
