import CryptoKit
import Foundation

actor DotNetRuntime {
    static let version = "8.0.32"
    struct Package: Sendable {
        let name: String
        let url: URL
        let sha512: String
    }
    static let packages = [
        Package(name: "dotnet-runtime-8.0.32-win-x64.zip",
            url: URL(string: "https://dotnetcli.blob.core.windows.net/dotnet/Runtime/8.0.32/dotnet-runtime-8.0.32-win-x64.zip")!,
            sha512: "f0349e793d8081c682c01d736db695c9c1ec268c6173648913543db219e44cbf2e952c7ef94fc37946b0f2bb95ca1898d972a43591b8e44d5a1659f4911904c0"),
        Package(name: "windowsdesktop-runtime-8.0.32-win-x64.zip",
            url: URL(string: "https://dotnetcli.blob.core.windows.net/dotnet/WindowsDesktop/8.0.32/windowsdesktop-runtime-8.0.32-win-x64.zip")!,
            sha512: "29fe39edc6820a564de94540df8664cf585f38be150f7c49043dc3fece10e2d94dfc22b6e9e4246371ff90bcf5dd4149f23c8e3aca4698a05b1ff658abc1d267")
    ]
    private let paths: TraversePaths
    private var preparation: Task<URL, Error>?

    init(paths: TraversePaths) { self.paths = paths }

    private struct Configuration: Decodable {
        struct Options: Decodable {
            struct Framework: Decodable {
                let name: String
                let version: String
                let rollForward: String?
                let applyPatches: Bool?
            }
            let framework: Framework?
            let frameworks: [Framework]?
            let includedFrameworks: [Framework]?
            let rollForward: String?
            let applyPatches: Bool?
        }
        let runtimeOptions: Options
    }

    static func isSupportedApplication(_ executable: URL) -> Bool {
        guard executable.pathExtension.lowercased() == "exe" else { return false }
        let config = executable.deletingPathExtension().appendingPathExtension("runtimeconfig.json")
        guard let data = try? Data(contentsOf: config),
              let options = try? JSONDecoder().decode(Configuration.self, from: data).runtimeOptions,
              options.includedFrameworks == nil,
              (try? GraphicsSupport.architecture(of: executable)) == .x64 else { return false }
        let directory = executable.deletingLastPathComponent()
        guard !FileManager.default.fileExists(atPath: directory.appendingPathComponent("hostfxr.dll").path),
              !FileManager.default.fileExists(atPath: directory.appendingPathComponent("coreclr.dll").path) else { return false }
        let frameworks = options.frameworks ?? options.framework.map { [$0] } ?? []
        return !frameworks.isEmpty && frameworks.allSatisfy { framework in
            guard ["Microsoft.NETCore.App", "Microsoft.WindowsDesktop.App"].contains(framework.name) else { return false }
            let components = framework.version.split(separator: ".")
            let numbers = components.compactMap { Int($0) }
            guard components.count == 3, numbers.count == 3, numbers[0] == 8, numbers[1] == 0,
                  (0...32).contains(numbers[2]) else { return false }
            // Keep exact-version requests exact; do not rewrite the application's policy.
            if (framework.rollForward ?? options.rollForward)?.lowercased() == "disable"
                || (framework.applyPatches ?? options.applyPatches) == false {
                return framework.version == version
            }
            return true
        }
    }

    static func directory(in paths: TraversePaths) -> URL {
        paths.root.appendingPathComponent("Runtimes/DotNet/\(version)-win-x64", isDirectory: true)
    }

    static var marker: String { packages.map(\.sha512).joined(separator: "\n") }

    static func installed(in paths: TraversePaths) -> URL? {
        let root = directory(in: paths)
        let files = ["dotnet.exe", "host/fxr/\(version)/hostfxr.dll",
                     "shared/Microsoft.NETCore.App/\(version)/coreclr.dll",
                     "shared/Microsoft.WindowsDesktop.App/\(version)/PresentationFramework.dll",
                     "shared/Microsoft.WindowsDesktop.App/\(version)/System.Windows.Forms.dll",
                     "LICENSE.txt", "ThirdPartyNotices.txt"]
        guard (try? String(contentsOf: root.appendingPathComponent(".traverse-ready"), encoding: .utf8)) == marker,
              files.allSatisfy({ FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path) }) else { return nil }
        return root
    }

    static func verify(_ archive: URL, package: Package) throws {
        let digest = SHA512.hash(data: try Data(contentsOf: archive, options: .mappedIfSafe))
            .map { String(format: "%02x", $0) }.joined()
        guard digest == package.sha512 else {
            throw TraverseError.message("The .NET runtime download failed verification. Remove \(package.name) from Downloads and try again.")
        }
    }

    func prepare(progress: @escaping @Sendable (String) async -> Void) async throws -> URL {
        if let installed = Self.installed(in: paths) { return installed }
        if let preparation { return try await preparation.value }
        let paths = paths
        let task = Task<URL, Error> {
            try paths.prepare()
            let root = Self.directory(in: paths)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            for package in Self.packages {
                let archive = paths.downloads.appendingPathComponent(package.name)
                if !FileManager.default.fileExists(atPath: archive.path) {
                    await progress("Downloading .NET Desktop Runtime…")
                    try await WineEngine.download(package.url, to: archive)
                }
                await progress("Preparing .NET Desktop Runtime…")
                try Self.verify(archive, package: package)
                let result = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/ditto"),
                    arguments: ["-x", "-k", archive.path, root.path],
                    log: paths.logs.appendingPathComponent("dotnet-install-\(package.name).log"))
                guard result.status == 0 else {
                    throw TraverseError.message("The .NET runtime could not be unpacked. Open Logs for details.")
                }
            }
            let marker = root.appendingPathComponent(".traverse-ready")
            try Data(Self.marker.utf8).write(to: marker, options: .atomic)
            guard let installed = Self.installed(in: paths) else {
                try FileManager.default.removeItem(at: marker)
                throw TraverseError.message("The .NET runtime is incomplete. Reopen the application to prepare it again.")
            }
            return installed
        }
        preparation = task
        defer { preparation = nil }
        return try await task.value
    }
}
