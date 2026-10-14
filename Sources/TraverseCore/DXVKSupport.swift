import CryptoKit
import Foundation

enum DXVKSupport {
    static let id = "dxvk-v1.10.3-traverse-power-2"
    static let upstreamVersion = "dxvk-macOS-async-v1.10.3-20230507-repack"
    static let baseCommit = "8f1e28deed3ad30802f7e1bdff428ec14e6e7817"
    static let archiveName = "dxvk-v1.10.3-traverse-power.tar.gz"
    static let archiveSHA256 = "85d6403e09efa1bc89e2c40cc9f4d05665e24718357b0bd369bb8d9be6914869"
    static let payloadFiles = ["x32", "x64"].flatMap { arch in
        ["d3d11.dll", "d3d10core.dll"].map { "\(arch)/\($0)" }
    }
    private static let installer = Installer()

    struct FileRecord: Codable, Sendable {
        let sha256: String
        let bytes: Int
    }

    struct Manifest: Codable, Sendable {
        let id: String
        let baseCommit: String
        let files: [String: FileRecord]
    }

    private struct InstallationRecord: Codable {
        let archiveSHA256: String
        let manifest: Manifest
    }

    static func payloads(architecture: GraphicsArchitecture, paths: TraversePaths,
                         progress: @Sendable (String) async -> Void) async throws -> [String: Data] {
        let files = try await installer.payloads(paths: paths, progress: progress)
        return Dictionary(uniqueKeysWithValues: ["d3d11.dll", "d3d10core.dll"].map {
            ($0, files["\(architecture.dxvkDirectory)/\($0)"]!)
        })
    }

    static func libraries(architecture: GraphicsArchitecture, paths: TraversePaths,
                          progress: @Sendable (String) async -> Void) async throws -> URL {
        _ = try await installer.payloads(paths: paths, progress: progress)
        return paths.root.appendingPathComponent("Graphics/\(id)/\(architecture.dxvkDirectory)", isDirectory: true)
    }

    private actor Installer {
        private var preparations: [String: Task<[String: Data], Error>] = [:]

        func payloads(paths: TraversePaths, progress: @Sendable (String) async -> Void) async throws -> [String: Data] {
            let key = paths.root.standardizedFileURL.resolvingSymlinksInPath().path
            if let preparation = preparations[key] { return try await preparation.value }
            let preparation = Task { try await DXVKSupport.prepare(in: paths) }
            preparations[key] = preparation
            defer { preparations.removeValue(forKey: key) }
            await progress("Preparing DXVK…")
            return try await preparation.value
        }
    }

    private static func prepare(in paths: TraversePaths) async throws -> [String: Data] {
        try paths.prepare()
        let graphics = paths.root.appendingPathComponent("Graphics", isDirectory: true)
        let destination = graphics.appendingPathComponent(id, isDirectory: true)
        if let recordData = try? Data(contentsOf: destination.appendingPathComponent("installation.json")),
           let record = try? JSONDecoder().decode(InstallationRecord.self, from: recordData),
           record.archiveSHA256 == archiveSHA256,
           let files = try? verifiedPayloads(in: destination, manifest: record.manifest),
           FileManager.default.fileExists(atPath: destination.appendingPathComponent("Sources").path),
           FileManager.default.fileExists(atPath: destination.appendingPathComponent("Licenses").path) {
            return files
        }
        guard let archive = Bundle.module.url(forResource: archiveName, withExtension: nil, subdirectory: "Resources"),
              digest(try Data(contentsOf: archive, options: .mappedIfSafe)) == archiveSHA256 else {
            throw TraverseError.message("The bundled DXVK update failed verification. Reinstall Traverse.")
        }
        try FileManager.default.createDirectory(at: graphics, withIntermediateDirectories: true)
        let staging = graphics.appendingPathComponent(".dxvk-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let result = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: ["-xzf", archive.path, "-C", staging.path],
            log: paths.logs.appendingPathComponent("dxvk-install.log"))
        guard result.status == 0 else {
            throw TraverseError.message("DXVK could not be unpacked. Open dxvk-install.log for details.")
        }
        let manifest = try JSONDecoder().decode(Manifest.self,
            from: Data(contentsOf: staging.appendingPathComponent("manifest.json")))
        let files = try verifiedPayloads(in: staging, manifest: manifest)
        guard FileManager.default.fileExists(atPath: staging.appendingPathComponent("Sources").path),
              FileManager.default.fileExists(atPath: staging.appendingPathComponent("Licenses").path) else {
            throw TraverseError.message("The bundled DXVK update is incomplete. Reinstall Traverse.")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(InstallationRecord(archiveSHA256: archiveSHA256, manifest: manifest))
            .write(to: staging.appendingPathComponent("installation.json"), options: .atomic)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: staging, to: destination)
        return files
    }

    private static func verifiedPayloads(in directory: URL, manifest: Manifest) throws -> [String: Data] {
        guard manifest.id == id, manifest.baseCommit == baseCommit,
              Set(manifest.files.keys) == Set(payloadFiles) else {
            throw TraverseError.message("The bundled DXVK update is incomplete. Reinstall Traverse.")
        }
        var files: [String: Data] = [:]
        for name in payloadFiles {
            let data = try Data(contentsOf: directory.appendingPathComponent(name), options: .mappedIfSafe)
            let record = manifest.files[name]!
            guard data.count == record.bytes, digest(data) == record.sha256 else {
                throw TraverseError.message("The DXVK library failed verification. Reapply its graphics backend.")
            }
            files[name] = data
        }
        return files
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
