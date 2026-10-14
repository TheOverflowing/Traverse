import AppKit
import Foundation

@MainActor
final class LauncherDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let info = Bundle.main.infoDictionary ?? [:]
        guard let hostPath = info["TraverseHostBundlePath"] as? String,
              FileManager.default.fileExists(atPath: hostPath) else {
            finish(error: "Traverse could not be found. Open Traverse and turn Fusion Mode on again.")
            return
        }

        let isLibrary = info["TraverseAction"] as? String == "library"
        var request = URLComponents()
        request.scheme = "traverse"
        request.host = isLibrary ? "library" : "launch"
        if !isLibrary {
            guard let applicationID = info["TraverseApplicationID"] as? String, !applicationID.isEmpty else {
                finish(error: "This shortcut has no application. Open Traverse to recreate it.")
                return
            }
            request.queryItems = [URLQueryItem(name: "id", value: applicationID)]
        }
        guard let url = request.url else {
            finish(error: "This shortcut could not be opened. Open Traverse to recreate it.")
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = isLibrary
        configuration.addsToRecentItems = false
        NSWorkspace.shared.open([url], withApplicationAt: URL(fileURLWithPath: hostPath),
                                configuration: configuration) { _, error in
            Task { @MainActor in
                self.finish(error: error?.localizedDescription)
            }
        }
    }

    private func finish(error: String?) {
        if let error {
            let alert = NSAlert()
            alert.messageText = "Unable to open Traverse"
            alert.informativeText = error
            alert.alertStyle = .warning
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
        NSApp.terminate(nil)
    }
}

let application = NSApplication.shared
let delegate = LauncherDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
