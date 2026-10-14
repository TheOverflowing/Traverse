import AppKit
import SwiftUI
import TraverseCore
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()
    let runtime: SteamRuntime
    let applicationsRuntime: WindowsApplicationRuntime
    let library: ApplicationLibrary
    let icons = ApplicationIconResolver()
    var draggingItemID: String?
    @Published var applications: [LauncherApplication] = []
    @Published var layout = LauncherLayout()
    @Published var libraryLoaded = false
    @Published var status: RuntimeStatus?
    @Published var busy = false {
        didSet { if !busy { processNextExternalOpen() } }
    }
    @Published var openingID: String?
    @Published var activity = ""
    @Published var error: String? {
        didSet {
            if let error, error != oldValue, fusionMode { onBackgroundError?(error) }
        }
    }
    @Published var rendering = SteamRendering.software
    @Published var msync = false
    @Published var graphicsBackend = GraphicsBackend.automatic
    @Published var frameRateLimit: Int?
    @Published var windowsTextFont = ""
    @Published var retinaMode = false
    @Published var gameSupport: GameSupportStatus?
    @Published var showingAdd = false
    @Published var showingSettings = false
    @Published var showingInstall = false
    @Published var graphicsApplication: LauncherApplication?
    @Published var iconApplication: LauncherApplication?
    @Published var focusSearch = false
    @Published private(set) var fusionMode = false
    var showLauncher: (() -> Void)?
    var showSettings: (() -> Void)?
    var onFusionModeChanged: ((Bool) -> Void)?
    var onBackgroundError: ((String) -> Void)?
    private var pendingOpens: [ApplicationOpenRequest] = []
    private var readyForExternalOpens = false
    private lazy var fusionExporter = FusionApplicationExporter(hostBundleURL: Bundle.main.bundleURL,
        helperExecutableURL: Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/TraverseLauncher"),
        iconResolver: icons)
    private lazy var fusionAssociations = FusionFileAssociations(paths: runtime.paths, hostBundleURL: Bundle.main.bundleURL)
    private lazy var iconCustomization = ApplicationIconCustomization(paths: runtime.paths)

    var engineName: String {
        guard let status else { return "MSync Wine" }
        if status.enginePath == MSyncEngine.engine(in: runtime.paths).wine.path || status.msync {
            return "MSync Wine"
        }
        return status.enginePath == WineEngine.managed(in: runtime.paths).wine.path ? "Wine 11.0" : "Custom Wine"
    }

    init() {
        let steam = SteamRuntime()
        runtime = steam
        applicationsRuntime = WindowsApplicationRuntime(steam: steam)
        library = ApplicationLibrary(paths: steam.paths)
        do { fusionMode = try TraverseSettings.load(from: steam.paths).fusionMode }
        catch { self.error = error.localizedDescription }
        do { layout = try LauncherLayout.load(from: steam.paths) }
        catch { self.error = error.localizedDescription }
    }

    func refresh() async {
        defer { libraryLoaded = true }
        do {
            status = try await runtime.status()
            rendering = status?.rendering ?? .software
            msync = status?.msync ?? false
            graphicsBackend = status?.graphicsBackend ?? .automatic
            frameRateLimit = status?.frameRateLimit
            windowsTextFont = status?.windowsTextFont ?? ""
            retinaMode = status?.retinaMode ?? false
            gameSupport = await runtime.gameSupportStatus()
            let library = library
            applications = try await Task.detached(priority: .userInitiated) { try library.applications() }.value
            try synchronizeLayout()
            if fusionMode { try fusionExporter.synchronize(applications: applications) }
        } catch { self.error = error.localizedDescription }
    }

    func start() async {
        await refresh()
        readyForExternalOpens = true
        processNextExternalOpen()
    }

    func openExternal(_ urls: [URL]) {
        for url in urls {
            do {
                switch try ApplicationOpenRequest(url: url) {
                case .library: showLauncher?()
                case .settings: showSettings?()
                case let request: pendingOpens.append(request)
                }
            } catch { self.error = error.localizedDescription }
        }
        processNextExternalOpen()
    }

    private func processNextExternalOpen() {
        guard readyForExternalOpens, !busy, !pendingOpens.isEmpty else { return }
        let request = pendingOpens.removeFirst()
        perform {
            let application: LauncherApplication
            switch request {
            case .application(let id):
                guard let current = try self.library.applications().first(where: { $0.id == id }) else {
                    throw TraverseError.message("This application is no longer in Traverse. Refresh Applications in Settings.")
                }
                application = current
            case .file(let url):
                application = try self.library.applicationForOpening(at: url)
            case .library, .settings: return
            }
            if application.kind == .steam, application.prefixPath == self.runtime.paths.prefix.path,
               self.status?.steamInstalled != true {
                self.showLauncher?()
                self.showingInstall = true
                return
            }
            try await self.openApplication(application)
        }
    }

    func setFusionMode(_ enabled: Bool) {
        guard enabled != fusionMode else { return }
        perform {
            if enabled {
                do {
                    try self.fusionExporter.synchronize(applications: self.applications)
                    try await self.fusionAssociations.enable()
                    try await self.runtime.setFusionMode(true)
                } catch {
                    let originalError = error
                    var cleanupErrors: [String] = []
                    do { try self.fusionExporter.removeExportedApplications() }
                    catch { cleanupErrors.append(error.localizedDescription) }
                    if !cleanupErrors.isEmpty {
                        throw TraverseError.message(originalError.localizedDescription + " " + cleanupErrors.joined(separator: " "))
                    }
                    throw originalError
                }
            } else {
                var cleanupErrors: [String] = []
                do { try self.fusionExporter.removeExportedApplications() }
                catch { cleanupErrors.append(error.localizedDescription) }
                try await self.runtime.setFusionMode(false)
                self.fusionMode = false
                self.onFusionModeChanged?(false)
                if !cleanupErrors.isEmpty { throw TraverseError.message(cleanupErrors.joined(separator: " ")) }
                return
            }
            self.fusionMode = true
            self.onFusionModeChanged?(true)
        }
    }

    func openFusionFolder() { NSWorkspace.shared.open(fusionExporter.destination) }

    func setIconPreset(_ preset: ApplicationIconPreset, for application: LauncherApplication) throws {
        _ = try iconCustomization.setPreset(preset, for: application)
        try refreshIcons()
    }

    func importIcon(at url: URL, for application: LauncherApplication) throws {
        _ = try iconCustomization.importImage(at: url, for: application)
        try refreshIcons()
    }

    func resetIcon(for application: LauncherApplication) throws {
        _ = try iconCustomization.reset(for: application)
        try refreshIcons()
    }

    private func refreshIcons() throws {
        icons.clearCache()
        applications = try library.applications()
        if fusionMode { try fusionExporter.synchronize(applications: applications) }
    }

    func launch(_ application: LauncherApplication, debug: Bool = false) {
        if application.kind == .steam, application.prefixPath == runtime.paths.prefix.path,
           status?.steamInstalled != true {
            showingInstall = true
            return
        }
        perform { try await self.openApplication(application, debug: debug) }
    }

    private func openApplication(_ application: LauncherApplication, debug: Bool = false) async throws {
        openingID = application.id
        defer { openingID = nil }
        _ = try await applicationsRuntime.launch(application, debug: debug, progress: { message in
                await MainActor.run { self.activity = message }
            }, onExit: { status, log in
                await MainActor.run {
                    if status != 0 {
                        self.error = "\(application.name) closed with an error (exit \(status)). Check \(URL(fileURLWithPath: log).lastPathComponent) in Logs."
                    }
                }
                await self.refresh()
        })
    }

    func add(url: URL, name: String, open: Bool) throws {
        let application = try library.addExecutable(at: url, name: name)
        applications = try library.applications()
        try synchronizeLayout()
        if fusionMode { try fusionExporter.synchronize(applications: applications) }
        if open { launch(application) }
    }

    func remove(_ application: LauncherApplication) {
        do {
            try library.remove(id: application.id)
            applications = try library.applications()
            try synchronizeLayout()
            if fusionMode { try fusionExporter.synchronize(applications: applications) }
        } catch { self.error = error.localizedDescription }
    }

    func install() {
        showingInstall = false
        perform {
            try await self.runtime.installSteam { message in
                await MainActor.run { self.activity = message }
            }
        }
    }

    func moveItem(_ id: String, to slot: Int) {
        updateLayout { $0.move(itemID: id, to: slot) }
    }

    func moveItem(_ id: String, toPage page: Int) {
        if let slot = layout.placements[id], slot / LauncherLayout.capacity == page { return }
        let start = page * LauncherLayout.capacity
        let slot = (start..<(start + LauncherLayout.capacity)).first { layout.itemID(at: $0) == nil } ?? start
        moveItem(id, to: slot)
    }

    func deleteEmptyPage(_ page: Int) -> Bool {
        updateLayout(animated: false) { $0.deleteEmptyPage(page) }
    }

    @discardableResult
    func groupApplication(_ id: String, on target: String) -> String? {
        guard applications.contains(where: { $0.id == id }), id != target else { return nil }
        if layout.folder(id: target)?.applicationIDs.contains(id) == true { return target }
        var folderID: String?
        let saved = updateLayout { next in
            if next.folder(id: target) != nil {
                next.add(applicationID: id, toFolder: target)
                folderID = target
            } else {
                folderID = next.createFolder(applicationID: id, on: target)
            }
        }
        return saved ? folderID : nil
    }

    func renameFolder(_ id: String, name: String) {
        updateLayout(animated: false) { $0.renameFolder(id: id, name: name) }
    }

    func reorderApplication(_ id: String, inFolder folder: String, to index: Int) {
        updateLayout { $0.reorder(applicationID: id, inFolder: folder, to: index) }
    }

    func moveOutOfFolder(_ id: String) {
        guard let folderID = layout.folderID(containing: id), let position = layout.placements[folderID] else { return }
        let start = position / LauncherLayout.capacity * LauncherLayout.capacity
        let slot = (start..<(start + LauncherLayout.capacity)).first { layout.itemID(at: $0) == nil }
            ?? (0...).first { layout.itemID(at: $0) == nil }!
        moveItem(id, to: slot)
    }

    func dissolveFolder(_ id: String) { updateLayout { $0.dissolveFolder(id: id) } }

    @discardableResult
    private func updateLayout(animated: Bool = true, _ change: (inout LauncherLayout) -> Void) -> Bool {
        var next = layout
        change(&next)
        guard next != layout else { return false }
        do {
            try next.save(to: runtime.paths)
            let animation: Animation? = animated && draggingItemID == nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                ? .spring(response: 0.26, dampingFraction: 1) : nil
            var transaction = Transaction(animation: animation)
            transaction.disablesAnimations = draggingItemID != nil
            withTransaction(transaction) { layout = next }
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    private func synchronizeLayout() throws {
        if layout.reconcile(applicationIDs: applications.map(\.id)) {
            try layout.save(to: runtime.paths)
        }
    }

    func enableGameSupport() {
        perform {
            try await self.runtime.installGameSupport { message in
                await MainActor.run { self.activity = message }
            }
        }
    }

    func saveRendering() {
        perform { try await self.runtime.setRendering(self.rendering) }
    }

    func chooseEngine() {
        let panel = NSOpenPanel()
        panel.title = "Choose Wine"
        panel.message = "Select the wine executable in your engine’s bin folder."
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.directoryURL = runtime.paths.engines
        if panel.runModal() == .OK, let url = panel.url {
            perform { try await self.runtime.setEngine(url) }
        }
    }

    func useManagedEngine() { perform { try await self.runtime.setEngine(nil) } }

    func saveMSync() { perform { try await self.runtime.setMSync(self.msync) } }

    func saveGraphicsBackend() { perform { try await self.runtime.setGraphicsBackend(self.graphicsBackend) } }

    func saveFrameRateLimit() { perform { try await self.runtime.setFrameRateLimit(self.frameRateLimit) } }

    func saveRetinaMode() { perform { try await self.runtime.setRetinaMode(self.retinaMode) } }

    func saveWindowsTextFont() {
        let selection = windowsTextFont.isEmpty ? nil : windowsTextFont
        perform {
            try await self.runtime.setWindowsTextFont(selection) { message in
                await MainActor.run { self.activity = message }
            }
        }
    }

    func installMSyncEngine() {
        perform {
            try await self.runtime.installMSyncEngine { message in
                await MainActor.run { self.activity = message }
            }
        }
    }

    func openLogs() {
        do { try runtime.paths.prepare(); NSWorkspace.shared.open(runtime.paths.logs) }
        catch { self.error = error.localizedDescription }
    }

    func reveal(_ application: LauncherApplication) {
        if let path = application.executablePath {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
    }

    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true
        error = nil
        Task {
            defer { activity = ""; busy = false }
            do { try await action() }
            catch { self.error = error.localizedDescription }
            await refresh()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel.shared
    private var launcherWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var statusItem: FusionStatusItem?
    private var receivedExternalOpen = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        configureMainMenu()
        model.showLauncher = { [weak self] in self?.showLauncher() }
        model.showSettings = { [weak self] in self?.showSettings() }
        model.onFusionModeChanged = { [weak self] enabled in self?.applyFusionMode(enabled) }
        model.onBackgroundError = { [weak self] message in
            guard let self, self.launcherWindow?.isVisible != true, self.settingsWindow?.isVisible != true else { return }
            Task { @MainActor in self.showError(message) }
        }
        NSApp.setActivationPolicy(model.fusionMode ? .accessory : .regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Read the bundled artwork directly when macOS caches an older icon.
        if let filename = Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") as? String,
           let url = Bundle.main.resourceURL?.appendingPathComponent(filename),
           let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
        if model.fusionMode { applyFusionMode(true, hideWindows: false) }
        else if !receivedExternalOpen { showLauncher() }
        Task { await model.start() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showLauncher()
        return false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // SwiftUI can consume a Dock reopen event before forwarding it to the
        // delegate. Activation must also restore the launcher's window order.
        if !model.fusionMode, launcherWindow?.isVisible == true,
           settingsWindow?.isVisible != true { raiseLauncher() }
        Task { await model.refresh() }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        receivedExternalOpen = true
        model.openExternal(urls)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private func applyFusionMode(_ enabled: Bool, hideWindows: Bool = true) {
        NSApp.setActivationPolicy(enabled ? .accessory : .regular)
        if enabled {
            if statusItem == nil {
                let model = model
                statusItem = FusionStatusItem(
                    state: { .init(busy: model.busy, activity: model.activity, hasError: model.error != nil) },
                    showLauncher: { [weak self] in self?.showLauncher() },
                    showSettings: { [weak self] in self?.showSettings() },
                    refresh: { [weak self] in self?.refreshApplications() },
                    openApplicationsFolder: { model.openFusionFolder() },
                    showError: { [weak self] in self?.showCurrentError() },
                    quit: { NSApp.terminate(nil) })
            }
            if hideWindows {
                model.showingSettings = false
                launcherWindow?.orderOut(nil)
                settingsWindow?.orderOut(nil)
            }
        } else {
            statusItem?.remove()
            statusItem = nil
            if NSApp.isRunning { showLauncher() }
        }
    }

    @objc func showLauncher() {
        if launcherWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1160, height: 760),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false)
            window.title = "Traverse"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.minSize = NSSize(width: 800, height: 580)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: LaunchpadView(model: model).frame(minWidth: 800, minHeight: 580))
            window.center()
            launcherWindow = window
        }
        raiseLauncher()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func raiseLauncher() {
        guard let window = launcherWindow else { return }
        // Covered and minimized windows still count as visible in a reopen event.
        // Raise the existing launcher rather than relying on that visibility flag.
        if NSApp.isHidden { NSApp.unhide(nil) }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }

    @objc func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 550, height: 650),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Traverse Settings"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: LauncherSettingsView(model: model, onDone: { [weak window] in window?.close() }))
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func addMenuItem(_ title: String, action: Selector, key: String = "", to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
    }

    @objc private func refreshApplications() { Task { await model.refresh() } }
    @objc private func openApplicationsFolder() { model.openFusionFolder() }
    @objc private func showCurrentError() { if let error = model.error { showError(error) } }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func addApplication() { showLauncher(); model.showingAdd = true }
    @objc private func searchApplications() { showLauncher(); model.focusSearch = true }
    @objc private func openLogs() { model.openLogs() }

    private func configureMainMenu() {
        let main = NSMenu()
        let application = NSMenu(title: "Traverse")
        application.addItem(withTitle: "About Traverse", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        application.addItem(.separator())
        addMenuItem("Settings…", action: #selector(showSettings), key: ",", to: application)
        application.addItem(.separator())
        let services = NSMenu(title: "Services")
        let servicesItem = application.addItem(withTitle: "Services", action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        NSApp.servicesMenu = services
        application.addItem(.separator())
        application.addItem(withTitle: "Hide Traverse", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = application.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        application.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        application.addItem(.separator())
        addMenuItem("Quit Traverse", action: #selector(quit), key: "q", to: application)

        let file = NSMenu(title: "File")
        addMenuItem("Add Application…", action: #selector(addApplication), key: "o", to: file)
        addMenuItem("Search Applications", action: #selector(searchApplications), key: "f", to: file)
        addMenuItem("Refresh Applications", action: #selector(refreshApplications), key: "r", to: file)
        addMenuItem("Open Logs", action: #selector(openLogs), to: file)
        file.addItem(.separator())
        file.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        let edit = NSMenu(title: "Edit")
        for (title, action, key) in [("Undo", "undo:", "z"), ("Cut", "cut:", "x"),
                                     ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            edit.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.insertItem(redo, at: 1)

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = window
        for submenu in [application, file, edit, window] {
            let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
            item.submenu = submenu
            main.addItem(item)
        }
        NSApp.mainMenu = main
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Traverse"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

@main
struct TraverseApp {
    @MainActor static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}

private enum LauncherItem {
    case application(LauncherApplication)
    case folder(LauncherFolder)

    var id: String {
        switch self {
        case let .application(application): application.id
        case let .folder(folder): folder.id
        }
    }
}

private struct LaunchpadView: View {
    @ObservedObject var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var query = ""
    @State private var page = 0
    @State private var previewPageCount = 1
    @State private var swipe = PageSwipeState()
    @State private var slideOffset: CGFloat = 0
    @State private var slidePresentation = PageSlidePresentation()
    @State private var deckWidth: CGFloat = 1
    @State private var settlement = 0
    @State private var lastMovement: ContinuousClock.Instant?
    @State private var mouseTranslation: CGFloat = 0
    @State private var mouseTime: Date?
    @State private var openFolderID: String?
    @State private var editingFolderName = false
    @StateObject private var iconDrag = LauncherIconDrag()
    @Namespace private var arrangementNamespace
    @FocusState private var searching: Bool
    @FocusState private var focusedItem: String?

    private var filtered: [LauncherApplication] {
        model.applications.filter { application in
            query.isEmpty || application.name.localizedStandardContains(query)
        }.sorted { (model.layout.position(of: $0.id) ?? Int.max) < (model.layout.position(of: $1.id) ?? Int.max) }
    }

    private var arranging: Bool { query.isEmpty }
    private var savedPageCount: Int { model.layout.pageCount(for: model.applications.map(\.id)) }
    private var displayedPageCount: Int {
        arranging ? max(savedPageCount, previewPageCount)
            : max(1, (filtered.count + LauncherLayout.capacity - 1) / LauncherLayout.capacity)
    }

    var body: some View {
        GeometryReader { geometry in
            let pageCount = arranging ? max(savedPageCount, previewPageCount)
                : max(1, (filtered.count + LauncherLayout.capacity - 1) / LauncherLayout.capacity)
            let currentPage = min(page, pageCount - 1)
            let indicatorPage = reduceMotion ? currentPage : min(max(currentPage
                - Int((slideOffset / max(1, deckWidth)).rounded()), 0), pageCount - 1)
            let showsPageDeletion = pageCount > 1 && model.layout.isPageEmpty(indicatorPage)
            let iconSize = min(88, max(72, (geometry.size.width - 144) / 6 - 28))
            VStack(spacing: 0) {
                header
                if !model.libraryLoaded {
                    ProgressView("Loading applications…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if filtered.isEmpty {
                    emptyState.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    applicationDeck(page: currentPage, iconSize: iconSize)
                }
                if arranging || pageCount > 1 {
                    HStack(spacing: 4) {
                        ForEach(0..<pageCount, id: \.self) { index in
                            LauncherDropTarget(enabled: arranging, currentApplication: { model.draggingItemID }, hover: { selectPage(index, animated: true) }, receive: { id in
                                model.moveItem(id, toPage: index)
                                setPageInstantly(index)
                            }) { targeted in
                                Button { selectPage(index, animated: true) } label: {
                                    Circle().fill(.white.opacity(index == indicatorPage || targeted ? 0.95 : 0.3))
                                        .frame(width: 7, height: 7).padding(9)
                                }.buttonStyle(.plain)
                                    .accessibilityLabel("Page \(index + 1) of \(pageCount)")
                                    .accessibilityAddTraits(index == indicatorPage ? .isSelected : [])
                                    .help("Page \(index + 1) · Drag here to move an application")
                            }
                        }
                        if arranging {
                            ZStack(alignment: .leading) {
                                if showsPageDeletion {
                                    Button { deletePage(indicatorPage) } label: {
                                        Image(systemName: "minus").font(.system(size: 10, weight: .semibold))
                                            .frame(width: 25, height: 25)
                                            .contentShape(Rectangle())
                                    }.buttonStyle(.plain)
                                        .foregroundStyle(.white.opacity(0.5))
                                        .disabled(model.busy)
                                        .accessibilityLabel("Delete Current Page")
                                        .help("Delete Current Page")
                                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.9)))
                                }
                                LauncherDropTarget(enabled: !model.busy, currentApplication: { model.draggingItemID }, hover: {
                                    previewPageCount = pageCount + 1
                                    selectPage(pageCount, animated: true)
                                }, receive: { id in
                                    model.moveItem(id, toPage: pageCount)
                                    previewPageCount = pageCount + 1
                                    setPageInstantly(pageCount)
                                }) { targeted in
                                    Button { previewPageCount = pageCount + 1; selectPage(pageCount, animated: true) } label: {
                                        Image(systemName: "plus").font(.system(size: 10, weight: .semibold))
                                            .foregroundStyle(.white.opacity(targeted ? 1 : 0.5))
                                            .frame(width: 25, height: 25)
                                            .background(.white.opacity(targeted ? 0.12 : 0), in: Circle())
                                    }.buttonStyle(.plain).help("New Page · Drag here to create a page")
                                        .accessibilityLabel("New Page")
                                }.offset(x: showsPageDeletion ? 29 : 0)
                            }.frame(width: 54, height: 25, alignment: .leading)
                                .animation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 1), value: showsPageDeletion)
                                .transaction { transaction in
                                    // Page rebasing disables deck animation; these controls keep their own transition.
                                    if !reduceMotion { transaction.disablesAnimations = false }
                                }

                        }
                    }.padding(.bottom, 10)
                }
                footer.padding(.bottom, 22)
            }
            .padding(.horizontal, 42).padding(.top, 26)
            .opacity(openFolderID == nil ? 1 : 0)
            .allowsHitTesting(openFolderID == nil)
            .disabled(openFolderID != nil)
            .accessibilityHidden(openFolderID != nil)
            .onMoveCommand { direction in
                moveFocus(direction)
            }
        }
        .background { LauncherBackdrop() }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $model.showingAdd) { AddApplicationView(model: model) }
        .sheet(isPresented: $model.showingSettings) { LauncherSettingsView(model: model) }
        .sheet(isPresented: $model.showingInstall) { installSheet }
        .sheet(item: $model.graphicsApplication) { application in
            ApplicationGraphicsSettingsView(model: model, application: application)
        }
        .sheet(item: $model.iconApplication) { application in
            ApplicationIconPicker(model: model, application: application)
        }
        .overlay {
            GeometryReader { geometry in
                if let id = openFolderID, let folder = model.layout.folder(id: id) {
                    ZStack {
                        LauncherDropTarget(enabled: !model.busy, currentApplication: { model.draggingItemID },
                            hover: {
                                if let source = model.draggingItemID, folder.applicationIDs.contains(source) { closeFolder() }
                            }, receive: { source in
                                model.moveOutOfFolder(source)
                                model.draggingItemID = nil
                                closeFolder()
                            }) { _ in
                                Color.black.opacity(0.04).contentShape(Rectangle()).onTapGesture { closeFolder() }
                            }
                        LauncherFolderPanel(folder: folder, applications: members(of: folder), icons: model.icons,
                            busy: model.busy, openingID: model.openingID,
                            editingName: editingFolderName,
                            arrangementNamespace: arrangementNamespace,
                            panelWidth: geometry.size.width - 120, maxHeight: geometry.size.height - 100,
                            currentItem: { model.draggingItemID },
                            beginDrag: { model.draggingItemID = $0 },
                            launch: { model.launch($0); closeFolder() },
                            configureGraphics: { model.graphicsApplication = $0 },
                            configureIcon: { model.iconApplication = $0; closeFolder() },
                            rename: { model.renameFolder(id, name: $0) },
                            moveOut: { model.moveOutOfFolder($0) },
                            receive: { source, index in
                                if folder.applicationIDs.contains(source) {
                                    model.reorderApplication(source, inFolder: id, to: index)
                                } else {
                                    _ = model.groupApplication(source, on: id)
                                }
                            }, close: closeFolder)
                            .frame(width: geometry.size.width - 120)
                            .id(id)
                            .transition(reduceMotion ? .opacity : .scale(scale: 0.96).combined(with: .opacity))
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .environmentObject(iconDrag)
        .onAppear {
            iconDrag.didFinish = { model.draggingItemID = nil }
            iconDrag.restoreSource = { id in
                if let folder = model.layout.folderID(containing: id) { showFolder(folder) }
                else {
                    closeFolder()
                    setPageInstantly((model.layout.placements[id] ?? 0) / LauncherLayout.capacity)
                }
            }
        }
        .onChange(of: model.layout.folders) { _, _ in
            if let id = openFolderID, model.layout.folder(id: id) == nil { closeFolder() }
        }
        .onChange(of: displayedPageCount) { _, count in
            if page >= count { setPageInstantly(count - 1) }
        }
        .onChange(of: model.focusSearch) { _, value in
            if value { closeFolder(); searching = true; model.focusSearch = false }
        }
        .onChange(of: focusedItem) { _, id in
            guard let id else { return }
            let slot = arranging ? model.layout.placements[id] : filtered.firstIndex { $0.id == id }
            if let slot, slot / LauncherLayout.capacity != page {
                setPageInstantly(slot / LauncherLayout.capacity)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.refresh() } }
        }
        .onExitCommand {
            if openFolderID != nil { closeFolder() }
            else if !query.isEmpty { query = ""; setPageInstantly(0) }
            else { searching = false; focusedItem = nil }
        }
    }

    private func applicationDeck(page currentPage: Int, iconSize: CGFloat) -> some View {
        GeometryReader { geometry in
            let first = max(0, currentPage - 1)
            let last = min(displayedPageCount - 1, currentPage + 1)
            let pages = reduceMotion ? [currentPage] : Array(first...max(first, last))
            HStack(spacing: 0) {
                ForEach(pages, id: \.self) { index in
                    applicationGrid(page: index, iconSize: iconSize)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .accessibilityHidden(index != currentPage)
                }
            }
            .modifier(PageSlideEffect(translation: reduceMotion ? 0 : slideOffset,
                base: reduceMotion ? 0 : -CGFloat(currentPage - first) * geometry.size.width,
                presentation: slidePresentation))
            .onAppear { deckWidth = geometry.size.width }
            .onChange(of: geometry.size.width) { _, width in
                deckWidth = width
                setPageInstantly(page)
            }
        }
        .contentShape(Rectangle())
        .clipped()
        .background { LauncherPageSwipe(onGesture: handleScrollGesture) }
        .overlay(alignment: .leading) {
            if arranging && currentPage > 0 { pageEdge(currentPage - 1, symbol: "chevron.left") }
        }
        .overlay(alignment: .trailing) {
            if arranging { pageEdge(currentPage + 1, symbol: "chevron.right") }
        }
        .coordinateSpace(name: "launcher-deck")
    }

    private func applicationGrid(page currentPage: Int, iconSize: CGFloat) -> some View {
        ScrollViewReader { reader in
            ScrollView(.vertical) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 96), spacing: 12),
                                         count: LauncherLayout.columns), alignment: .leading, spacing: 20) {
                    ForEach(0..<LauncherLayout.capacity, id: \.self) { localSlot in
                        let slot = currentPage * LauncherLayout.capacity + localSlot
                        let item = item(at: slot)
                        LauncherDropTarget(enabled: arranging && !model.busy, outlined: true, currentApplication: { model.draggingItemID }, receive: { id in
                            receiveItem(id, at: slot)
                        }) { targeted in
                            Group {
                                switch item {
                                case let .application(application):
                                    applicationTile(application, iconSize: iconSize, draggable: arranging)
                                case let .folder(folder):
                                    folderTile(folder, iconSize: iconSize, targeted: targeted)
                                case nil:
                                    Color.white.opacity(0.001)
                                        .onTapGesture { if openFolderID != nil { closeFolder() } }
                                        .gesture(DragGesture(minimumDistance: 8, coordinateSpace: .named("launcher-deck"))
                                            .onChanged { trackMouseSwipe($0) }
                                            .onEnded { _ in
                                                mouseTime = nil
                                                if swipe.active { finishSwipe(cancelled: false) }
                                            })
                                        .accessibilityHidden(true)
                                }
                            }.frame(maxWidth: .infinity).frame(height: 144)
                                .contentShape(Rectangle())
                        }.id(slot)
                    }
                }.padding(.top, 30).padding(.bottom, 16)
            }.scrollIndicators(.hidden)
                .onChange(of: focusedItem) { _, id in
                    guard let id else { return }
                    if arranging, let slot = model.layout.placements[id] { reader.scrollTo(slot, anchor: .center) }
                    else if let index = filtered.firstIndex(where: { $0.id == id }) { reader.scrollTo(index, anchor: .center) }
                }
        }
    }

    private func item(at slot: Int) -> LauncherItem? {
        if arranging {
            guard let id = model.layout.itemID(at: slot) else { return nil }
            if let folder = model.layout.folder(id: id) { return .folder(folder) }
            return model.applications.first { $0.id == id }.map(LauncherItem.application)
        }
        return filtered.indices.contains(slot) ? .application(filtered[slot]) : nil
    }

    private func members(of folder: LauncherFolder) -> [LauncherApplication] {
        folder.applicationIDs.compactMap { id in model.applications.first { $0.id == id } }
    }

    private func receiveItem(_ id: String, at slot: Int) {
        guard id != model.layout.itemID(at: slot) else { return }
        if let target = model.layout.itemID(at: slot), let folder = model.groupApplication(id, on: target) {
            showFolder(folder, editing: model.layout.folder(id: target) == nil)
        } else {
            model.moveItem(id, to: slot)
            closeFolder()
        }
        model.draggingItemID = nil
    }

    private func showFolder(_ id: String, editing: Bool = false) {
        setPageInstantly((model.layout.placements[id] ?? page * LauncherLayout.capacity) / LauncherLayout.capacity)
        searching = false
        editingFolderName = editing
        withAnimation(reduceMotion || iconDrag.itemID != nil ? nil : .spring(response: 0.24, dampingFraction: 1)) { openFolderID = id }
    }

    private func closeFolder() {
        withAnimation(reduceMotion || iconDrag.itemID != nil ? nil : .easeOut(duration: 0.16)) { openFolderID = nil }
    }

    private func folderTile(_ folder: LauncherFolder, iconSize: CGFloat, targeted: Bool) -> some View {
        LauncherFolderTile(folder: folder, applications: members(of: folder), icons: model.icons,
            iconSize: iconSize, targeted: targeted,
            beginDrag: { model.draggingItemID = folder.id }) { showFolder(folder.id) }
            .matchedGeometryEffect(id: folder.id, in: arrangementNamespace, properties: .position)
            .focused($focusedItem, equals: folder.id)
            .disabled(model.busy)
            .contextMenu {
                Button("Open Folder") { showFolder(folder.id) }
                Button("Rename Folder…") { showFolder(folder.id, editing: true) }
                moveToPageMenu(folder.id)
                Divider()
                Button("Dissolve Folder") { model.dissolveFolder(folder.id) }
            }
    }

    private func applicationTile(_ application: LauncherApplication, iconSize: CGFloat,
                                              draggable: Bool) -> some View {
        ApplicationTile(application: application, image: model.icons.image(for: application),
            iconSize: iconSize, opening: model.openingID == application.id,
            needsInstall: application.kind == .steam && model.status?.steamInstalled != true,
            beginDrag: draggable ? {
                model.draggingItemID = application.id
            } : nil) {
                if openFolderID != nil { closeFolder() } else { model.launch(application) }
            }
            .matchedGeometryEffect(id: application.id, in: arrangementNamespace, properties: .position)
            .focused($focusedItem, equals: application.id)
            .disabled(model.busy)
            .contextMenu { contextMenu(application) }
    }

    private func pageEdge(_ destination: Int, symbol: String) -> some View {
        LauncherDropTarget(enabled: !model.busy, currentApplication: { model.draggingItemID }, hover: {
            previewPageCount = max(previewPageCount, destination + 1)
            selectPage(destination, animated: true)
        }, receive: { id in
            model.moveItem(id, toPage: destination)
            previewPageCount = max(previewPageCount, destination + 1)
            setPageInstantly(destination)
        }) { targeted in
            Image(systemName: symbol).font(.system(size: 18, weight: .medium))
                .foregroundStyle(.white.opacity(targeted ? 0.85 : 0))
                .frame(width: 26).frame(maxHeight: .infinity)
                .background(.white.opacity(targeted ? 0.05 : 0), in: RoundedRectangle(cornerRadius: 12))
        }.accessibilityHidden(true)
    }

    private func handleScrollGesture(_ event: PageScrollGestureEvent) {
        guard openFolderID == nil else { return }
        switch event {
        case .began: beginSwipe()
        case let .changed(delta, elapsed): trackSwipe(delta: delta, elapsed: elapsed)
        case .ended: if swipe.active { finishSwipe(cancelled: false) }
        case .cancelled: if swipe.active { finishSwipe(cancelled: true) }
        }
    }

    private func beginSwipe() {
        settlement += 1
        let visible = reduceMotion ? 0 : slidePresentation.read()
        let nearest = min(max(page - Int((visible / max(1, deckWidth)).rounded()), 0), displayedPageCount - 1)
        let residual = visible + CGFloat(nearest - page) * deckWidth
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            page = nearest
            slideOffset = residual
            swipe.begin(translation: Double(residual), page: page,
                        pageCount: displayedPageCount, width: Double(deckWidth))
        }
        lastMovement = nil
    }

    private func trackSwipe(delta: Double, elapsed: Double) {
        if !swipe.active { beginSwipe() }
        swipe.track(delta: delta, elapsed: elapsed, page: page,
                    pageCount: displayedPageCount, width: Double(deckWidth))
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { slideOffset = CGFloat(swipe.translation) }
        if delta != 0 { lastMovement = .now }
    }

    private func trackMouseSwipe(_ value: DragGesture.Value) {
        guard openFolderID == nil else { return }
        if mouseTime == nil {
            guard abs(value.translation.width) > abs(value.translation.height) * 1.3 else { return }
            beginSwipe()
            mouseTranslation = 0
        }
        let elapsed = mouseTime.map { value.time.timeIntervalSince($0) } ?? 1.0 / 60.0
        let delta = value.translation.width - mouseTranslation
        mouseTranslation = value.translation.width
        mouseTime = value.time
        trackSwipe(delta: Double(delta), elapsed: elapsed)
    }

    private func finishSwipe(cancelled: Bool) {
        if let lastMovement, lastMovement.duration(to: .now) > .milliseconds(100) {
            swipe.track(delta: 0, elapsed: 0, page: page,
                        pageCount: displayedPageCount, width: Double(deckWidth))
        }
        let destination = cancelled ? page : swipe.finish(page: page,
            pageCount: displayedPageCount, width: Double(deckWidth))
        settle(to: destination)
    }

    private func selectPage(_ destination: Int, animated: Bool) {
        if !animated || reduceMotion || abs(destination - page) > 1 {
            setPageInstantly(destination)
            return
        }
        beginSwipe()
        settle(to: destination)
    }

    private func settle(to destination: Int) {
        let destination = min(max(destination, 0), displayedPageCount - 1)
        settlement += 1
        let token = settlement
        mouseTime = nil
        if reduceMotion { setPageInstantly(destination); return }
        let target = CGFloat(page - destination) * deckWidth
        // Rebasing before the spring's tail finishes produces a final position jump.
        withAnimation(.spring(response: 0.32, dampingFraction: 1), completionCriteria: .removed) {
            slideOffset = target
        } completion: {
            guard settlement == token else { return }
            setPageInstantly(destination)
        }
    }

    private func setPageInstantly(_ destination: Int) {
        settlement += 1
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            page = min(max(destination, 0), displayedPageCount - 1)
            slideOffset = 0
            swipe.cancel()
            mouseTime = nil
            lastMovement = nil
        }
        slidePresentation.record(0)
    }

    private var header: some View {
        HStack {
            Text("Traverse").font(.system(size: 17, weight: .semibold)).tracking(-0.3)
                .foregroundStyle(.white.opacity(0.9)).frame(width: 130, alignment: .leading)
            Spacer(minLength: 20)
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.system(size: 17)).foregroundStyle(.white.opacity(0.65))
                TextField("Search Applications", text: Binding(get: { query }, set: {
                    query = $0; closeFolder(); setPageInstantly(0)
                }))
                    .textFieldStyle(.plain).font(.system(size: 15))
                    .focused($searching).accessibilityLabel("Search Applications")
                    .onSubmit { if let first = filtered.first { model.launch(first) } }
                if !query.isEmpty {
                    Button { query = ""; setPageInstantly(0); searching = true } label: {
                        Label("Clear Search", systemImage: "xmark.circle.fill").labelStyle(.iconOnly)
                    }.buttonStyle(.plain).foregroundStyle(.white.opacity(0.6)).help("Clear Search")
                }
            }
            .padding(.horizontal, 16).frame(width: 330, height: 44)
            .background(searchMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(searching || contrast == .increased ? 0.6 : 0.16), lineWidth: 1))
            Spacer(minLength: 20)
            HStack(spacing: 10) {
                Button { model.showingAdd = true } label: {
                    Label("Add Application", systemImage: "plus").labelStyle(.iconOnly)
                }.help("Add a Windows application (⌘O)")
                Menu {
                    Button("Refresh Applications") { Task { await model.refresh() } }
                    Button("Settings…") { model.showingSettings = true }
                    Button("Open Logs") { model.openLogs() }
                } label: {
                    Label("Launcher Options", systemImage: "ellipsis").labelStyle(.iconOnly)
                }.menuStyle(.borderlessButton).menuIndicator(.hidden).help("Launcher Options")
            }.font(.system(size: 17, weight: .medium)).buttonStyle(LauncherControlStyle())
                .frame(width: 130, alignment: .trailing)
        }
    }

    private var searchMaterial: Color { Color.white.opacity(reduceTransparency ? 0.17 : 0.1) }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: query.isEmpty ? "square.grid.3x3" : "magnifyingglass")
                .font(.system(size: 34, weight: .light)).foregroundStyle(.white.opacity(0.45))
            Text(query.isEmpty ? "No applications here yet" : "No applications found")
                .font(.system(size: 20, weight: .medium))
            if query.isEmpty {
                Button("Add Application…") { model.showingAdd = true }
                    .buttonStyle(.bordered).padding(.top, 4)
            } else {
                Text("Try another name.").font(.callout).foregroundStyle(.white.opacity(0.6))
            }
        }
    }

    @ViewBuilder private var footer: some View {
        if let error = model.error {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                Text(error).font(.callout).lineLimit(2).textSelection(.enabled)
                Button("Open Logs") { model.openLogs() }
                Button { model.error = nil } label: {
                    Label("Dismiss Error", systemImage: "xmark").labelStyle(.iconOnly)
                }.buttonStyle(.plain).help("Dismiss Error")
            }.padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        } else if model.busy {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(model.activity.isEmpty ? "Preparing…" : model.activity).font(.callout)
            }.padding(.horizontal, 16).padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
        } else if model.libraryLoaded {
            Text("\(model.applications.count) \(model.applications.count == 1 ? "application" : "applications")")
                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.45))
        }
    }

    @ViewBuilder private func contextMenu(_ application: LauncherApplication) -> some View {
        Button(application.kind == .steam && model.status?.steamInstalled != true ? "Install Steam…" : "Open") {
            model.launch(application)
        }.disabled(model.busy)
        Button("Open with Diagnostic Log") { model.launch(application, debug: true) }.disabled(model.busy)
        if application.isImported {
            Button("Change Icon…") { model.iconApplication = application }.disabled(model.busy)
        }
        if application.kind == .steamGame || application.kind == .shortcut
            || (application.kind == .executable && URL(fileURLWithPath: application.executablePath ?? "").pathExtension.lowercased() != "jar") {
            Button("Application Settings…") { model.graphicsApplication = application }.disabled(model.busy)
        }
        if application.steamAppID == BadEndTheaterSupport.appID {
            Button(model.gameSupport?.supportInstalled == true ? "Reapply Compatibility" : "Enable Compatibility") {
                model.enableGameSupport()
            }.disabled(model.busy)
        }
        Divider()
        if let folder = model.layout.folderID(containing: application.id) {
            Button("Open Folder") { query = ""; showFolder(folder) }
            Button("Move Out of Folder") { model.moveOutOfFolder(application.id) }
        }
        if !model.layout.folders.isEmpty {
            Menu("Move to Folder") {
                ForEach(model.layout.folders.filter { !$0.applicationIDs.contains(application.id) }) { folder in
                    Button(folder.name) { _ = model.groupApplication(application.id, on: folder.id) }
                }
            }.disabled(model.busy)
        }
        moveToPageMenu(application.id)
        Button("Show in Finder") { model.reveal(application) }
        Button("Remove from Launcher", role: .destructive) { model.remove(application) }
    }

    private func deletePage(_ index: Int) {
        let count = displayedPageCount
        guard arranging, count > 1, model.layout.isPageEmpty(index) else { return }
        if index < savedPageCount && !model.deleteEmptyPage(index) { return }
        previewPageCount = max(1, count - 1)
        focusedItem = nil
        setPageInstantly(min(index, displayedPageCount - 1))
    }

    private func moveToPageMenu(_ id: String) -> some View {
        Menu("Move to Page") {
            ForEach(0..<savedPageCount, id: \.self) { destination in
                Button("Page \(destination + 1)") {
                    model.moveItem(id, toPage: destination)
                    query = ""; closeFolder(); setPageInstantly(destination)
                }
            }
            Button("New Page") {
                let destination = savedPageCount
                model.moveItem(id, toPage: destination)
                query = ""; closeFolder(); setPageInstantly(destination)
            }
        }.disabled(model.busy)
    }

    private func moveFocus(_ direction: MoveCommandDirection) {
        guard !searching, openFolderID == nil, !filtered.isEmpty else { return }
        guard let focusedItem else {
            if let first = (0..<LauncherLayout.capacity).compactMap({ item(at: page * LauncherLayout.capacity + $0) }).first {
                self.focusedItem = first.id
            }
            return
        }
        let current = arranging ? model.layout.placements[focusedItem] ?? 0
            : filtered.firstIndex { $0.id == focusedItem } ?? 0
        let offset: Int
        switch direction {
        case .left: offset = -1
        case .right: offset = 1
        case .up: offset = -LauncherLayout.columns
        case .down: offset = LauncherLayout.columns
        @unknown default: return
        }
        let last = arranging ? model.layout.placements.values.max() ?? 0 : filtered.count - 1
        var target = current + offset
        while target >= 0 && target <= last {
            if let application = item(at: target) {
                setPageInstantly(target / LauncherLayout.capacity)
                self.focusedItem = application.id
                break
            }
            target += offset
        }
    }

    private var installSheet: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Install Steam").font(.title2.weight(.semibold))
            Text("Install the Windows version of Steam in Traverse.").foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { model.showingInstall = false }.keyboardShortcut(.cancelAction)
                Button("Install Steam") { model.install() }.buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction).disabled(model.busy)
            }
        }.padding(28).frame(width: 400)
    }
}

struct ApplicationTile: View {
    let application: LauncherApplication
    let image: NSImage?
    let iconSize: CGFloat
    let opening: Bool
    let needsInstall: Bool
    var beginDrag: (() -> Void)? = nil
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        VStack(spacing: 12) {
            draggableIcon.frame(height: 92)
            VStack(spacing: 3) {
                Text(application.name).font(.system(size: 13, weight: .medium))
                    .lineLimit(2).multilineTextAlignment(.center)
                    .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                if needsInstall {
                    Text("Install").font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                }
            }.frame(height: 36, alignment: .top).contentShape(Rectangle()).onTapGesture(perform: action)
        }
        .frame(maxWidth: .infinity).frame(height: 144)
        .background(.white.opacity(hovered ? 0.065 : 0), in: RoundedRectangle(cornerRadius: 20))
        .contentShape(RoundedRectangle(cornerRadius: 20))
        .focusable()
        .onKeyPress(.return) { action(); return .handled }
        .onKeyPress(.space) { action(); return .handled }
        .onHover { hovered = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(application.name)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { action() }
        .accessibilityHint(needsInstall ? "Install the Windows Steam client" : "Open application or drag to arrange")
        .help(needsInstall ? "Install Steam" : "Open \(application.name)")
    }

    @ViewBuilder private var draggableIcon: some View {
        if let beginDrag {
            LauncherDraggableIcon(id: application.id, begin: beginDrag, action: action) { iconArtwork }
        } else { iconArtwork.onTapGesture(perform: action) }
    }

    private var iconArtwork: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                    .frame(width: iconSize, height: iconSize)
                    .clipShape(RoundedRectangle(cornerRadius: iconSize * 0.22, style: .continuous))
                    .shadow(color: .black.opacity(0.25), radius: 9, x: 0, y: 5)
            } else {
                RoundedRectangle(cornerRadius: iconSize * 0.22, style: .continuous).fill(.white.opacity(0.16))
                    .overlay(Image(systemName: application.kind == .steamGame ? "gamecontroller.fill" : "app.fill")
                        .font(.system(size: 40, weight: .light)).foregroundStyle(.white.opacity(0.8)))
                    .frame(width: iconSize, height: iconSize)
            }
            if opening {
                RoundedRectangle(cornerRadius: iconSize * 0.22, style: .continuous).fill(.black.opacity(0.3))
                    .frame(width: iconSize, height: iconSize)
                ProgressView().controlSize(.small)
            }
        }.frame(width: iconSize, height: iconSize)
    }

}

private struct LauncherControlStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.frame(width: 34, height: 34)
            .background(.white.opacity(configuration.isPressed ? 0.2 : 0.09), in: Circle())
            .contentShape(Circle())
    }
}

private struct LauncherBackdrop: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private static let wallpaper: NSImage? = {
        guard let screen = NSScreen.main, let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
        return NSImage(contentsOf: url)
    }()

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                LinearGradient(colors: [Color(red: 0.12, green: 0.23, blue: 0.29),
                                        Color(red: 0.24, green: 0.34, blue: 0.34),
                                        Color(red: 0.17, green: 0.2, blue: 0.31)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                if !reduceTransparency, let image = Self.wallpaper {
                    Image(nsImage: image).resizable().scaledToFill()
                        .frame(width: geometry.size.width + 120, height: geometry.size.height + 120)
                        .blur(radius: 38).offset(x: -60, y: -60)
                    Color.black.opacity(0.48)
                } else if !reduceTransparency {
                    Ellipse().fill(Color.teal.opacity(0.35)).frame(width: 760, height: 540)
                        .blur(radius: 100).offset(x: -170, y: -180)
                    Ellipse().fill(Color.indigo.opacity(0.3)).frame(width: 600, height: 450)
                        .blur(radius: 100).offset(x: 280, y: 260)
                }
            }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
        }.ignoresSafeArea()
    }
}

private struct AddApplicationView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var url: URL?
    @State private var name = ""
    @State private var openAfterAdding = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 12) {
                Image(systemName: "plus.app").font(.system(size: 30, weight: .light)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Add Application").font(.title2.weight(.semibold))
                    Text("Choose a Windows app, Java app, installer, or shortcut.").font(.callout).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(url?.lastPathComponent ?? "No file selected").lineLimit(1)
                        Text(url?.deletingLastPathComponent().path ?? ".exe, .com, .jar, .msi, or .lnk")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                    }
                    Spacer()
                    Button("Choose File…") { chooseFile() }
                }
                Divider()
                TextField("Name", text: $name).textFieldStyle(.roundedBorder)
                Toggle("Open after adding", isOn: $openAfterAdding)
                if url?.pathExtension.lowercased() == "jar" {
                    Text("Uses Windows Java 17. The runtime is downloaded when needed.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(16).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add Application") {
                    guard let url else { return }
                    do { try model.add(url: url, name: name, open: openAfterAdding); dismiss() }
                    catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(url == nil || model.busy)
            }
        }.padding(28).frame(width: 480)
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.title = "Choose Windows Application"
        panel.allowedContentTypes = ["exe", "com", "jar", "msi", "lnk"].compactMap { UTType(filenameExtension: $0) }
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let selected = panel.url {
            url = selected
            name = selected.deletingPathExtension().lastPathComponent
            error = nil
        }
    }
}

private struct ApplicationGraphicsSettingsView: View {
    @ObservedObject var model: AppModel
    let application: LauncherApplication
    @Environment(\.dismiss) private var dismiss
    @State private var backend = GraphicsBackend.automatic
    @State private var directKeyboardInput = false
    @State private var executable: URL?
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(application.name).font(.title2.weight(.semibold))
            GroupBox {
                HStack {
                    Text("Graphics")
                    Spacer()
                    Picker("Graphics", selection: $backend) {
                        ForEach(GraphicsBackend.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.menu).frame(width: 180)
                }.padding(.vertical, 6)
            } label: {
                Text("Advanced Settings").font(.headline)
            }
            if backend == .automatic {
                Text("Uses the global graphics setting.").font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Direct Keyboard Input", isOn: $directKeyboardInput)
            Text("Bypass input methods when game keys do not respond. Text composition is disabled for this application.")
                .font(.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                Text("Executable").font(.headline)
                Text(executable?.path ?? "Choose the application's Windows executable.")
                    .font(.callout).lineLimit(3).truncationMode(.middle).textSelection(.enabled)
                if application.kind == .steamGame || application.kind == .shortcut
                    || (application.kind == .executable && URL(fileURLWithPath: application.executablePath ?? "").pathExtension.lowercased() != "exe") {
                    Button("Choose Executable…") { chooseExecutable() }
                }
            }
            Text("Restart this application to apply these settings.")
                .font(.caption).foregroundStyle(.secondary)
            if model.busy {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(model.activity.isEmpty ? "Configuring graphics…" : model.activity).font(.callout)
                }
            }
            if let error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(model.busy)
                Button("Apply") { apply() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(loading || executable == nil || model.busy)
            }
        }.padding(24).frame(width: 460)
            .task {
                do {
                    directKeyboardInput = try await model.applicationsRuntime.directKeyboardInput(for: application)
                    if let profile = try await model.applicationsRuntime.graphicsProfile(for: application) {
                        backend = profile.selection
                        executable = URL(fileURLWithPath: profile.executablePath)
                    } else if application.kind == .executable, let path = application.executablePath,
                              URL(fileURLWithPath: path).pathExtension.lowercased() == "exe" {
                        executable = URL(fileURLWithPath: path)
                    }
                } catch { self.error = error.localizedDescription }
                loading = false
            }
            .interactiveDismissDisabled(model.busy)
    }

    private func chooseExecutable() {
        let panel = NSOpenPanel()
        panel.title = "Choose Application Executable"
        panel.allowedContentTypes = ["exe"].compactMap { UTType(filenameExtension: $0) }
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = application.activationDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? executable?.deletingLastPathComponent()
            ?? application.workingDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) }
        if panel.runModal() == .OK, let selected = panel.url { executable = selected; error = nil }
    }

    private func apply() {
        guard let executable, !model.busy else { return }
        model.busy = true
        error = nil
        Task {
            defer { model.busy = false; model.activity = "" }
            do {
                _ = try await model.applicationsRuntime.setGraphicsBackend(backend, for: application,
                    targetExecutable: executable, progress: { message in
                        await MainActor.run { model.activity = message }
                    })
                try await model.applicationsRuntime.setDirectKeyboardInput(directKeyboardInput, for: application)
                await model.refresh()
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}

private struct FrameRateLimitPicker: View {
    @ObservedObject var model: AppModel
    @State private var choice = Choice.off
    @State private var custom = 90

    private enum Choice: Hashable { case off, preset(Int), custom }

    var body: some View {
        Picker("Frame rate limit", selection: $choice) {
            Text("Off").tag(Choice.off)
            ForEach(FrameRateLimit.presets, id: \.self) { Text("\($0) FPS").tag(Choice.preset($0)) }
            Text("Custom").tag(Choice.custom)
        }
        .onChange(of: choice) { _, _ in save() }
        if choice == .custom {
            HStack {
                Text("Custom limit")
                Spacer()
                TextField("FPS", value: $custom, format: .number)
                    .multilineTextAlignment(.trailing).frame(width: 64)
                    .onSubmit { save() }
                Stepper("FPS", value: $custom, in: FrameRateLimit.range, step: 5).labelsHidden()
                    .onChange(of: custom) { _, _ in save() }
            }
        }
        Text("Caps D3DMetal, DXMT, and DXVK games. DXMT and DXVK use up to 30 FPS when minimized or hidden. Visible windows keep the selected limit. Restart applications and Steam to apply.")
            .font(.caption).foregroundStyle(.secondary)
            .onAppear(perform: load)
            .onChange(of: model.frameRateLimit) { _, _ in load() }
    }

    private func load() {
        switch model.frameRateLimit {
        case nil: choice = .off
        case let limit? where FrameRateLimit.presets.contains(limit): choice = .preset(limit)
        case let limit?: custom = limit; choice = .custom
        }
    }

    private func save() {
        custom = min(max(custom, FrameRateLimit.range.lowerBound), FrameRateLimit.range.upperBound)
        let limit: Int? = switch choice {
        case .off: nil
        case .preset(let value): value
        case .custom: custom
        }
        guard limit != model.status?.frameRateLimit else { return }
        model.frameRateLimit = limit
        model.saveFrameRateLimit()
    }
}

private struct LauncherSettingsView: View {
    @ObservedObject var model: AppModel
    var onDone: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var textFonts: [WindowsTextFont] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Settings").font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { if let onDone { onDone() } else { dismiss() } }.keyboardShortcut(.cancelAction)
            }.padding(24)
            Form {
                Section("Fusion Mode") {
                    Toggle("Fusion Mode", isOn: Binding(get: { model.fusionMode }, set: { model.setFusionMode($0) }))
                    Text("Run Traverse in the menu bar. Open Windows apps from Finder or Spotlight, and search for Traverse to open your library.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Windows files keep opening with Traverse when Fusion Mode is off.")
                        .font(.caption).foregroundStyle(.secondary)
                    if model.fusionMode {
                        Button("Open Applications Folder") { model.openFusionFolder() }
                    }
                }
                Section("Wine Engine") {
                    LabeledContent("Engine", value: model.engineName)
                    HStack {
                        Button("Choose Wine…") { model.chooseEngine() }
                        Button("Use Default Engine") { model.useManagedEngine() }
                    }
                    Button("Install MSync Engine…") { model.installMSyncEngine() }
                        .help("Includes a Steam browser workaround that disables Chromium's sandbox.")
                    Toggle("Fast synchronization", isOn: $model.msync)
                        .onChange(of: model.msync) { _, _ in
                            if model.msync != model.status?.msync { model.saveMSync() }
                        }
                    Text("Quit Windows applications before changing the engine or synchronization.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Graphics") {
                    Picker("Default backend", selection: $model.graphicsBackend) {
                        ForEach(GraphicsBackend.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.onChange(of: model.graphicsBackend) { _, _ in
                        if model.graphicsBackend != model.status?.graphicsBackend { model.saveGraphicsBackend() }
                    }
                    Text("Auto follows this setting. With D3DMetal selected, 32-bit apps use DXMT or Wine. Restart apps to apply.")
                        .font(.caption).foregroundStyle(.secondary)
                    FrameRateLimitPicker(model: model)
                }
                Section("Steam") {
                    Picker("Interface rendering", selection: $model.rendering) {
                        ForEach(SteamRendering.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.onChange(of: model.rendering) { _, _ in
                        if model.rendering != model.status?.rendering { model.saveRendering() }
                    }
                    Text("Use software rendering for a blank Steam window. Restart Steam to apply.")
                        .font(.caption).foregroundStyle(.secondary)
                    if model.status?.steamInstalled != true {
                        Button("Install Steam…") {
                            if let onDone { onDone() } else { dismiss() }
                            model.showLauncher?()
                            model.showingInstall = true
                        }
                    }
                }
                Section("Windows Display") {
                    Toggle("Retina high resolution", isOn: $model.retinaMode)
                        .onChange(of: model.retinaMode) { _, _ in
                            if model.retinaMode != model.status?.retinaMode { model.saveRetinaMode() }
                        }
                    Text("Sharper text and controls on Retina displays, with 200% interface scaling. Quit all Windows apps, including Steam, then reopen them to apply.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Some older apps may still appear blurry or have smaller controls. Games may use more GPU power.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Windows Text") {
                    Picker("Chinese font", selection: $model.windowsTextFont) {
                        Text("Default (Heiti SC)").tag("")
                        ForEach(textFonts) { font in Text(font.family).tag(font.id) }
                        if !model.windowsTextFont.isEmpty, !textFonts.contains(where: { $0.id == model.windowsTextFont }) {
                            Text("Unavailable font").tag(model.windowsTextFont)
                        }
                    }.onChange(of: model.windowsTextFont) { _, _ in
                        if model.windowsTextFont != (model.status?.windowsTextFont ?? "") { model.saveWindowsTextFont() }
                    }
                    Text("Aa 0123 \u{4e2d}\u{6587} \u{7e41}\u{9ad4}")
                        .font(.custom(model.windowsTextFont.isEmpty ? "STHeitiSC-Light" : model.windowsTextFont, size: 24))
                    Text("Uses Chinese fonts installed on this Mac. Restart Windows apps, including Steam, to apply.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let game = model.gameSupport, game.gameInstalled {
                    Section("Game Compatibility") {
                        LabeledContent(game.title, value: game.supportInstalled ? "Enabled" : "Available")
                        Button(game.supportInstalled ? "Reapply Compatibility" : "Enable Compatibility") { model.enableGameSupport() }
                    }
                }
                Section("Library") {
                    Button("Refresh Applications") { Task { await model.refresh() } }
                    Button("Open Traverse Folder") { NSWorkspace.shared.open(model.runtime.paths.root) }
                    Button("Open Logs") { model.openLogs() }
                }
            }.formStyle(.grouped).disabled(model.busy)
        }.frame(width: 550, height: 650)
            .task { textFonts = WindowsTextFont.available() }
            .alert("Traverse", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
                Button("OK") { model.error = nil }
            } message: {
                Text(model.error ?? "")
            }
    }
}
