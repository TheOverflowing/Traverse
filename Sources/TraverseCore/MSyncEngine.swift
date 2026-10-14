import CryptoKit
import Foundation

public enum MSyncEngine {
    public static let version = "1.0.2"
    public static let archiveName = "grapple-wine-\(version).tar.xz"
    public static let archiveURL = URL(string:
        "https://github.com/MartijnBud/grapple-releases/releases/download/v0.2.5-beta.1/\(archiveName)")!
    public static let sha256 = "db4925788bef2f83404bb685e2304cb923d62c5759312ee639822aaf85b34a5c"
    public static let sourceArchiveName = "grapple-wine-\(version)-source.tar.xz"
    public static let sourceArchiveURL = URL(string:
        "https://github.com/MartijnBud/grapple-releases/releases/download/v0.2.5-beta.1/\(sourceArchiveName)")!
    public static let sourceSHA256 = "b78e6b5cca86396c8c286abd7170ff3c2be8cdded27fece09cf703fca150a80a"

    public static func engine(in paths: TraversePaths) -> WineEngine {
        WineEngine(wine: destination(in: paths).appendingPathComponent("grapple-wine/bin/wine"), msync: true)
    }

    public static func installed(in paths: TraversePaths) -> Bool {
        let directory = destination(in: paths)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard engine(in: paths).installed,
              let data = try? Data(contentsOf: directory.appendingPathComponent("installation.json")),
              let record = try? decoder.decode(InstallationRecord.self, from: data),
              record.version == version, record.engineURL == archiveURL,
              record.engineSHA256 == sha256, record.sourceURL == sourceArchiveURL,
              record.sourceSHA256 == sourceSHA256 else { return false }
        return retainedFiles.allSatisfy {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
    }

    public static func install(in paths: TraversePaths,
                               progress: @Sendable (String) async -> Void) async throws -> WineEngine {
        try paths.prepare()
        if installed(in: paths) {
            try await MSyncGraphicsOverlay.install(in: paths, progress: progress)
            try await MSyncAudioOverlay.install(in: paths)
            return engine(in: paths)
        }
        let directory = destination(in: paths)
        let recordURL = directory.appendingPathComponent("installation.json")
        if FileManager.default.fileExists(atPath: recordURL.path) {
            try FileManager.default.removeItem(at: recordURL)
        }
        // Re-extracting the base package restores its original DXMT files.
        let graphicsRecord = directory.appendingPathComponent("graphics-overlay.json")
        if FileManager.default.fileExists(atPath: graphicsRecord.path) {
            try FileManager.default.removeItem(at: graphicsRecord)
        }
        let archive = try await verifiedArchive(name: archiveName, url: archiveURL, sha256: sha256,
            description: "MSync engine", paths: paths, progress: progress)
        let sourceArchive = try await verifiedArchive(name: sourceArchiveName, url: sourceArchiveURL,
            sha256: sourceSHA256, description: "engine source", paths: paths, progress: progress)
        let sources = directory.appendingPathComponent("Sources", isDirectory: true)
        let wineLicenses = directory.appendingPathComponent("Licenses/Wine", isDirectory: true)
        let dxmtLicenses = directory.appendingPathComponent("Licenses/DXMT", isDirectory: true)
        for folder in [sources, wineLicenses, dxmtLicenses] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }

        await progress("Preparing engine source and licenses…")
        try await unpack(arguments: ["-xJf", sourceArchive.path, "-C", sources.path],
            log: paths.logs.appendingPathComponent("msync-source-install.log"),
            failure: "The engine source could not be unpacked. Open msync-source-install.log for details.")
        let retainedArchive = sources.appendingPathComponent(sourceArchiveName)
        if FileManager.default.fileExists(atPath: retainedArchive.path) {
            try FileManager.default.removeItem(at: retainedArchive)
        }
        try FileManager.default.copyItem(at: sourceArchive, to: retainedArchive)
        let sourcePackage = sources.appendingPathComponent("grapple-wine-\(version)-source", isDirectory: true)
        try await unpack(arguments: ["-xzf",
            sourcePackage.appendingPathComponent("wine/crossover-sources-26.3.0.tar.gz").path,
            "-C", wineLicenses.path, "--strip-components", "2",
            "sources/wine/LICENSE", "sources/wine/COPYING.LIB"],
            log: paths.logs.appendingPathComponent("msync-wine-license-install.log"),
            failure: "The Wine licenses could not be unpacked. Open msync-wine-license-install.log for details.")
        try await unpack(arguments: ["-xzf", sourcePackage.appendingPathComponent("dxmt/dxmt-v0.80.tar.gz").path,
            "-C", dxmtLicenses.path, "--strip-components", "1",
            "dxmt-v0.80/LICENSE", "dxmt-v0.80/src/util/dxvk.LICENSE"],
            log: paths.logs.appendingPathComponent("msync-dxmt-license-install.log"),
            failure: "The graphics licenses could not be unpacked. Open msync-dxmt-license-install.log for details.")

        await progress("Preparing MSync engine…")
        try await unpack(arguments: ["-xJf", archive.path, "-C", directory.path],
            log: paths.logs.appendingPathComponent("msync-engine-install.log"),
            failure: "The MSync engine could not be unpacked. Open msync-engine-install.log for details.")
        let engine = engine(in: paths)
        guard engine.installed, retainedFiles.allSatisfy({
            FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
        }) else {
            throw TraverseError.message("The MSync installation is incomplete. Install the engine again.")
        }

        let record = InstallationRecord(version: version, engineURL: archiveURL, engineSHA256: sha256,
            sourceURL: sourceArchiveURL, sourceSHA256: sourceSHA256, installedAt: Date())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // The record marks completion only after the engine, source, and licenses are present.
        try encoder.encode(record).write(to: recordURL, options: .atomic)
        try await MSyncGraphicsOverlay.install(in: paths, progress: progress)
        try await MSyncAudioOverlay.install(in: paths)
        await progress("MSync engine installed")
        return engine
    }

    static func destination(in paths: TraversePaths) -> URL {
        paths.engines.appendingPathComponent("grapple-wine-\(version)", isDirectory: true)
    }

    static func managedPaths(for engine: WineEngine) -> TraversePaths? {
        let wine = engine.wine.standardizedFileURL.resolvingSymlinksInPath()
        let root = wine.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let paths = TraversePaths(root: root)
        return wine == Self.engine(in: paths).wine.standardizedFileURL.resolvingSymlinksInPath() ? paths : nil
    }

    static func prepareGraphics(for engine: WineEngine,
                                progress: @Sendable (String) async -> Void = { _ in }) async throws {
        guard let paths = managedPaths(for: engine) else { return }
        _ = try await install(in: paths, progress: progress)
    }

    private static let retainedFiles = [
        "Sources/\(sourceArchiveName)",
        "Sources/grapple-wine-\(version)-source/SOURCE-OFFER.md",
        "Sources/grapple-wine-\(version)-source/DEPENDENCIES.md",
        "Licenses/Wine/LICENSE", "Licenses/Wine/COPYING.LIB",
        "Licenses/DXMT/LICENSE", "Licenses/DXMT/src/util/dxvk.LICENSE",
    ]

    private static func verifiedArchive(name: String, url: URL, sha256: String, description: String,
                                        paths: TraversePaths,
                                        progress: @Sendable (String) async -> Void) async throws -> URL {
        let archive = paths.downloads.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: archive.path) {
            await progress("Downloading \(description)…")
            try await WineEngine.download(url, to: archive)
        }
        await progress("Verifying \(description)…")
        let data = try Data(contentsOf: archive, options: .mappedIfSafe)
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual == sha256 else {
            try FileManager.default.removeItem(at: archive)
            throw TraverseError.message("The \(description) download failed verification. Install the engine again.")
        }
        return archive
    }

    private static func unpack(arguments: [String], log: URL, failure: String) async throws {
        let result = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: arguments, log: log)
        guard result.status == 0 else { throw TraverseError.message(failure) }
    }

    private struct InstallationRecord: Codable {
        let version: String
        let engineURL: URL
        let engineSHA256: String
        let sourceURL: URL
        let sourceSHA256: String
        let installedAt: Date
    }
}
