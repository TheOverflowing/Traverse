import CryptoKit
import Foundation

enum MSyncGraphicsOverlay {
    static let id = "dxmt-v0.80-traverse-div-reciprocal-4"
    static let archiveName = "dxmt-v0.80-traverse-div-reciprocal.tar.gz"
    static let archiveSHA256 = "154e5cfee388c02e8297f23ccfaf55943fd84fc9be5de1d9cb7a17cfc58fc324"
    static let baseCommit = "589adb780354b461645b29999cefaf533594ee99"
    static let patchSHA256 = "720d621063aca1095dfa1447f986004a96e2c0435ee348d5c4bf654e28a27a51"
    static let companionFiles = ["x86_64-windows/winemetal.dll", "i386-windows/winemetal.dll", "x86_64-unix/winemetal.so"]
    static let payloadFiles = ["x86_64-unix/winemetal.so"] + ["x86_64-windows", "i386-windows"].flatMap { architecture in
        ["d3d11.dll", "d3d10core.dll", "dxgi.dll", "winemetal.dll"].map { "\(architecture)/\($0)" }
    }
    private static let installer = Installer()

    struct FileRecord: Codable, Sendable {
        let sha256: String
        let bytes: Int
    }

    struct Manifest: Codable, Sendable {
        let id: String
        let baseCommit: String
        let patchSHA256: String
        let files: [String: FileRecord]
    }

    private struct InstallationRecord: Codable {
        let archiveSHA256: String
        let manifest: Manifest
        let retainedFiles: [String]
        let installedAt: Date
    }

    static func installed(in paths: TraversePaths, expectedSHA256: String = archiveSHA256) -> Bool {
        let directory = MSyncEngine.destination(in: paths)
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("graphics-overlay.json")),
              let record = try? JSONDecoder().decode(InstallationRecord.self, from: data),
              record.archiveSHA256 == expectedSHA256, record.manifest.id == id,
              record.manifest.baseCommit == baseCommit, record.manifest.patchSHA256 == patchSHA256,
              Set(record.manifest.files.keys) == Set(payloadFiles), !record.retainedFiles.isEmpty else { return false }
        let files = payloadFiles.map { "grapple-wine/share/grapple/dxmt/\($0)" }
            + companionFiles.map { "grapple-wine/lib/wine/\($0)" } + record.retainedFiles
        return files.allSatisfy { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }
    }

    static func install(in paths: TraversePaths,
                        progress: @Sendable (String) async -> Void) async throws {
        if installed(in: paths) { return }
        guard let archive = Bundle.module.url(forResource: archiveName, withExtension: nil, subdirectory: "Resources") else {
            throw TraverseError.message("The bundled DXMT update is missing. Reinstall Traverse.")
        }
        try await install(in: paths, archive: archive, expectedSHA256: archiveSHA256, progress: progress)
    }

    static func install(in paths: TraversePaths, archive: URL, expectedSHA256: String,
                        progress: @Sendable (String) async -> Void = { _ in }) async throws {
        try await installer.install(in: paths, archive: archive, expectedSHA256: expectedSHA256, progress: progress)
    }

    private actor Installer {
        private var updates: [String: Task<Void, Error>] = [:]

        func install(in paths: TraversePaths, archive: URL, expectedSHA256: String,
                     progress: @Sendable (String) async -> Void) async throws {
            let key = paths.root.standardizedFileURL.resolvingSymlinksInPath().path
            if let update = updates[key] { return try await update.value }
            if MSyncGraphicsOverlay.installed(in: paths, expectedSHA256: expectedSHA256) { return }
            let update = Task {
                try await MSyncGraphicsOverlay.installArchive(in: paths, archive: archive,
                    expectedSHA256: expectedSHA256)
            }
            updates[key] = update
            defer { updates.removeValue(forKey: key) }
            await progress("Updating DXMT…")
            try await update.value
        }
    }

    private static func installArchive(in paths: TraversePaths, archive: URL, expectedSHA256: String) async throws {
        guard digest(try Data(contentsOf: archive, options: .mappedIfSafe)) == expectedSHA256 else {
            throw TraverseError.message("The bundled DXMT update failed verification. Reinstall Traverse.")
        }
        try paths.prepare()
        let files = FileManager.default
        let directory = MSyncEngine.destination(in: paths)
        let staging = directory.appendingPathComponent(".dxmt-update-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: staging) }
        let result = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: ["-xzf", archive.path, "-C", staging.path],
            log: paths.logs.appendingPathComponent("msync-graphics-update.log"))
        guard result.status == 0 else {
            throw TraverseError.message("DXMT could not be unpacked. Open msync-graphics-update.log for details.")
        }
        let manifestData = try Data(contentsOf: staging.appendingPathComponent("manifest.json"))
        let manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)
        guard manifest.id == id, manifest.baseCommit == baseCommit, manifest.patchSHA256 == patchSHA256,
              Set(manifest.files.keys) == Set(payloadFiles),
              files.fileExists(atPath: staging.appendingPathComponent("Sources").path),
              files.fileExists(atPath: staging.appendingPathComponent("Licenses").path) else {
            throw TraverseError.message("The bundled DXMT update is incomplete. Reinstall Traverse.")
        }
        var payloads: [String: Data] = [:]
        for name in payloadFiles {
            let data = try Data(contentsOf: staging.appendingPathComponent(name), options: .mappedIfSafe)
            guard let record = manifest.files[name], record.bytes == data.count, record.sha256 == digest(data) else {
                throw TraverseError.message("The bundled DXMT library failed verification. Reinstall Traverse.")
            }
            payloads[name] = data
        }
        let engineRoot = directory.appendingPathComponent("grapple-wine", isDirectory: true)
        let stagedDXMT = engineRoot.appendingPathComponent("share/grapple/dxmt", isDirectory: true)
        let previous = try? JSONDecoder().decode(InstallationRecord.self,
            from: Data(contentsOf: directory.appendingPathComponent("graphics-overlay.json")))
        // Check every companion against its previously managed payload before changing any file.
        for name in companionFiles {
            let destination = engineRoot.appendingPathComponent("lib/wine/\(name)")
            guard files.fileExists(atPath: destination.path) else { continue }
            let current = try Data(contentsOf: destination, options: .mappedIfSafe)
            let old = try? Data(contentsOf: stagedDXMT.appendingPathComponent(name), options: .mappedIfSafe)
            guard current == payloads[name] || current == old || previous?.manifest.files[name]?.sha256 == digest(current) else {
                throw TraverseError.message("The Wine engine has a different \(destination.lastPathComponent). Its existing file was kept.")
            }
        }
        // Update companions first so an interrupted update can still recognize the old staged payloads.
        for name in companionFiles {
            let destination = engineRoot.appendingPathComponent("lib/wine/\(name)")
            try files.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try payloads[name]!.write(to: destination, options: .atomic)
        }
        for name in payloadFiles {
            let destination = stagedDXMT.appendingPathComponent(name)
            try files.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try payloads[name]!.write(to: destination, options: .atomic)
        }
        var retainedFiles: [String] = []
        for folder in ["Sources", "Licenses"] {
            let destination = directory.appendingPathComponent("\(folder)/\(id)", isDirectory: true)
            if files.fileExists(atPath: destination.path) { try files.removeItem(at: destination) }
            try files.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try files.copyItem(at: staging.appendingPathComponent(folder), to: destination)
            retainedFiles += try Self.retainedFiles(in: destination, relativeTo: directory)
        }
        let retainedManifest = directory.appendingPathComponent("Sources/\(id)/manifest.json")
        try manifestData.write(to: retainedManifest, options: .atomic)
        retainedFiles.append("Sources/\(id)/manifest.json")
        let record = InstallationRecord(archiveSHA256: expectedSHA256, manifest: manifest,
            retainedFiles: retainedFiles.sorted(), installedAt: Date())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(record).write(to: directory.appendingPathComponent("graphics-overlay.json"), options: .atomic)
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func retainedFiles(in directory: URL, relativeTo root: URL) throws -> [String] {
        let contents = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey])!
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        var files: [String] = []
        for case let file as URL in contents where try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            files.append(String(file.standardizedFileURL.resolvingSymlinksInPath().path.dropFirst(rootPath.count + 1)))
        }
        return files
    }
}
