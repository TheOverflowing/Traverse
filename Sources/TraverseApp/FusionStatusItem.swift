import AppKit

@MainActor
final class FusionStatusItem: NSObject {
    struct State {
        let busy: Bool
        let activity: String
        let hasError: Bool
    }

    private let item: NSStatusItem
    private let state: () -> State
    private let showLauncher: () -> Void
    private let showSettings: () -> Void
    private let refresh: () -> Void
    private let openApplicationsFolder: () -> Void
    private let showError: () -> Void
    private let quit: () -> Void
    private var trackingMenu: NSMenu?

    init(state: @escaping () -> State,
         showLauncher: @escaping () -> Void,
         showSettings: @escaping () -> Void,
         refresh: @escaping () -> Void,
         openApplicationsFolder: @escaping () -> Void,
         showError: @escaping () -> Void,
         quit: @escaping () -> Void) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.state = state
        self.showLauncher = showLauncher
        self.showSettings = showSettings
        self.refresh = refresh
        self.openApplicationsFolder = openApplicationsFolder
        self.showError = showError
        self.quit = quit
        super.init()
        if let button = item.button {
            button.image = Self.foldImage()
            button.toolTip = "Traverse"
            button.setAccessibilityLabel("Traverse")
            button.target = self
            button.action = #selector(openMenu(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    func remove() {
        trackingMenu?.cancelTracking()
        item.button?.target = nil
        NSStatusBar.system.removeStatusItem(item)
    }

    @objc private func openMenu(_ sender: NSStatusBarButton) {
        let menu = makeMenu()
        trackingMenu = menu
        sender.highlight(true)
        defer {
            sender.highlight(false)
            trackingMenu = nil
        }
        // Accessory apps must own menu tracking so a click outside the menu
        // dismisses it even while the library window is hidden.
        NSApp.activate(ignoringOtherApps: true)
        let edge = sender.isFlipped ? sender.bounds.maxY : sender.bounds.minY
        menu.popUp(positioning: nil, at: NSPoint(x: sender.bounds.minX, y: edge), in: sender)
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let current = state()
        if current.busy {
            let activity = NSMenuItem(title: current.activity.isEmpty ? "Opening…" : current.activity,
                                      action: nil, keyEquivalent: "")
            activity.isEnabled = false
            menu.addItem(activity)
            menu.addItem(.separator())
        }
        add("Open Traverse", action: #selector(openLauncher), to: menu)
        add("Settings…", action: #selector(openSettings), key: ",", to: menu)
        add("Refresh Applications", action: #selector(refreshApplications), to: menu)
        add("Open Applications Folder", action: #selector(openFolder), to: menu)
        if current.hasError { add("Show Error…", action: #selector(openError), to: menu) }
        menu.addItem(.separator())
        add("Quit Traverse", action: #selector(quitTraverse), key: "q", to: menu)
        return menu
    }

    private func add(_ title: String, action: Selector, key: String = "", to menu: NSMenu) {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        entry.target = self
        menu.addItem(entry)
    }

    @objc private func openLauncher() { showLauncher() }
    @objc private func openSettings() { showSettings() }
    @objc private func refreshApplications() { refresh() }
    @objc private func openFolder() { openApplicationsFolder() }
    @objc private func openError() { showError() }
    @objc private func quitTraverse() { quit() }

    static func foldImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let transform = AffineTransform(translationByX: 1, byY: 1)
            var scale = AffineTransform(scaleByX: 0.16, byY: 0.16)
            scale.append(transform)
            NSColor.black.setFill()

            let upper = NSBezierPath()
            upper.move(to: NSPoint(x: 3, y: 46))
            upper.curve(to: NSPoint(x: 10, y: 59), controlPoint1: NSPoint(x: 3, y: 51), controlPoint2: NSPoint(x: 6, y: 54))
            upper.line(to: NSPoint(x: 42, y: 94))
            upper.curve(to: NSPoint(x: 53, y: 99), controlPoint1: NSPoint(x: 45, y: 97), controlPoint2: NSPoint(x: 49, y: 99))
            upper.line(to: NSPoint(x: 93, y: 99))
            upper.curve(to: NSPoint(x: 98, y: 89), controlPoint1: NSPoint(x: 99, y: 99), controlPoint2: NSPoint(x: 102, y: 94))
            upper.line(to: NSPoint(x: 80, y: 63))
            upper.curve(to: NSPoint(x: 69, y: 57), controlPoint1: NSPoint(x: 78, y: 59), controlPoint2: NSPoint(x: 75, y: 57))
            upper.line(to: NSPoint(x: 36, y: 57))
            upper.curve(to: NSPoint(x: 3, y: 46), controlPoint1: NSPoint(x: 20, y: 57), controlPoint2: NSPoint(x: 8, y: 56))
            upper.close()
            upper.transform(using: scale)
            upper.fill()

            let lower = NSBezierPath()
            lower.move(to: NSPoint(x: 5, y: 41))
            lower.curve(to: NSPoint(x: 10, y: 31), controlPoint1: NSPoint(x: 4, y: 38), controlPoint2: NSPoint(x: 6, y: 35))
            lower.line(to: NSPoint(x: 34, y: 7))
            lower.curve(to: NSPoint(x: 44, y: 2), controlPoint1: NSPoint(x: 37, y: 3), controlPoint2: NSPoint(x: 40, y: 2))
            lower.line(to: NSPoint(x: 76, y: 2))
            lower.curve(to: NSPoint(x: 84, y: 19), controlPoint1: NSPoint(x: 91, y: 2), controlPoint2: NSPoint(x: 91, y: 12))
            lower.line(to: NSPoint(x: 43, y: 51))
            lower.line(to: NSPoint(x: 31, y: 51))
            lower.curve(to: NSPoint(x: 5, y: 41), controlPoint1: NSPoint(x: 19, y: 51), controlPoint2: NSPoint(x: 8, y: 48))
            lower.close()
            lower.transform(using: scale)
            lower.fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Traverse"
        return image
    }
}
