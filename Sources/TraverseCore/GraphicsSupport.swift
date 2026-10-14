import Foundation

public enum GraphicsArchitecture: String, Sendable {
    case x86
    case x64

    var wineDirectory: String { self == .x64 ? "x86_64-windows" : "i386-windows" }
    var dxvkDirectory: String { self == .x64 ? "x64" : "x32" }
}

public enum GraphicsSupport {
    static let dxmtLibraryNames = ["d3d11.dll", "dxgi.dll", "d3d10core.dll"]
    static let builtinMarker = Data("Wine builtin DLL".utf8) + Data(repeating: 0, count: 16)

    static func resolve(_ selection: GraphicsBackend, executable: URL, engine: WineEngine,
                        globalBackend: GraphicsBackend = .automatic) throws -> GraphicsBackend {
        guard selection == .automatic else { return selection }
        // A global preference must not prevent 32-bit applications and installers
        // from launching. Explicit per-application choices still require validation.
        if globalBackend == .d3dmetal, try architecture(of: executable) == .x86 {
            return supportsDXMT(engine: engine) ? .dxmt : .wine
        }
        if globalBackend != .automatic { return globalBackend }
        guard supportsDXMT(engine: engine) else { return .wine }
        if executable.lastPathComponent.lowercased() == "ffxiv_dx11.exe",
           try architecture(of: executable) == .x64 { return .d3dmetal }
        return .dxmt
    }

    public static func architecture(of executable: URL) throws -> GraphicsArchitecture {
        try architecture(of: Data(contentsOf: executable, options: .mappedIfSafe))
    }

    static func architecture(of data: Data) throws -> GraphicsArchitecture {
        guard data.count >= 64, data[0] == 0x4d, data[1] == 0x5a else {
            throw TraverseError.message("Select a 32-bit or 64-bit Windows executable.")
        }
        let peOffset = Int(data[60]) | Int(data[61]) << 8 | Int(data[62]) << 16 | Int(data[63]) << 24
        guard peOffset >= 64, peOffset <= data.count - 6,
              Array(data[peOffset..<(peOffset + 4)]) == [0x50, 0x45, 0, 0] else {
            throw TraverseError.message("The selected file is not a Windows executable.")
        }
        let machine = UInt16(data[peOffset + 4]) | UInt16(data[peOffset + 5]) << 8
        switch machine {
        case 0x014c: return .x86
        case 0x8664: return .x64
        default: throw TraverseError.message("Graphics profiles support x86 and x64 Windows executables.")
        }
    }

    public static func supportsDXMT(engine: WineEngine) -> Bool {
        #if arch(arm64)
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 else { return false }
        #else
        return false
        #endif
        let wine = engine.wine.standardizedFileURL.resolvingSymlinksInPath()
        let engineRoot = wine.deletingLastPathComponent().deletingLastPathComponent()
        guard let installedPaths = MSyncEngine.managedPaths(for: engine),
              MSyncEngine.installed(in: installedPaths) else { return false }
        let dxmt = engineRoot.appendingPathComponent("share/grapple/dxmt", isDirectory: true)
        let files = ["x86_64-unix/winemetal.so"] + [GraphicsArchitecture.x86, .x64].flatMap { architecture in
            (dxmtLibraryNames + ["winemetal.dll"]).map { "\(architecture.wineDirectory)/\($0)" }
        }
        return files.allSatisfy { FileManager.default.fileExists(atPath: dxmt.appendingPathComponent($0).path) }
    }

    public static func validate(backend: GraphicsBackend, engine: WineEngine) throws {
        if backend == .d3dmetal { try D3DMetalSupport.validate(engine: engine) }
        if backend == .dxmt, !supportsDXMT(engine: engine) {
            throw TraverseError.message("DXMT requires the managed MSync engine on Apple silicon with macOS 26 or later.")
        }
    }

    public static func payloads(backend: GraphicsBackend, executable: URL, engine: WineEngine,
                                paths: TraversePaths,
                                progress: @Sendable (String) async -> Void) async throws -> [String: Data] {
        if backend == .wine { return [:] }
        if backend == .dxmt { try await MSyncEngine.prepareGraphics(for: engine, progress: progress) }
        try validate(backend: backend, engine: engine)
        let architecture = try architecture(of: executable)
        switch backend {
        case .automatic:
            return try await payloads(backend: resolve(.automatic, executable: executable, engine: engine,
                                                      globalBackend: TraverseSettings.load(from: paths).graphicsBackend),
                                      executable: executable, engine: engine, paths: paths, progress: progress)
        case .wine: return [:]
        case .dxvk:
            return try await DXVKSupport.payloads(architecture: architecture, paths: paths, progress: progress)
        case .dxmt:
            let root = engine.wine.standardizedFileURL.resolvingSymlinksInPath()
                .deletingLastPathComponent().deletingLastPathComponent()
            let dxmt = root.appendingPathComponent("share/grapple/dxmt", isDirectory: true)
            let libraries = dxmt.appendingPathComponent(architecture.wineDirectory, isDirectory: true)
            var payloads: [String: Data] = [:]
            for name in dxmtLibraryNames {
                payloads[name] = try nativeDXMTPayload(Data(contentsOf: libraries.appendingPathComponent(name)))
            }
            // Keep winemetal builtin: Wine associates its PE module with the Unix companion.
            payloads["winemetal.dll"] = try Data(contentsOf: libraries.appendingPathComponent("winemetal.dll"))
            await progress("Preparing DXMT…")
            try installDXMTCompanions(from: dxmt, in: root)
            return payloads
        case .d3dmetal:
            return try await D3DMetalSupport.payloads(executable: executable, engine: engine, paths: paths, progress: progress)
        }
    }

    static func nativeDXMTPayload(_ data: Data) throws -> Data {
        _ = try architecture(of: data)
        guard data.count >= 96, data.subdata(in: 64..<96) == builtinMarker else {
            throw TraverseError.message("The DXMT library does not match the packaged graphics support.")
        }
        // winebuild --builtin adds only this DOS-stub stamp. Removing it from the
        // deployment copy prevents Wine from substituting its stock graphics DLL.
        var native = data
        native.replaceSubrange(64..<96, with: Data(repeating: 0, count: 32))
        return native
    }

    static func installDXMTCompanions(from dxmt: URL, in engineRoot: URL) throws {
        let files = ["x86_64-windows/winemetal.dll", "i386-windows/winemetal.dll", "x86_64-unix/winemetal.so"]
        let companions = try files.map { name -> (source: URL, destination: URL, data: Data) in
            let source = dxmt.appendingPathComponent(name)
            return (source, engineRoot.appendingPathComponent("lib/wine/\(name)"),
                    try Data(contentsOf: source, options: .mappedIfSafe))
        }
        // Check every destination before adding any file; an existing custom
        // companion must not be replaced by the managed package.
        for companion in companions where FileManager.default.fileExists(atPath: companion.destination.path) {
            guard try Data(contentsOf: companion.destination, options: .mappedIfSafe) == companion.data else {
                throw TraverseError.message("The Wine engine already has a different \(companion.destination.lastPathComponent). Its existing file was kept.")
            }
        }
        for companion in companions where !FileManager.default.fileExists(atPath: companion.destination.path) {
            try FileManager.default.createDirectory(at: companion.destination.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: companion.source, to: companion.destination)
        }
    }

}
