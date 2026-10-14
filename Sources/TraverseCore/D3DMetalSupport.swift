import CryptoKit
import Foundation

public enum D3DMetalSupport {
    public static let version = "4.0-beta-2"
    static let overlayID = "d3dmetal-4.0-beta-2-ffxiv-scanline-1"
    static let archiveName = "d3dmetal-\(version).tar.xz"
    static let archiveURL = URL(string: "https://github.com/MartijnBud/grapple-releases/releases/download/v0.2.5-beta.1/\(archiveName)")!
    static let archiveSHA256 = "b512c609f91c855209d2f9abdbc20bec6d627a7f9981f0b2bbec0c276b194507"
    static let aliases = ["d3d10.dll": "td310.dll", "d3d11.dll": "td311.dll",
                          "d3d12.dll": "td312.dll", "dxgi.dll": "tdxg.dll"]

    static func validate(engine: WineEngine, executable: URL? = nil) throws {
        #if arch(arm64)
        let supportedHost = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26
        #else
        let supportedHost = false
        #endif
        guard supportedHost, let managed = MSyncEngine.managedPaths(for: engine), MSyncEngine.installed(in: managed) else {
            throw TraverseError.message("D3DMetal requires the managed MSync engine on Apple silicon with macOS 26 or later.")
        }
        if let executable, try GraphicsSupport.architecture(of: executable) != .x64 {
            throw TraverseError.message("D3DMetal supports 64-bit Windows executables.")
        }
    }

    static func package(for engine: WineEngine) -> URL {
        engine.wine.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("D3DMetal/d3dmetal-\(version)")
    }

    static func prepared(for engine: WineEngine) -> Bool {
        let root = engine.wine.deletingLastPathComponent().deletingLastPathComponent()
        let bridge = package(for: engine).appendingPathComponent("external/libd3dshared.dylib")
        return FileManager.default.fileExists(atPath: bridge.path) && aliases.values.allSatisfy { alias in
            let library = root.appendingPathComponent("lib/wine/x86_64-windows/\(alias)")
            let companion = root.appendingPathComponent("lib/wine/x86_64-unix/\(URL(fileURLWithPath: alias).deletingPathExtension().lastPathComponent).so")
            return FileManager.default.fileExists(atPath: library.path)
                && companion.resolvingSymlinksInPath() == bridge.resolvingSymlinksInPath()
        }
    }

    static func payloads(executable: URL, engine: WineEngine, paths: TraversePaths,
                         progress: @Sendable (String) async -> Void) async throws -> [String: Data] {
        try validate(engine: engine, executable: executable)
        try paths.prepare()
        let archive = paths.downloads.appendingPathComponent(archiveName)
        if !FileManager.default.fileExists(atPath: archive.path) {
            await progress("Downloading D3DMetal…")
            try await WineEngine.download(archiveURL, to: archive)
        }
        guard digest(try Data(contentsOf: archive, options: .mappedIfSafe)) == archiveSHA256 else {
            try FileManager.default.removeItem(at: archive)
            throw TraverseError.message("The D3DMetal download failed verification. Apply its graphics backend again.")
        }
        let package = package(for: engine)
        if !FileManager.default.fileExists(atPath: package.appendingPathComponent("manifest.json").path) {
            await progress("Preparing D3DMetal…")
            try FileManager.default.createDirectory(at: package.deletingLastPathComponent(), withIntermediateDirectories: true)
            let result = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/tar"),
                arguments: ["-xJf", archive.path, "-C", package.deletingLastPathComponent().path],
                log: paths.logs.appendingPathComponent("d3dmetal-install.log"))
            guard result.status == 0 else {
                throw TraverseError.message("D3DMetal could not be unpacked. Open d3dmetal-install.log for details.")
            }
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: package.appendingPathComponent("manifest.json")))
        for file in manifest.files {
            if let expected = file.sha256 {
                guard digest(try Data(contentsOf: package.appendingPathComponent(file.path), options: .mappedIfSafe)) == expected else {
                    throw TraverseError.message("The installed D3DMetal files have changed. Remove its component folder and apply D3DMetal again.")
                }
            }
        }
        let engineRoot = engine.wine.deletingLastPathComponent().deletingLastPathComponent()
        let libraries = engineRoot.appendingPathComponent("lib/wine/x86_64-windows")
        let companions = engineRoot.appendingPathComponent("lib/wine/x86_64-unix")
        var payloads: [String: Data] = [:]
        for (name, alias) in aliases.sorted(by: { $0.key < $1.key }) {
            let data = try renamedBuiltin(Data(contentsOf: package.appendingPathComponent("wine/x86_64-windows/\(name)")), name: alias)
            let library = libraries.appendingPathComponent(alias)
            if FileManager.default.fileExists(atPath: library.path) {
                guard try Data(contentsOf: library) == data else {
                    throw TraverseError.message("The Wine engine has a different \(alias). Its existing file was kept.")
                }
            } else { try data.write(to: library, options: .atomic) }
            let companion = companions.appendingPathComponent(URL(fileURLWithPath: alias).deletingPathExtension().lastPathComponent + ".so")
            let bridge = package.appendingPathComponent("external/libd3dshared.dylib")
            if FileManager.default.fileExists(atPath: companion.path) {
                guard companion.resolvingSymlinksInPath() == bridge.resolvingSymlinksInPath() else {
                    throw TraverseError.message("The Wine engine has a different \(companion.lastPathComponent). Its existing file was kept.")
                }
            } else { try FileManager.default.createSymbolicLink(at: companion, withDestinationURL: bridge) }
            payloads[name] = data
        }
        // The FFXIV proxy loads this name explicitly; Wine needs a local PE
        // entry to resolve its separately named builtin and Unix companion.
        payloads["tdxg.dll"] = payloads["dxgi.dll"]
        if executable.lastPathComponent.lowercased() == "ffxiv_dx11.exe" {
            guard let shim = Bundle.module.url(forResource: "ffxiv-dxgi", withExtension: "dll", subdirectory: "Resources") else {
                throw TraverseError.message("The FFXIV graphics fix is missing. Reinstall Traverse.")
            }
            payloads["dxgi.dll"] = try Data(contentsOf: shim)
        }
        return payloads
    }

    // Wine resolves a stamped PE to the builtin named in its export directory.
    // Separate names keep its stock DXGI/D3D DLLs available to other profiles.
    static func renamedBuiltin(_ original: Data, name: String) throws -> Data {
        guard try GraphicsSupport.architecture(of: original) == .x64,
              original.count >= 96, original.subdata(in: 64..<96) == GraphicsSupport.builtinMarker else {
            throw TraverseError.message("The D3DMetal library does not match the supported package.")
        }
        func word(_ offset: Int, size: Int = 4) throws -> Int {
            guard offset >= 0, offset <= original.count - size else { throw TraverseError.message("The D3DMetal library is incomplete.") }
            return (0..<size).reduce(0) { $0 | Int(original[offset + $1]) << ($1 * 8) }
        }
        let pe = try word(60), optional = pe + 24
        let sections = optional + (try word(pe + 20, size: 2))
        let sectionCount = try word(pe + 6, size: 2)
        func offset(_ rva: Int) throws -> Int {
            for index in 0..<sectionCount {
                let section = sections + index * 40
                let address = try word(section + 12)
                let size = max(try word(section + 8), try word(section + 16))
                if rva >= address, rva - address < size { return try word(section + 20) + rva - address }
            }
            throw TraverseError.message("The D3DMetal library has no export directory.")
        }
        let exports = try offset(word(optional + 112))
        let start = try offset(word(exports + 12))
        guard start < original.count, let end = original[start...].firstIndex(of: 0),
              end - start == name.utf8.count else { throw TraverseError.message("The D3DMetal library has an unexpected module name.") }
        var data = original
        data.replaceSubrange(start..<end, with: name.utf8)
        return data
    }

    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private struct Manifest: Decodable {
        let files: [File]
        struct File: Decodable { let path: String; let sha256: String? }
    }
}
