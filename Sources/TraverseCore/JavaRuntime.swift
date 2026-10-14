import CryptoKit
import Foundation

public actor JavaRuntime {
    public static let version = "17.0.20.1+1"
    public static let archiveName = "OpenJDK17U-jre_x64_windows_hotspot_17.0.20.1_1.zip"
    public static let archiveURL = URL(string: "https://github.com/adoptium/temurin17-binaries/releases/download/jdk-17.0.20.1%2B1/\(archiveName)")!
    public static let sha256 = "bc21a93923103cdaac93ee337b0ae4365e739fde36df823dd456bc67c8a9d352"
    private let paths: TraversePaths
    private var preparation: Task<URL, Error>?

    public init(paths: TraversePaths) { self.paths = paths }

    static func directory(in paths: TraversePaths) -> URL {
        paths.root.appendingPathComponent("Runtimes/Java/temurin-\(version)", isDirectory: true)
    }

    static func installed(in paths: TraversePaths) -> URL? {
        let root = directory(in: paths)
        let jre = root.appendingPathComponent("jdk-\(version)-jre", isDirectory: true)
        let required = ["bin/java.exe", "bin/javaw.exe", "bin/server/jvm.dll", "lib/modules",
                        "legal/java.base/LICENSE", "release"]
        guard (try? String(contentsOf: root.appendingPathComponent(".traverse-ready"), encoding: .utf8)) == sha256,
              required.allSatisfy({ FileManager.default.fileExists(atPath: jre.appendingPathComponent($0).path) }) else {
            return nil
        }
        return jre.appendingPathComponent("bin/java.exe")
    }

    static func verify(_ archive: URL) throws {
        let data = try Data(contentsOf: archive, options: .mappedIfSafe)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == sha256 else {
            throw TraverseError.message("The Java runtime download failed verification. Remove \(archive.lastPathComponent) from Downloads and try again.")
        }
    }

    public func executable(progress: @escaping @Sendable (String) async -> Void = { _ in }) async throws -> URL {
        if let installed = Self.installed(in: paths) { return installed }
        if let preparation { return try await preparation.value }
        let paths = paths
        let task = Task<URL, Error> {
            try paths.prepare()
            let archive = paths.downloads.appendingPathComponent(Self.archiveName)
            if !FileManager.default.fileExists(atPath: archive.path) {
                await progress("Downloading Java…")
                try await WineEngine.download(Self.archiveURL, to: archive)
            }
            await progress("Preparing Java…")
            try Self.verify(archive)
            let destination = Self.directory(in: paths)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let result = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/ditto"),
                arguments: ["-x", "-k", archive.path, destination.path],
                log: paths.logs.appendingPathComponent("java-install.log"))
            guard result.status == 0 else {
                throw TraverseError.message("Java could not be unpacked. Open java-install.log in Logs for details.")
            }
            let marker = destination.appendingPathComponent(".traverse-ready")
            try Data(Self.sha256.utf8).write(to: marker, options: .atomic)
            guard let executable = Self.installed(in: paths) else {
                try FileManager.default.removeItem(at: marker)
                throw TraverseError.message("The Java runtime is incomplete. Install Java again by reopening the application.")
            }
            return executable
        }
        preparation = task
        defer { preparation = nil }
        return try await task.value
    }

    static func arguments(java: URL, archive: URL, prefix: URL, arguments: [String], fontDirectory: URL? = nil,
                          hostFontDirectory: URL = URL(fileURLWithPath: "/System/Library/Fonts"),
                          textFont: WindowsTextFont? = nil) throws -> [String] {
        guard let windowsPath = ApplicationActivation.windowsPath(for: archive, prefix: prefix) else {
            throw TraverseError.message("The Java application is outside this Windows environment's mapped drives.")
        }
        var options: [String] = []
        var fontPaths: [String] = []
        // Wine can expose host fonts through GDI while C:\windows\Fonts is empty.
        // Swing also needs a physical TrueType directory for its font manager.
        if let fontDirectory,
           FileManager.default.fileExists(atPath: fontDirectory.appendingPathComponent("tahoma.ttf").path),
           let fonts = ApplicationActivation.windowsPath(for: fontDirectory, prefix: prefix) {
            fontPaths.append(fonts)
        }
        let template = java.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("lib/fontconfig.properties.src")
        let configuration = template.deletingLastPathComponent().appendingPathComponent("traverse-fontconfig.properties")
        let chineseFontDirectory = textFont?.file.deletingLastPathComponent() ?? hostFontDirectory
        let chineseFontFile = textFont?.file.lastPathComponent ?? "STHeiti Light.ttc"
        let chineseFontName = textFont?.fullName ?? "Heiti SC Light"
        if FileManager.default.fileExists(atPath: chineseFontDirectory.appendingPathComponent(chineseFontFile).path),
           FileManager.default.fileExists(atPath: template.path),
           let hostFonts = ApplicationActivation.windowsPath(for: chineseFontDirectory, prefix: prefix),
           let configPath = ApplicationActivation.windowsPath(for: configuration, prefix: prefix) {
            let original = try String(contentsOf: template, encoding: .utf8)
            // Preserve the shipped configuration and its license. Windows Java expects
            // a basename here and resolves it against its font directories.
            let mappings = try NSRegularExpression(pattern:
                "(?m)^((?:allfonts|serif|sansserif|monospaced|dialog|dialoginput)\\.[^=\\n]*chinese-[^=\\n]*)=.*$")
            var configured = mappings.stringByReplacingMatches(in: original,
                range: NSRange(original.startIndex..., in: original),
                withTemplate: "$1=\(NSRegularExpression.escapedTemplate(for: chineseFontName))")
                + "\nfilename.\(chineseFontName.replacingOccurrences(of: " ", with: "_"))=\(chineseFontFile)\n"
            if let textFont, textFont != .default,
               let backupFonts = ApplicationActivation.windowsPath(for: WindowsTextFont.default.file.deletingLastPathComponent(), prefix: prefix) {
                // Some host faces have narrower coverage in Java's bold/italic
                // variants. Keep a separate, standard Chinese fallback component.
                configured += "allfonts.chinese-gb18030=Heiti SC Light\nfilename.Heiti_SC_Light=STHeiti Light.ttc\n"
                fontPaths.append(backupFonts)
            }
            if (try? String(contentsOf: configuration, encoding: .utf8)) != configured {
                try configured.write(to: configuration, atomically: true, encoding: .utf8)
            }
            fontPaths.append(hostFonts)
            options.append("-Dsun.awt.fontconfig=\(configPath)")
        }
        if !fontPaths.isEmpty {
            options.insert("-Dsun.java2d.fontpath=append:\(fontPaths.joined(separator: ";"))", at: 0)
        }
        return [java.path] + options + ["-jar", windowsPath] + arguments
    }
}
