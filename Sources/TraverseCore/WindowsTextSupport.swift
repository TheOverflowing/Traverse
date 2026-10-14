import Foundation

actor WindowsTextSupport {
    private let paths: TraversePaths
    private var preparations: [String: Task<Void, Error>] = [:]
    private var prepared: [String: String] = [:]

    init(paths: TraversePaths) { self.paths = paths }

    func prepare(prefix: URL, engine: WineEngine, font: WindowsTextFont,
                 progress: @escaping @Sendable (String) async -> Void) async throws {
        let key = prefix.path + "|" + engine.wine.path
        let signature = font.id + "|" + font.file.path + "|" + font.family
        if prepared[key] == signature { return }
        if let task = preparations[key] { return try await task.value }
        let paths = paths
        let task = Task {
            let fonts = prefix.appendingPathComponent("drive_c/windows/Fonts", isDirectory: true)
            let marker = prefix.appendingPathComponent(".traverse-chinese-text-v1")
            let previous = (try? String(contentsOf: marker, encoding: .utf8))?.components(separatedBy: "|")
            let previousLink: String?
            if let previous, previous.count == 3 {
                previousLink = "\(URL(fileURLWithPath: previous[1]).lastPathComponent),\(previous[2])"
            } else { previousLink = nil }
            let sources = [WindowsTextFont.default.file,
                URL(fileURLWithPath: "/System/Library/Fonts/STHeiti Medium.ttc"), font.file]
            if (try? String(contentsOf: marker, encoding: .utf8)) == signature,
               sources.allSatisfy({ FileManager.default.fileExists(atPath: fonts.appendingPathComponent($0.lastPathComponent).path) }) {
                return
            }
            await progress("Preparing Chinese text support…")
            try FileManager.default.createDirectory(at: fonts, withIntermediateDirectories: true)
            for source in Set(sources) {
                let name = source.lastPathComponent
                guard FileManager.default.fileExists(atPath: source.path) else {
                    throw TraverseError.message("The macOS Chinese font \(name) is missing.")
                }
                let destination = fonts.appendingPathComponent(name)
                if !FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: source)
                }
            }
            let log = paths.logs.appendingPathComponent("chinese-text-\(UUID().uuidString).log")
            let linksKey = "HKLM\\Software\\Microsoft\\Windows NT\\CurrentVersion\\FontLink\\SystemLink"
            let query = try await ProcessRunner.run(executable: engine.wine,
                arguments: ["reg", "query", linksKey], environment: engine.environment(prefix: prefix), log: log)
            guard query.status == 0 else {
                throw TraverseError.message("The Windows font links could not be read. Open \(log.lastPathComponent) for details.")
            }
            let links = Self.fontLinks(from: try String(contentsOf: log, encoding: .utf8))
            let registry = prefix.appendingPathComponent(".traverse-chinese-text.reg")
            var data = Data([0xff, 0xfe])
            data.append(Self.registry(existingLinks: links, font: font, previousFontLink: previousLink)
                .data(using: .utf16LittleEndian)!)
            try data.write(to: registry, options: .atomic)
            defer { try? FileManager.default.removeItem(at: registry) }
            let result = try await ProcessRunner.run(executable: engine.wine,
                arguments: ["reg", "import", registry.path], environment: engine.environment(prefix: prefix), log: log)
            guard result.status == 0 else {
                throw TraverseError.message("Chinese text support could not be prepared. Open \(log.lastPathComponent) for details.")
            }
            try Data(signature.utf8).write(to: marker, options: .atomic)
        }
        preparations[key] = task
        defer { preparations.removeValue(forKey: key) }
        try await task.value
        prepared[key] = signature
    }

    static func fontLinks(from output: String) -> [String: [String]] {
        var links: [String: [String]] = [:]
        for line in output.components(separatedBy: .newlines) {
            guard let range = line.range(of: "REG_MULTI_SZ") else { continue }
            let name = line[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            links[name] = line[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: "\\0").filter { !$0.isEmpty }
        }
        return links
    }

    static func registry(existingLinks: [String: [String]], font: WindowsTextFont = .default,
                         previousFontLink: String? = nil) -> String {
        var lines = ["Windows Registry Editor Version 5.00", "",
            "[HKEY_LOCAL_MACHINE\\Software\\Microsoft\\Windows NT\\CurrentVersion\\Fonts]",
            "\"Heiti SC Light (TrueType)\"=\"STHeiti Light.ttc\"",
            "\"Heiti SC Medium (TrueType)\"=\"STHeiti Medium.ttc\""]
        if font != .default {
            lines.append("\"\(font.fullName) (TrueType)\"=\"\(font.file.lastPathComponent)\"")
        }
        lines += ["", "[HKEY_CURRENT_USER\\Software\\Wine\\Fonts\\Replacements]"]
        // Replacements expose missing Windows families to both GDI and DirectWrite,
        // while Wine keeps an application's genuine installed font if it exists.
        for name in ["SimSun", "NSimSun", "SimHei", "FangSong", "KaiTi", "Microsoft YaHei",
                     "Microsoft YaHei UI", "MingLiU", "PMingLiU", "Microsoft JhengHei", "Microsoft JhengHei UI",
                     "\u{5b8b}\u{4f53}", "\u{9ed1}\u{4f53}", "\u{5fae}\u{8f6f}\u{96c5}\u{9ed1}"] {
            lines.append("\"\(name)\"=\"\(font.family)\"")
        }
        lines += ["", "[HKEY_LOCAL_MACHINE\\Software\\Microsoft\\Windows NT\\CurrentVersion\\FontLink\\SystemLink]"]
        let fallback = "\(font.file.lastPathComponent),\(font.family)"
        let families = Set(existingLinks.keys).union(["Tahoma", "Arial", "Arial Unicode MS", "Segoe UI",
            "Microsoft Sans Serif", "Lucida Sans Unicode", "Lucida Console", "Courier New", "Times New Roman", "Verdana"])
        for name in families.sorted() {
            // Keep other scripts' links, but replace Traverse's previous selection.
            let entries = [fallback, "STHeiti Light.ttc,Heiti SC"].reduce(into: [String]()) {
                if !$0.contains($1) { $0.append($1) }
            } + (existingLinks[name] ?? []).filter {
                $0 != fallback && $0 != "STHeiti Light.ttc,Heiti SC" && $0 != previousFontLink
            }
            let value = entries.joined(separator: "\0") + "\0\0"
            let bytes = value.data(using: .utf16LittleEndian)!.map { String(format: "%02x", $0) }.joined(separator: ",")
            let escaped = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            lines.append("\"\(escaped)\"=hex(7):\(bytes)")
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }
}
