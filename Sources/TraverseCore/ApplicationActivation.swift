import Foundation

enum ApplicationActivation {
    struct Result: Codable, Sendable {
        let pid: Int32
        let hwnd: UInt64
    }

    struct Match: Sendable {
        let result: Result
        let log: URL
    }

    static func activate(_ application: LauncherApplication, engine: WineEngine, paths: TraversePaths) async throws -> Match? {
        let prefix = URL(fileURLWithPath: application.prefixPath, isDirectory: true)
        guard let arguments = try arguments(for: application, paths: paths) else { return nil }
        guard let helper = Bundle.module.url(forResource: "window-activate", withExtension: "exe", subdirectory: "Resources") else {
            throw TraverseError.message("The Windows window helper is missing. Rebuild Traverse with scripts/build-app.sh.")
        }
        let log = paths.logs.appendingPathComponent("activation-\(UUID().uuidString.lowercased()).log")
        let result = try await ProcessRunner.run(executable: engine.wine, arguments: [helper.path] + arguments,
            environment: engine.environment(prefix: prefix),
            directory: application.workingDirectory.map { URL(fileURLWithPath: $0) }, log: log)
        if result.status == 1 { return nil }
        guard result.status == 0 else {
            throw TraverseError.message("Could not bring \(application.name) to the front. Check \(log.lastPathComponent) in Logs.")
        }
        // Wine diagnostics share the file-backed output with the helper's one
        // JSON result line. Decode the result without interpreting diagnostics.
        let output = try String(contentsOf: log, encoding: .utf8)
        let activation = output.split(whereSeparator: \.isNewline).compactMap {
            try? JSONDecoder().decode(Result.self, from: Data($0.utf8))
        }.first
        guard let activation, activation.pid > 0, activation.hwnd > 0 else {
            throw TraverseError.message("Could not read the existing window for \(application.name). Check \(log.lastPathComponent) in Logs.")
        }
        return Match(result: activation, log: log)
    }

    static func arguments(for application: LauncherApplication, paths: TraversePaths) throws -> [String]? {
        guard let path = application.executablePath else { return nil }
        let prefix = URL(fileURLWithPath: application.prefixPath, isDirectory: true)
        let mode: String
        let target: URL
        switch application.kind {
        case .steam:
            mode = "--steam"
            target = URL(fileURLWithPath: path)
        case .steamGame:
            var directory = application.activationDirectory
            if directory == nil {
                directory = try ApplicationLibrary(paths: paths).applications().first {
                    $0.kind == .steamGame && $0.steamAppID == application.steamAppID
                        && canonical(URL(fileURLWithPath: $0.prefixPath)) == canonical(prefix)
                }?.activationDirectory
            }
            guard let directory else { return nil }
            mode = "--directory"
            target = URL(fileURLWithPath: directory, isDirectory: true)
        case .shortcut:
            mode = "--shortcut"
            target = URL(fileURLWithPath: path)
        case .executable:
            // A shared JVM image cannot identify which JAR owns a window.
            guard !["msi", "jar"].contains(URL(fileURLWithPath: path).pathExtension.lowercased()) else { return nil }
            mode = "--executable"
            target = URL(fileURLWithPath: path)
        }
        guard let windowsPath = windowsPath(for: target, prefix: prefix) else { return nil }
        return [mode, windowsPath]
    }

    static func windowsPath(for url: URL, prefix: URL) -> String? {
        let path = canonical(url).path
        let cDrive = canonical(prefix.appendingPathComponent("drive_c", isDirectory: true)).path
        if let relative = relativePath(path, inside: cDrive) { return "C:\\" + relative.replacingOccurrences(of: "/", with: "\\") }
        let drives = (try? FileManager.default.contentsOfDirectory(at: prefix.appendingPathComponent("dosdevices"),
            includingPropertiesForKeys: nil)) ?? []
        let mapped = drives.compactMap { drive -> (String, String)? in
            let name = drive.lastPathComponent
            guard name.count == 2, name.last == ":", name.first?.isLetter == true,
                  FileManager.default.fileExists(atPath: drive.path) else { return nil }
            return (String(name.prefix(1)).uppercased(), canonical(drive).path)
        }.sorted { $0.1.count > $1.1.count }
        for (letter, root) in mapped {
            if let relative = relativePath(path, inside: root) {
                return letter + ":\\" + relative.replacingOccurrences(of: "/", with: "\\")
            }
        }
        return nil
    }

    private static func relativePath(_ path: String, inside root: String) -> String? {
        if path == root { return "" }
        let start = root == "/" ? "/" : root + "/"
        guard path.hasPrefix(start) else { return nil }
        return String(path.dropFirst(start.count))
    }

    private static func canonical(_ url: URL) -> URL { url.standardizedFileURL.resolvingSymlinksInPath() }
}
