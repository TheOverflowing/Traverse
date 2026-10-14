import CryptoKit
import Foundation

enum MSyncAudioOverlay {
    static let id = "wine-11-coreaudio-device-period-1"
    static let originalSHA256 = "635bd140542e28971bc0e7056b54f7b6759256b9b2886d52279ccfa524eb6033"
    static let payloadSHA256 = "557d90fd37f04d8894cf23201f8f5b8033b7f31eff66685e09cb20d36465f1da"
    static let sourceSHA256 = "b1dc1c5c4f5f755cc712a29fb7ee6a4383d1b634d6ffbd22197047c041b2e864"
    static let library = Bundle.module.url(forResource: "winecoreaudio-traverse-period", withExtension: "so",
                                         subdirectory: "Resources")!
    static let source = Bundle.module.url(forResource: "wine-coreaudio-device-period-source", withExtension: "tar.gz",
                                        subdirectory: "Resources")!
    static let dsoundID = "wine-11-dsound-sse2-1"
    static let dsoundSHA256 = "56c6da3cd5ba0b9415fb8b78090beb307f80882d4d237b0237cf54d69ccd58bb"
    static let dsoundSourceSHA256 = "5dee0d4dbc121cc090b6b4b593da439320afb5086fa90437c74c0d4291fd91ec"
    static let dsoundLibrary = Bundle.module.url(forResource: "dsound-traverse-sse2", withExtension: "dll",
                                               subdirectory: "Resources")!
    static let dsoundSource = Bundle.module.url(forResource: "wine-dsound-sse2-source", withExtension: "tar.gz",
                                              subdirectory: "Resources")!
    private static let installer = Installer()

    private struct Driver {
        let id: String
        let relativePath: String
        let originalHash: String
        let payloadHash: String
        let sourceHash: String
        let library: URL
        let source: URL
    }

    private static let drivers = [
        Driver(id: id, relativePath: "x86_64-unix/winecoreaudio.so", originalHash: originalSHA256,
               payloadHash: payloadSHA256, sourceHash: sourceSHA256, library: library, source: source),
        Driver(id: dsoundID, relativePath: "i386-windows/dsound.dll",
               originalHash: "59133bd0362dae28366d4b32d4dfaef469ac0e508316fe54f761ff64dc8e5fb7",
               payloadHash: dsoundSHA256, sourceHash: dsoundSourceSHA256,
               library: dsoundLibrary, source: dsoundSource)
    ]

    static func install(in paths: TraversePaths) async throws {
        try await installer.install(in: paths)
    }

    private actor Installer {
        func install(in paths: TraversePaths) throws {
            let root = MSyncEngine.destination(in: paths)
            for driver in drivers { try install(driver, root: root) }
        }

        private func install(_ driver: Driver, root: URL) throws {
            let target = root.appendingPathComponent("grapple-wine/lib/wine/\(driver.relativePath)")
            let retainedSource = root.appendingPathComponent("Sources/\(driver.id)/source.tar.gz")
            let files = FileManager.default
            let current = try files.fileExists(atPath: target.path) ? Data(contentsOf: target) : nil
            let currentHash = current.map(Self.digest)
            if currentHash == driver.payloadHash, let retained = try? Data(contentsOf: retainedSource),
               Self.digest(retained) == driver.sourceHash { return }
            guard currentHash == nil || currentHash == driver.originalHash || currentHash == driver.payloadHash else {
                throw TraverseError.message("The Wine engine has a different audio driver. Its existing file was kept.")
            }
            let payload = try Data(contentsOf: driver.library)
            let sourceData = try Data(contentsOf: driver.source)
            guard Self.digest(payload) == driver.payloadHash, Self.digest(sourceData) == driver.sourceHash else {
                throw TraverseError.message("The bundled audio driver failed verification. Reinstall Traverse.")
            }
            let backup = root.appendingPathComponent("Originals/\(target.lastPathComponent)")
            if let current, currentHash == driver.originalHash, !files.fileExists(atPath: backup.path) {
                try files.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
                try current.write(to: backup, options: .atomic)
            }
            try files.createDirectory(at: retainedSource.deletingLastPathComponent(), withIntermediateDirectories: true)
            try sourceData.write(to: retainedSource, options: .atomic)
            try files.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Atomic replacement lets existing streams finish with their loaded driver.
            try payload.write(to: target, options: .atomic)
            try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
        }

        private static func digest(_ data: Data) -> String {
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
    }
}
