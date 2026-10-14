import CryptoKit
import CoreServices
import Foundation

@MainActor
enum ApplicationDockIdentity {
    static func environment(for application: LauncherApplication, engine: WineEngine,
                            paths: TraversePaths) throws -> [String: String] {
        let fallbackProcessPath = try processPath(id: application.id, name: application.name,
            engine: engine, paths: paths, application: application)
        guard let helper = Bundle.module.url(forResource: "application-dock-identity",
            withExtension: "dylib", subdirectory: "Resources") else {
            throw TraverseError.message("The Dock helper is missing. Rebuild Traverse with scripts/build-app.sh.")
        }
        var applications = try ApplicationLibrary(paths: paths).applications().filter {
            $0.prefixPath == application.prefixPath && $0.id != application.id
        }
        applications.append(application)
        var rules = Data()
        var keyboardRules = Data()
        let directKeyboardApplications = try TraverseSettings.load(from: paths).directKeyboardApplications
        for entry in applications {
            let target: String?
            if entry.kind == .steamGame {
                target = entry.activationDirectory.map { $0 + "/" }
            } else if entry.kind == .steam, let executable = entry.executablePath {
                target = URL(fileURLWithPath: executable).deletingLastPathComponent().path + "/"
            } else {
                target = entry.executablePath
            }
            guard let target else { continue }
            let identity = try processPath(id: entry.id, name: entry.name,
                engine: engine, paths: paths, application: entry)
            if directKeyboardApplications.contains(entry.id) {
                keyboardRules.append(Data(identity.utf8))
                keyboardRules.append(0)
            }
            var targets = [target, "Z:" + target]
            let drive = URL(fileURLWithPath: entry.prefixPath).appendingPathComponent("drive_c").path + "/"
            if target.hasPrefix(drive) { targets.append("C:/" + target.dropFirst(drive.count)) }
            let devices = URL(fileURLWithPath: entry.prefixPath).appendingPathComponent("dosdevices")
            for device in (try? FileManager.default.contentsOfDirectory(at: devices,
                includingPropertiesForKeys: nil)) ?? [] where device.lastPathComponent.hasSuffix(":") {
                let destination = device.resolvingSymlinksInPath().path + "/"
                if target.hasPrefix(destination) {
                    targets.append(device.lastPathComponent + "/" + target.dropFirst(destination.count))
                }
            }
            let icon = iconPath(processPath: identity)
            for target in targets {
                for field in [target.replacingOccurrences(of: "\\", with: "/"), identity, icon] {
                    rules.append(Data(field.utf8))
                    rules.append(0)
                }
            }
        }
        let token = SHA256.hash(data: Data(application.prefixPath.utf8))
            .map { String(format: "%02x", $0) }.joined()
        let manifest = paths.root.appendingPathComponent("Application Identities/\(token).map")
        try rules.write(to: manifest, options: .atomic)
        let keyboardManifest = manifest.appendingPathExtension("keyboard")
        try keyboardRules.write(to: keyboardManifest, options: .atomic)
        var environment = ["CFProcessPath": fallbackProcessPath, "DYLD_INSERT_LIBRARIES": helper.path,
                "TRAVERSE_DOCK_IDENTITIES": manifest.path,
                "TRAVERSE_DIRECT_KEYBOARD_PROFILE": keyboardManifest.path,
                "TRAVERSE_DOCK_ICON": iconPath(processPath: fallbackProcessPath)]
        if MSyncEngine.managedPaths(for: engine) != nil {
            environment["TRAVERSE_RETINA_MASK_FIX"] = "1"
        }
        return environment
    }

    private static func iconPath(processPath: String) -> String {
        let contents = URL(fileURLWithPath: processPath).deletingLastPathComponent().deletingLastPathComponent()
        guard let data = try? Data(contentsOf: contents.appendingPathComponent("Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String],
              let icon = info["CFBundleIconFile"] else { return "" }
        return contents.appendingPathComponent("Resources/\(icon)").path
    }

    static func processPath(id: String, name: String, engine: WineEngine,
                            paths: TraversePaths, application: LauncherApplication? = nil) throws -> String {
        let token = SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
        let filename = name.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let bundle = paths.root.appendingPathComponent("Application Identities/\(token)/\(filename).app",
                                                      isDirectory: true)
        let contents = bundle.appendingPathComponent("Contents",
                                                        isDirectory: true)
        let executable = contents.appendingPathComponent("MacOS/\(filename)")
        let manager = FileManager.default
        try manager.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        if (try? manager.destinationOfSymbolicLink(atPath: executable.path)) != engine.wine.path {
            if manager.fileExists(atPath: executable.path)
                || (try? manager.destinationOfSymbolicLink(atPath: executable.path)) != nil {
                try manager.removeItem(at: executable)
            }
            try manager.createSymbolicLink(at: executable, withDestinationURL: engine.wine)
        }
        var info: [String: String] = [
            "CFBundleName": name,
            "CFBundleDisplayName": name,
            "CFBundleIdentifier": "org.traverse.application.\(token)",
            "CFBundleExecutable": filename,
            "CFBundlePackageType": "APPL"
        ]
        if let application, let icon = ApplicationIconResolver().icnsData(for: application) {
            let resources = contents.appendingPathComponent("Resources", isDirectory: true)
            try manager.createDirectory(at: resources, withIntermediateDirectories: true)
            let iconToken = SHA256.hash(data: icon).prefix(8).map { String(format: "%02x", $0) }.joined()
            let iconName = "Application-\(iconToken).icns"
            try icon.write(to: resources.appendingPathComponent(iconName), options: .atomic)
            info["CFBundleIconFile"] = iconName
        }
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        let plist = contents.appendingPathComponent("Info.plist")
        if (try? Data(contentsOf: plist)) != data {
            try data.write(to: plist, options: .atomic)
        }
        let status = LSRegisterURL(bundle as CFURL, true)
        guard status == noErr else {
            throw TraverseError.message("The application could not be registered with macOS (\(status)).")
        }
        // CoreFoundation reads CFProcessPath when registering Wine with Launch Services.
        // The engine and its library lookup remain at their original locations.
        return executable.path
    }
}
