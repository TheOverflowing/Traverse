import Foundation

actor WindowsDisplaySupport {
    private let paths: TraversePaths
    private var prepared: [String: Bool] = [:]
    private var compatibleApplications: Set<String> = []

    init(paths: TraversePaths) { self.paths = paths }

    func prepareApplication(_ application: LauncherApplication, engine: WineEngine) async throws {
        guard let executable = application.executablePath,
              URL(fileURLWithPath: executable).lastPathComponent.lowercased() == "hanamikachs.exe" else { return }
        let key = application.prefixPath + "|" + engine.wine.path
        if compatibleApplications.contains(key) { return }
        // This legacy D3D9 game fixes its backbuffer at 800x600. DPI
        // virtualization otherwise doubles the fullscreen window a second time.
        let log = paths.logs.appendingPathComponent("hanamika-display-\(UUID().uuidString).log")
        let result = try await ProcessRunner.run(executable: engine.wine,
            arguments: ["reg", "add", "HKCU\\Software\\Microsoft\\Windows NT\\CurrentVersion\\AppCompatFlags\\Layers",
                "/v", "hanamikachs.exe", "/t", "REG_SZ", "/d", "HIGHDPIAWARE", "/f"],
            environment: engine.environment(prefix: URL(fileURLWithPath: application.prefixPath)), log: log)
        guard result.status == 0 else {
            throw TraverseError.message("The game's display settings could not be applied. Open \(log.lastPathComponent) for details.")
        }
        compatibleApplications.insert(key)
    }

    func prepare(prefix: URL, engine: WineEngine, retinaMode: Bool) async throws {
        let key = prefix.path + "|" + engine.wine.path
        if prepared[key] == retinaMode { return }
        let registry = prefix.appendingPathComponent(".traverse-display-\(UUID().uuidString).reg")
        // Retina doubles Wine's screen coordinates. Matching DPI keeps the
        // physical size of DPI-aware controls and text unchanged.
        // EmulateModeset is a win32u setting under the historical X11 Driver
        // key; it also applies to the Mac driver and supplies virtual modes.
        let contents = """
        Windows Registry Editor Version 5.00

        [HKEY_CURRENT_USER\\Software\\Wine\\Mac Driver]
        "RetinaMode"="\(retinaMode ? "y" : "n")"

        [HKEY_CURRENT_USER\\Control Panel\\Desktop]
        "LogPixels"=dword:\(retinaMode ? "000000c0" : "00000060")

        [HKEY_CURRENT_USER\\Software\\Wine\\X11 Driver]
        "EmulateModeset"="Y"

        """
        var data = Data([0xff, 0xfe])
        data.append(contents.replacingOccurrences(of: "\n", with: "\r\n").data(using: .utf16LittleEndian)!)
        try data.write(to: registry, options: .atomic)
        defer { try? FileManager.default.removeItem(at: registry) }
        let log = paths.logs.appendingPathComponent("windows-display-\(UUID().uuidString).log")
        let result = try await ProcessRunner.run(executable: engine.wine,
            arguments: ["reg", "import", registry.path], environment: engine.environment(prefix: prefix), log: log)
        guard result.status == 0 else {
            throw TraverseError.message("Windows display settings could not be applied. Open \(log.lastPathComponent) for details.")
        }
        prepared[key] = retinaMode
    }
}
