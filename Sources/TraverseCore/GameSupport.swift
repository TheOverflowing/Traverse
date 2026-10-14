import CryptoKit
import Foundation

public struct GameSupportStatus: Codable, Sendable {
    public let appID: Int
    public let title: String
    public let gameInstalled: Bool
    public let supportInstalled: Bool
}

struct GameSupportRecord: Codable {
    let appID: Int
    let backendVersion: String
    let installedAt: Date
    let fileHashes: [String: String]
    let graphicsOverlayID: String?

    init(appID: Int, backendVersion: String, installedAt: Date, fileHashes: [String: String],
         graphicsOverlayID: String? = nil) {
        self.appID = appID
        self.backendVersion = backendVersion
        self.installedAt = installedAt
        self.fileHashes = fileHashes
        self.graphicsOverlayID = graphicsOverlayID
    }
}

public enum BadEndTheaterSupport {
    public static let appID = 1764390
    public static let title = "BAD END THEATER"
    public static let backendVersion = "dxvk-macOS-async-v1.10.3-20230507-repack"
    static let archiveURL = URL(string:
        "https://github.com/Gcenx/DXVK-macOS/releases/download/v1.10.3-20230507-repack/\(backendVersion).tar.gz")!
    static let archiveSHA256 = "acd1520ad105d8ef124a09c8e11a259a5dc8bdc565ad18e0e52693f9807b2477"
    static let environment = Data("# Traverse compatibility profile for BAD END THEATER.\nRENPY_RENDERER = \"angle2\"\n".utf8)
    static let libraryNames = ["d3d11.dll", "d3d10core.dll"]

    public static func gameDirectory(in paths: TraversePaths) -> URL {
        if let game = ApplicationLibrary(paths: paths).steamGameDirectory(appID: appID) { return game }
        // Keep support for existing default installations without a Steam manifest.
        return paths.steam.deletingLastPathComponent()
            .appendingPathComponent("steamapps/common/BAD END THEATER", isDirectory: true)
    }

    static func recordURL(in paths: TraversePaths) -> URL {
        paths.root.appendingPathComponent("GameSupport/\(appID).json")
    }

    public static func status(in paths: TraversePaths) -> GameSupportStatus {
        let game = gameDirectory(in: paths)
        let installed = FileManager.default.fileExists(atPath: game.appendingPathComponent("badendtheater.exe").path)
        var supportInstalled = false
        if installed, let data = try? Data(contentsOf: recordURL(in: paths)),
           let record = try? JSONDecoder().decode(GameSupportRecord.self, from: data),
           record.backendVersion == backendVersion, record.appID == appID,
           record.graphicsOverlayID == DXVKSupport.id,
           Set(record.fileHashes.keys) == Set(libraryNames + ["environment.txt"]) {
            supportInstalled = record.fileHashes.allSatisfy { name, expected in
                guard let data = try? Data(contentsOf: game.appendingPathComponent(name), options: .mappedIfSafe) else {
                    return false
                }
                return digest(data) == expected
            }
        }
        return GameSupportStatus(appID: appID, title: title,
            gameInstalled: installed, supportInstalled: supportInstalled)
    }

    static func install(in paths: TraversePaths, engine: WineEngine,
                        progress: @Sendable (String) async -> Void) async throws {
        try paths.prepare()
        guard status(in: paths).gameInstalled else {
            throw TraverseError.message("Install BAD END THEATER in Windows Steam first.")
        }
        guard engine.installed else { throw TraverseError.message("Install the Wine engine first.") }
        let libraries = try await DXVKSupport.libraries(architecture: .x64, paths: paths, progress: progress)
        let destination = recordURL(in: paths)
        let originalRecord = try? Data(contentsOf: destination)
        let previous = originalRecord.flatMap {
            try? JSONDecoder().decode(GameSupportRecord.self, from: $0)
        }
        var ownedHashes = previous?.appID == appID && previous?.backendVersion == backendVersion
            ? previous?.fileHashes ?? [:] : [:]
        let game = gameDirectory(in: paths)
        var originalFiles: [String: Data] = [:]
        for name in libraryNames + ["environment.txt"] {
            let file = game.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: file.path) { originalFiles[name] = try Data(contentsOf: file) }
        }
        let profiles = GraphicsProfiles(paths: paths)
        let profileURL = await profiles.store
        let previousLibraryHashes = originalFiles.filter { libraryNames.contains($0.key) }.mapValues(digest)
        let newLibraryHashes = try Dictionary(uniqueKeysWithValues: libraryNames.map {
            ($0, digest(try Data(contentsOf: libraries.appendingPathComponent($0))))
        })
        let profileUpdate = try await profiles.compatibilityDXVKProfileUpdate(
            executable: game.appendingPathComponent("badendtheater.exe"), prefix: paths.prefix,
            previousHashes: previousLibraryHashes, fileHashes: newLibraryHashes)
        if profileUpdate != nil {
            ownedHashes.merge(previousLibraryHashes) { _, profileHash in profileHash }
        }
        await progress("Preparing BAD END THEATER…")
        let hashes = try stageFiles(from: libraries, in: game, ownedHashes: ownedHashes)
        // AppDefaults applies these overrides to this executable only. Steam's
        // Chromium helper and other games retain their own graphics settings.
        let key = "HKCU\\Software\\Wine\\AppDefaults\\badendtheater.exe\\DllOverrides"
        var recordWritten = false
        do {
            for library in ["d3d11", "d3d10core"] {
                let result = try await ProcessRunner.run(executable: engine.wine,
                    arguments: ["reg", "add", key, "/v", library, "/t", "REG_SZ", "/d", "native,builtin", "/f"],
                    environment: engine.environment(prefix: paths.prefix),
                    log: paths.logs.appendingPathComponent("badendtheater-\(library)-override.log"))
                guard result.status == 0 else {
                    throw TraverseError.message("BAD END THEATER's graphics settings could not be saved. Open its override log for details.")
                }
            }
            let record = GameSupportRecord(appID: appID, backendVersion: backendVersion,
                installedAt: Date(), fileHashes: hashes, graphicsOverlayID: DXVKSupport.id)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(record).write(to: destination, options: .atomic)
            recordWritten = true
            if let profileUpdate { try profileUpdate.write(to: profileURL, options: .atomic) }
        } catch {
            let failure = error
            if recordWritten {
                if let originalRecord { try originalRecord.write(to: destination, options: .atomic) }
                else { try FileManager.default.removeItem(at: destination) }
            }
            for name in libraryNames + ["environment.txt"] {
                let file = game.appendingPathComponent(name)
                if let original = originalFiles[name] { try original.write(to: file, options: .atomic) }
                else if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            }
            throw failure
        }
        await progress("BAD END THEATER compatibility is enabled")
    }

    static func stageFiles(from libraries: URL, in game: URL,
                           ownedHashes: [String: String] = [:]) throws -> [String: String] {
        var payloads: [String: Data] = ["environment.txt": environment]
        for name in libraryNames { payloads[name] = try Data(contentsOf: libraries.appendingPathComponent(name)) }
        // Upgrade only recorded files that still match their owned hashes.
        // Check every conflict before replacing any library or environment file.
        for (name, payload) in payloads {
            let destination = game.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: destination.path) {
                let current = try Data(contentsOf: destination)
                if current != payload && ownedHashes[name] != digest(current) {
                    throw TraverseError.message("BAD END THEATER already has a different \(name). Its existing file was kept.")
                }
            }
        }
        for (name, payload) in payloads {
            let destination = game.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: destination.path),
               try Data(contentsOf: destination) == payload { continue }
            try payload.write(to: destination, options: .atomic)
        }
        return payloads.mapValues(digest)
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
