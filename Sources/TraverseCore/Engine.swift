import CryptoKit
import Foundation

public struct WineEngine: Sendable {
    public static let version = "11.0_1"
    public static let archiveName = "wine-stable-11.0_1-osx64.tar.xz"
    public static let archiveURL = URL(string:
        "https://github.com/Gcenx/macOS_Wine_builds/releases/download/11.0_1/\(archiveName)")!
    public static let sha256 = "b50dc50ec7f41d58b115a6b685d4d1315ba3c797bd3aa0f49213f2703cb82388"

    public let wine: URL
    public let msync: Bool
    public var server: URL { wine.deletingLastPathComponent().appendingPathComponent("wineserver") }

    public init(wine: URL, msync: Bool = false) {
        self.wine = wine
        self.msync = msync
    }

    public var supportsMSync: Bool {
        let client = wine.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("lib/wine/x86_64-unix/ntdll.so")
        let marker = Data("WINEMSYNC".utf8)
        return [client, server].allSatisfy { binary in
            guard let data = try? Data(contentsOf: binary, options: .mappedIfSafe) else { return false }
            return data.range(of: marker) != nil
        }
    }

    public static func managed(in paths: TraversePaths) -> Self {
        Self(wine: paths.engines.appendingPathComponent(
            "wine-\(version)/Wine Stable.app/Contents/Resources/wine/bin/wine"))
    }

    public var installed: Bool {
        FileManager.default.isExecutableFile(atPath: wine.path)
            && FileManager.default.isExecutableFile(atPath: server.path)
    }

    public func environment(prefix: URL, debug: Bool = false) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        // An inherited Wine/CrossOver configuration must never redirect this bottle.
        for key in ["WINEPREFIX", "WINEARCH", "WINESERVER", "WINELOADER", "WINEDLLPATH",
                    "WINEDLLOVERRIDES", "CX_BOTTLE", "CX_ROOT", "DYLD_LIBRARY_PATH", "CFProcessPath",
                    "DYLD_INSERT_LIBRARIES", "TRAVERSE_DOCK_IDENTITIES", "TRAVERSE_DOCK_ICON", "TRAVERSE_RETINA_MASK_FIX"] {
            environment.removeValue(forKey: key)
        }
        environment["WINEPREFIX"] = prefix.path
        environment["WINEARCH"] = "win64"
        // macOS exposes OpenGL 3.2+ Core only as forward-compatible contexts.
        // The managed engine can supply the flag when a Core application omits it.
        environment["CX_FWD_COMPAT_GL_CTX"] = "1"
        environment["WINESERVER"] = server.path
        environment["WINEDEBUG"] = debug ? "+timestamp,+pid,+tid,+seh" : "-all"
        // Wine derives the legacy Windows code page from LC_CTYPE. GBK text
        // needs CP936 even when macOS and the application's UI are English.
        environment.removeValue(forKey: "LC_ALL")
        environment["LC_CTYPE"] = "zh_CN.UTF-8"
        // Client and server must use the same synchronization mode in a prefix.
        environment["WINEMSYNC"] = msync ? "1" : "0"
        environment.removeValue(forKey: "WINE_MSYNC")
        environment["PATH"] = wine.deletingLastPathComponent().path
            + ":/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"
        return environment
    }

    public static func install(in paths: TraversePaths,
                               progress: @Sendable (String) async -> Void) async throws -> Self {
        try paths.prepare()
        let engine = managed(in: paths)
        if engine.installed { return engine }
        let archive = paths.downloads.appendingPathComponent(archiveName)
        if !FileManager.default.fileExists(atPath: archive.path) {
            await progress("Downloading Wine 11…")
            try await download(archiveURL, to: archive)
        }
        await progress("Verifying Wine…")
        let data = try Data(contentsOf: archive, options: .mappedIfSafe)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == sha256 else {
            try FileManager.default.removeItem(at: archive)
            throw TraverseError.message("The Wine download failed verification. Install the engine again.")
        }
        await progress("Preparing Wine…")
        let destination = paths.engines.appendingPathComponent("wine-\(version)", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let result = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: ["-xJf", archive.path, "-C", destination.path],
            log: paths.logs.appendingPathComponent("engine-install.log"))
        guard result.status == 0, engine.installed else {
            throw TraverseError.message("Wine could not be unpacked. Open the engine install log for details.")
        }
        return engine
    }

    static func download(_ source: URL, to destination: URL) async throws {
        let (temporary, response) = try await URLSession.shared.download(from: source)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw TraverseError.message("The download server did not return the requested file.")
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
    }
}
