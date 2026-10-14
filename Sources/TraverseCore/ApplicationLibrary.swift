import CryptoKit
import Foundation

public enum LauncherApplicationKind: String, Codable, Sendable {
    case steam
    case steamGame
    case executable
    case shortcut
}

public struct LauncherApplication: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let kind: LauncherApplicationKind
    public let executablePath: String?
    public let arguments: [String]
    public let workingDirectory: String?
    public let prefixPath: String
    public let steamAppID: Int?
    public let iconPath: String?
    public var customIconPath: String?
    public let activationDirectory: String?
    public let isImported: Bool

    public init(id: String, name: String, kind: LauncherApplicationKind,
                executablePath: String? = nil, arguments: [String] = [],
                workingDirectory: String? = nil, prefixPath: String,
                steamAppID: Int? = nil, iconPath: String? = nil, activationDirectory: String? = nil,
                isImported: Bool = false, customIconPath: String? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.executablePath = executablePath
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.prefixPath = prefixPath
        self.steamAppID = steamAppID
        self.iconPath = iconPath
        self.customIconPath = customIconPath
        self.activationDirectory = activationDirectory
        self.isImported = isImported
    }
}

public struct ApplicationLibrary: Sendable {
    public let paths: TraversePaths
    public var applicationsPrefix: URL { paths.root.appendingPathComponent("Bottles/Windows", isDirectory: true) }
    private var catalogURL: URL { paths.root.appendingPathComponent("library.json") }

    public init(paths: TraversePaths = TraversePaths()) { self.paths = paths }

    public func applications() throws -> [LauncherApplication] {
        let catalog = try load()
        let discovered = discover()
        let importedPaths = Set(catalog.applications.compactMap(\.executablePath).map { canonical(URL(fileURLWithPath: $0)).path })
        let visible = catalog.applications + discovered.filter {
            guard let path = $0.executablePath, $0.kind == .shortcut else { return true }
            return !importedPaths.contains(canonical(URL(fileURLWithPath: path)).path)
        }
        return visible.filter { !catalog.hiddenIDs.contains($0.id) }.sorted {
            if $0.kind == .steam && $1.kind != .steam { return true }
            if $1.kind == .steam && $0.kind != .steam { return false }
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    @discardableResult
    public func addExecutable(at url: URL, name: String? = nil) throws -> LauncherApplication {
        let source = canonical(url)
        guard ["exe", "com", "msi", "lnk", "jar"].contains(source.pathExtension.lowercased()) else {
            throw TraverseError.message("Choose a Windows application, Java application, installer, or shortcut (.exe, .com, .jar, .msi, or .lnk).")
        }
        guard (try? source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            throw TraverseError.message("The selected application could not be found.")
        }
        let shortcut = source.pathExtension.lowercased() == "lnk"
        guard !shortcut || isWindowsShortcut(source) else {
            throw TraverseError.message("The selected file is not a Windows shortcut.")
        }
        var catalog = try load()
        if let discovered = discover().first(where: { application in
            guard application.kind == .steam || application.kind == .shortcut,
                  let path = application.executablePath else { return false }
            return canonical(URL(fileURLWithPath: path)) == source
        }) {
            // Preserve Steam's update/rendering profile and the shortcut's
            // owning environment when an existing entry is added again.
            catalog.applications.removeAll { application in
                guard let path = application.executablePath else { return false }
                return canonical(URL(fileURLWithPath: path)) == source
            }
            catalog.hiddenIDs.remove(discovered.id)
            try save(catalog)
            return discovered
        }
        let title = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = inferredPrefix(for: source) ?? applicationsPrefix
        let id = "import:\(token(source.path))"
        let entry = LauncherApplication(id: id,
            name: title.flatMap { $0.isEmpty ? nil : $0 } ?? source.deletingPathExtension().lastPathComponent,
            kind: shortcut ? .shortcut : .executable, executablePath: source.path,
            workingDirectory: source.deletingLastPathComponent().path, prefixPath: prefix.path,
            iconPath: adjacentIcon(to: source)?.path, isImported: true,
            customIconPath: catalog.applications.first { $0.id == id }?.customIconPath)
        catalog.applications.removeAll { $0.id == entry.id }
        catalog.applications.append(entry)
        catalog.hiddenIDs.remove(entry.id)
        try save(catalog)
        return entry
    }

    public func applicationForOpening(at url: URL) throws -> LauncherApplication {
        let source = canonical(url)
        if let existing = try applications().first(where: { application in
            application.executablePath.map { canonical(URL(fileURLWithPath: $0)) == source } ?? false
        }) { return existing }
        return try addExecutable(at: source)
    }

    @discardableResult
    public func setCustomIconPath(_ path: String?, for applicationID: String) throws -> LauncherApplication {
        var catalog = try load()
        guard let index = catalog.applications.firstIndex(where: { $0.id == applicationID && $0.isImported }) else {
            throw TraverseError.message("Icons can be changed for imported applications.")
        }
        catalog.applications[index].customIconPath = path
        try save(catalog)
        return catalog.applications[index]
    }

    func applicationForIconCustomization(id: String) throws -> LauncherApplication {
        guard let application = try load().applications.first(where: { $0.id == id && $0.isImported }) else {
            throw TraverseError.message("Icons can be changed for imported applications.")
        }
        return application
    }

    public func remove(id: String) throws {
        var catalog = try load()
        if catalog.applications.contains(where: { $0.id == id }) {
            catalog.applications.removeAll { $0.id == id }
        } else {
            catalog.hiddenIDs.insert(id)
        }
        try save(catalog)
    }

    private struct Catalog: Codable {
        var applications: [LauncherApplication] = []
        var hiddenIDs: Set<String> = []
    }

    private func load() throws -> Catalog {
        guard FileManager.default.fileExists(atPath: catalogURL.path) else { return Catalog() }
        return try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: catalogURL))
    }

    private func save(_ catalog: Catalog) throws {
        try paths.prepare()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(catalog).write(to: catalogURL, options: .atomic)
    }

    func managedPrefixes() -> [URL] {
        let bottles = paths.root.appendingPathComponent("Bottles", isDirectory: true)
        var prefixes = [paths.prefix]
        for url in directoryContents(bottles) {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("drive_c").path) {
                prefixes.append(url)
            }
        }
        var seen = Set<String>()
        return prefixes.filter { seen.insert(canonical($0).path).inserted }
            .sorted { $0.path < $1.path }
    }

    private func discover() -> [LauncherApplication] {
        var applications: [LauncherApplication] = []
        for prefix in managedPrefixes() {
            let shortcuts = shortcutFiles(in: prefix)
            let steamCandidates = [prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam/steam.exe"),
                                   prefix.appendingPathComponent("drive_c/Program Files/Steam/steam.exe")]
            let steam = steamCandidates.first { FileManager.default.fileExists(atPath: $0.path) }
                ?? (canonical(prefix) == canonical(paths.prefix) ? paths.steam : nil)
            if let steam {
                applications.append(LauncherApplication(id: "steam:\(token(canonical(prefix).path))", name: "Steam",
                    kind: .steam, executablePath: steam.path,
                    workingDirectory: steam.deletingLastPathComponent().path, prefixPath: prefix.path))
                applications += steamGames(steam: steam, prefix: prefix, shortcuts: shortcuts)
            }
            let knownNames = Set(applications.filter { canonical(URL(fileURLWithPath: $0.prefixPath)) == canonical(prefix) }
                .map { normalizedName($0.name) })
            var seenNames = knownNames
            for shortcut in shortcuts where shortcut.pathExtension.lowercased() == "lnk" {
                let title = shortcut.deletingPathExtension().lastPathComponent
                let nameKey = normalizedName(title)
                guard isLaunchShortcut(title), isWindowsShortcut(shortcut), seenNames.insert(nameKey).inserted else { continue }
                applications.append(LauncherApplication(id: "shortcut:\(token(canonical(prefix).path + "|" + nameKey))",
                    name: title, kind: .shortcut, executablePath: shortcut.path,
                    prefixPath: prefix.path, iconPath: adjacentIcon(to: shortcut)?.path))
            }
        }
        return applications
    }

    func steamGameDirectory(appID: Int) -> URL? {
        installedSteamGames(steam: paths.steam, prefix: paths.prefix)
            .first { $0.appID == appID }?.directory
    }

    private struct InstalledSteamGame {
        let appID: Int
        let title: String
        let directory: URL
    }

    private func steamGames(steam: URL, prefix: URL, shortcuts: [URL]) -> [LauncherApplication] {
        let steamDirectory = steam.deletingLastPathComponent()
        return installedSteamGames(steam: steam, prefix: prefix).map { game in
            let icon = steamGameIcon(appID: game.appID, steamDirectory: steamDirectory,
                gameDirectory: game.directory, shortcuts: shortcuts, prefix: prefix)
            return LauncherApplication(id: "steam-game:\(token(canonical(prefix).path)):\(game.appID)",
                name: game.title, kind: .steamGame, executablePath: steam.path,
                arguments: ["-applaunch", String(game.appID)], workingDirectory: steamDirectory.path,
                prefixPath: prefix.path, steamAppID: game.appID, iconPath: icon?.path,
                activationDirectory: canonical(game.directory).path)
        }
    }

    private func installedSteamGames(steam: URL, prefix: URL) -> [InstalledSteamGame] {
        let steamDirectory = steam.deletingLastPathComponent()
        var libraries = [steamDirectory]
        let libraryFile = steamDirectory.appendingPathComponent("steamapps/libraryfolders.vdf")
        if let root = ValveKeyValues.read(libraryFile)?.object("libraryfolders") {
            for (_, node) in root {
                let path = node.string ?? node.object?["path"]?.string
                if let path, let url = windowsURL(path, prefix: prefix) { libraries.append(url) }
            }
        }
        var seenLibraries = Set<String>()
        var seenGames = Set<Int>()
        var games: [InstalledSteamGame] = []
        for library in libraries where seenLibraries.insert(canonical(library).path).inserted {
            let steamapps = library.appendingPathComponent("steamapps", isDirectory: true)
            for manifest in directoryContents(steamapps) where manifest.lastPathComponent.hasPrefix("appmanifest_") && manifest.pathExtension == "acf" {
                guard let state = ValveKeyValues.read(manifest)?.object("AppState"),
                      let rawID = state["appid"]?.string, let appID = Int(rawID), appID > 0,
                      manifest.lastPathComponent == "appmanifest_\(appID).acf",
                      let title = state["name"]?.string, !title.isEmpty,
                      let installDirectory = state["installdir"]?.string, !installDirectory.isEmpty,
                      !installDirectory.contains("/"), !installDirectory.contains("\\"), installDirectory != ".." else { continue }
                let game = steamapps.appendingPathComponent("common", isDirectory: true)
                    .appendingPathComponent(installDirectory, isDirectory: true)
                guard (try? game.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                      seenGames.insert(appID).inserted else { continue }
                games.append(InstalledSteamGame(appID: appID, title: title, directory: game))
            }
        }
        return games
    }

    private func steamGameIcon(appID: Int, steamDirectory: URL, gameDirectory: URL,
                               shortcuts: [URL], prefix: URL) -> URL? {
        for shortcut in shortcuts where shortcut.pathExtension.lowercased() == "url" {
            guard let text = try? String(contentsOf: shortcut, encoding: .utf8) else { continue }
            let fields = Dictionary(text.components(separatedBy: .newlines).compactMap { line -> (String, String)? in
                guard let separator = line.firstIndex(of: "=") else { return nil }
                return (line[..<separator].trimmingCharacters(in: .whitespaces).lowercased(),
                        line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces))
            }, uniquingKeysWith: { _, latest in latest })
            guard fields["url"] == "steam://rungameid/\(appID)", let path = fields["iconfile"],
                  let icon = windowsURL(path, prefix: prefix), FileManager.default.fileExists(atPath: icon.path) else { continue }
            return icon
        }
        for name in ["\(appID)_icon.jpg", "\(appID)_icon.png", "\(appID)_logo.png"] {
            let icon = steamDirectory.appendingPathComponent("appcache/librarycache/\(name)")
            if FileManager.default.fileExists(atPath: icon.path) { return icon }
        }
        for app in directoryContents(gameDirectory) where app.pathExtension == "app" {
            let icon = app.appendingPathComponent("Contents/Resources/icon.icns")
            if FileManager.default.fileExists(atPath: icon.path) { return icon }
        }
        return nil
    }

    private func shortcutRoots(in prefix: URL) -> [URL] {
        let drive = prefix.appendingPathComponent("drive_c", isDirectory: true)
        var roots = [drive.appendingPathComponent("ProgramData/Microsoft/Windows/Start Menu/Programs")]
        for user in directoryContents(drive.appendingPathComponent("users", isDirectory: true)) {
            roots += [user.appendingPathComponent("Desktop"),
                      user.appendingPathComponent("AppData/Roaming/Microsoft/Windows/Start Menu/Programs")]
        }
        return roots
    }

    private func shortcutFiles(in prefix: URL) -> [URL] {
        let discoveryRoot = canonical(paths.root)
        var seenRoots = Set<String>()
        var seenFiles = Set<String>()
        var shortcuts: [URL] = []
        for root in shortcutRoots(in: prefix) {
            // Wine's host Desktop aliases can block on macOS folder permission prompts.
            // Automatic discovery stays inside Traverse's managed storage.
            let resolved = canonical(root)
            guard resolved.path == discoveryRoot.path || resolved.path.hasPrefix(discoveryRoot.path + "/"),
                  seenRoots.insert(resolved.path).inserted,
                  let enumerator = FileManager.default.enumerator(at: resolved,
                    includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { continue }
            for case let item as URL in enumerator {
                let properties = try? item.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                if properties?.isSymbolicLink == true { enumerator.skipDescendants(); continue }
                guard ["lnk", "url"].contains(item.pathExtension.lowercased()), properties?.isRegularFile == true,
                      seenFiles.insert(canonical(item).path).inserted else { continue }
                shortcuts.append(item)
            }
        }
        return shortcuts.sorted { $0.path < $1.path }
    }

    private func inferredPrefix(for source: URL) -> URL? {
        let prefixes = managedPrefixes()
        if let prefix = prefixes.first(where: { prefix in
            let drive = canonical(prefix.appendingPathComponent("drive_c", isDirectory: true)).path + "/"
            return source.path.hasPrefix(drive)
        }) { return prefix }
        guard source.pathExtension.lowercased() == "lnk" else { return nil }
        // An explicitly selected shortcut can belong to a mapped Desktop without
        // granting automatic access to the rest of that host folder.
        return prefixes.first { prefix in
            shortcutRoots(in: prefix).contains { root in
                source.path.hasPrefix(canonical(root).path + "/")
            }
        }
    }

    private func windowsURL(_ path: String, prefix: URL) -> URL? {
        if path.hasPrefix("/") { return canonical(URL(fileURLWithPath: path)) }
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        guard normalized.count >= 3 else { return nil }
        let characters = Array(normalized)
        guard characters[1] == ":", characters[2] == "/" else { return nil }
        let drive = String(characters[0]).lowercased()
        let base: URL
        if drive == "c" { base = prefix.appendingPathComponent("drive_c", isDirectory: true) }
        else {
            base = prefix.appendingPathComponent("dosdevices/\(drive):", isDirectory: true)
            guard FileManager.default.fileExists(atPath: base.path) else { return nil }
        }
        return canonical(base.appendingPathComponent(String(characters.dropFirst(3))))
    }

    private func adjacentIcon(to source: URL) -> URL? {
        for ext in ["ico", "png", "icns"] {
            let icon = source.deletingPathExtension().appendingPathExtension(ext)
            if FileManager.default.fileExists(atPath: icon.path) { return icon }
        }
        return nil
    }

    private func isWindowsShortcut(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 76), header.count == 76 else { return false }
        return header.prefix(20) == Data([0x4c, 0, 0, 0, 0x01, 0x14, 0x02, 0, 0, 0, 0, 0, 0xc0, 0, 0, 0, 0, 0, 0, 0x46])
    }

    private func isLaunchShortcut(_ title: String) -> Bool {
        let words = title.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
        return !words.contains { ["uninstall", "uninstaller", "readme", "help", "manual", "documentation"].contains($0) }
    }

    private func normalizedName(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    private func directoryContents(_ directory: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]))?.sorted { $0.path < $1.path } ?? []
    }

    private func canonical(_ url: URL) -> URL { url.standardizedFileURL.resolvingSymlinksInPath() }
    private func token(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}

enum ValveKeyValues {
    indirect enum Value {
        case string(String)
        case object([String: Value])
        var string: String? { if case .string(let value) = self { value } else { nil } }
        var object: [String: Value]? { if case .object(let value) = self { value } else { nil } }
        func object(_ key: String) -> [String: Value]? { object?[key]?.object }
    }

    static func read(_ url: URL) -> Value? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return parse(text)
    }

    static func parse(_ text: String) -> Value? {
        var parser = Parser(characters: Array(text))
        return parser.object(nested: false).map(Value.object)
    }

    private enum Token { case text(String), open, close }
    private struct Parser {
        let characters: [Character]
        var index = 0

        mutating func object(nested: Bool) -> [String: Value]? {
            var result: [String: Value] = [:]
            while let token = next() {
                if case .close = token { return nested ? result : nil }
                guard case .text(let key) = token, let value = next() else { return nil }
                switch value {
                case .text(let string): result[key] = .string(string)
                case .open:
                    guard let child = object(nested: true) else { return nil }
                    result[key] = .object(child)
                case .close: return nil
                }
            }
            return nested ? nil : result
        }

        mutating func next() -> Token? {
            while index < characters.count {
                if characters[index].isWhitespace || characters[index] == "\u{feff}" { index += 1; continue }
                if characters[index] == "/", index + 1 < characters.count, characters[index + 1] == "/" {
                    while index < characters.count && characters[index] != "\n" { index += 1 }
                    continue
                }
                break
            }
            guard index < characters.count else { return nil }
            let first = characters[index]
            index += 1
            if first == "{" { return .open }
            if first == "}" { return .close }
            var string = ""
            if first == "\"" {
                while index < characters.count {
                    let character = characters[index]
                    index += 1
                    if character == "\"" { return .text(string) }
                    if character == "\\", index < characters.count {
                        let escaped = characters[index]
                        if escaped == "\\" || escaped == "\"" { string.append(escaped); index += 1 }
                        else { string.append(character) }
                    } else { string.append(character) }
                }
                return nil
            }
            string.append(first)
            while index < characters.count, !characters[index].isWhitespace,
                  characters[index] != "{", characters[index] != "}" {
                string.append(characters[index]); index += 1
            }
            return .text(string)
        }
    }
}
