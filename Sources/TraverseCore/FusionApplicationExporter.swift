import CoreServices
import CryptoKit
import Foundation

@MainActor
public final class FusionApplicationExporter {
    public let destination: URL
    private let hostBundleURL: URL
    private let helperExecutableURL: URL
    private let iconResolver: ApplicationIconResolver
    private let manager = FileManager.default

    public init(destination: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Applications/Traverse", isDirectory: true),
        hostBundleURL: URL, helperExecutableURL: URL,
        iconResolver: ApplicationIconResolver? = nil) {
        self.destination = destination.standardizedFileURL
        self.hostBundleURL = hostBundleURL
        self.helperExecutableURL = helperExecutableURL
        self.iconResolver = iconResolver ?? ApplicationIconResolver()
    }

    @discardableResult
    public func synchronize(applications: [LauncherApplication]) throws -> [URL] {
        let helper = try Data(contentsOf: helperExecutableURL)
        guard manager.isExecutableFile(atPath: helperExecutableURL.path) else {
            throw TraverseError.message("The Fusion Mode launcher is missing or cannot be opened.")
        }
        let helperDigest = token(helper)
        try manager.createDirectory(at: destination, withIntermediateDirectories: true)
        let existing = try exportedApplications()
        let entries = [Entry(key: "library", name: "Traverse", application: nil)]
            + applications.sorted { $0.id < $1.id }.map {
                Entry(key: "application:\($0.id)", name: $0.name, application: $0)
            }
        let names = entries.map { filename($0.name) }
        let nameCounts = Dictionary(names.map { (nameKey($0), 1) }, uniquingKeysWith: +)
        let existingPaths = Set(existing.map { $0.url.resolvingSymlinksInPath().path })
        let unrelated = try manager.contentsOfDirectory(at: destination,
            includingPropertiesForKeys: nil).filter { !existingPaths.contains($0.resolvingSymlinksInPath().path) }
        var occupied = Set(unrelated.map { nameKey($0.lastPathComponent) })
        var result: [URL] = []
        for (entry, name) in zip(entries, names) {
            let identifier = "org.traverse.launcher.\(token(Data(entry.key.utf8)))"
            let suffix = String(identifier.suffix(10))
            var stem = entry.application == nil || nameCounts[nameKey(name)] == 1
                ? name : "\(name) (\(suffix))"
            if occupied.contains(nameKey(stem + ".app")) { stem = "\(name) (\(suffix))" }
            var number = 2
            while occupied.contains(nameKey(stem + ".app")) {
                stem = "\(name) (\(suffix)-\(number))"
                number += 1
            }
            let bundle = destination.appendingPathComponent(stem + ".app", isDirectory: true)
            occupied.insert(nameKey(bundle.lastPathComponent))
            let icon = entry.application.flatMap { iconResolver.icnsData(for: $0) }
                ?? (entry.application == nil ? hostIcon() : nil)
            var info: [String: Any] = [
                "CFBundleName": entry.name,
                "CFBundleDisplayName": entry.name,
                "CFBundleIdentifier": identifier,
                "CFBundleExecutable": "TraverseLauncher",
                "CFBundlePackageType": "APPL",
                "CFBundleInfoDictionaryVersion": "6.0",
                "CFBundleVersion": "1",
                "CFBundleShortVersionString": "1.0",
                "LSMinimumSystemVersion": "14.0",
                "LSUIElement": true,
                "TraverseManagedLauncher": true,
                "TraverseHostBundlePath": hostBundleURL.path,
                "TraverseLauncherDigest": helperDigest
            ]
            if let application = entry.application {
                info["TraverseApplicationID"] = application.id
            } else {
                info["TraverseAction"] = "library"
            }
            if let icon { info["CFBundleIconFile"] = "Application-\(token(icon).prefix(16)).icns" }
            if !isCurrent(bundle, info: info, icon: icon) {
                try writeBundle(bundle, info: info, icon: icon)
            }
            let status = LSRegisterURL(bundle as CFURL, true)
            guard status == noErr else {
                throw TraverseError.message("The Fusion Mode launcher could not be registered with macOS (\(status)).")
            }
            result.append(bundle)
        }
        let retained = Set(result.map { $0.resolvingSymlinksInPath().path })
        for old in existing where !retained.contains(old.url.resolvingSymlinksInPath().path) {
            try manager.removeItem(at: old.url)
        }
        return result
    }

    public func removeExportedApplications() throws {
        for entry in try exportedApplications() { try manager.removeItem(at: entry.url) }
        if manager.fileExists(atPath: destination.path),
           try manager.contentsOfDirectory(atPath: destination.path).isEmpty {
            try manager.removeItem(at: destination)
        }
    }

    private struct Entry {
        let key: String
        let name: String
        let application: LauncherApplication?
    }

    private func exportedApplications() throws -> [(url: URL, key: String)] {
        guard manager.fileExists(atPath: destination.path) else { return [] }
        return try manager.contentsOfDirectory(at: destination,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]).compactMap { url in
                guard url.pathExtension.lowercased() == "app",
                      let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                      values.isDirectory == true, values.isSymbolicLink != true,
                      let info = readInfo(url), info["TraverseManagedLauncher"] as? Bool == true else { return nil }
                let key: String
                if let id = info["TraverseApplicationID"] as? String {
                    key = "application:\(id)"
                } else if info["TraverseAction"] as? String == "library" {
                    key = "library"
                } else {
                    return nil
                }
                guard info["CFBundleIdentifier"] as? String
                    == "org.traverse.launcher.\(token(Data(key.utf8)))" else { return nil }
                return (url, key)
            }
    }

    private func readInfo(_ bundle: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }

    private func isCurrent(_ bundle: URL, info: [String: Any], icon: Data?) -> Bool {
        guard let existing = readInfo(bundle), NSDictionary(dictionary: existing).isEqual(to: info),
              manager.isExecutableFile(atPath: bundle.appendingPathComponent("Contents/MacOS/TraverseLauncher").path)
        else { return false }
        guard let icon else { return true }
        guard let name = info["CFBundleIconFile"] as? String else { return false }
        return (try? Data(contentsOf: bundle.appendingPathComponent("Contents/Resources/\(name)"))) == icon
    }

    private func writeBundle(_ bundle: URL, info: [String: Any], icon: Data?) throws {
        let temporary = destination.appendingPathComponent(".traverse-\(UUID().uuidString).app", isDirectory: true)
        defer { try? manager.removeItem(at: temporary) }
        let contents = temporary.appendingPathComponent("Contents", isDirectory: true)
        let executable = contents.appendingPathComponent("MacOS/TraverseLauncher")
        try manager.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try manager.copyItem(at: helperExecutableURL, to: executable)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        if let icon, let name = info["CFBundleIconFile"] as? String {
            let resources = contents.appendingPathComponent("Resources", isDirectory: true)
            try manager.createDirectory(at: resources, withIntermediateDirectories: true)
            try icon.write(to: resources.appendingPathComponent(name))
        }
        let signing = Process()
        signing.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        signing.arguments = ["--force", "--sign", "-", "--timestamp=none", temporary.path]
        let output = Pipe()
        signing.standardOutput = output
        signing.standardError = output
        try signing.run()
        let message = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        signing.waitUntilExit()
        guard signing.terminationStatus == 0 else {
            throw TraverseError.message("The Fusion Mode launcher could not be signed. \(message.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        if manager.fileExists(atPath: bundle.path) { try manager.removeItem(at: bundle) }
        try manager.moveItem(at: temporary, to: bundle)
    }

    private func hostIcon() -> Data? {
        guard let info = readInfo(hostBundleURL), let name = info["CFBundleIconFile"] as? String else { return nil }
        let iconName = (name as NSString).pathExtension.isEmpty ? name + ".icns" : name
        return try? Data(contentsOf: hostBundleURL.appendingPathComponent("Contents/Resources/\(iconName)"))
    }

    private func filename(_ name: String) -> String {
        var value = name.components(separatedBy: CharacterSet(charactersIn: "/:")
            .union(.controlCharacters)).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        while value.utf8.count > 180 { value.removeLast() }
        return value.isEmpty ? "Windows Application" : value
    }

    private func nameKey(_ name: String) -> String { name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")) }

    private func token(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
