import AppKit
import QuartzCore
import SwiftUI

/// Owns the one visible icon from pickup through the end of its landing animation.
@MainActor
final class LauncherIconDrag: ObservableObject {
    @Published private(set) var itemID: String?
    var didFinish: (() -> Void)?
    var restoreSource: ((String) -> Void)?
    private var sources = NSHashTable<LauncherIconSurface>.weakObjects()
    private var targets = NSHashTable<LauncherTargetRegion>.weakObjects()
    private var floating: NSImageView?
    private var origin = NSPoint.zero
    private var pointerStart = NSPoint.zero
    private var lastPointer = NSPoint.zero
    private var monitor: Any?
    private var hoverTask: Task<Void, Never>?
    private weak var target: LauncherTargetRegion?
    private var receiver: ((String) -> Void)?
    private var landing = false

    func register(_ source: LauncherIconSurface) { sources.add(source) }
    func register(_ region: LauncherTargetRegion) { targets.add(region) }

    func begin(_ source: LauncherIconSurface, start: NSPoint, event: NSEvent) {
        guard itemID == nil, let host = source.window?.contentView, let image = source.artwork() else { return }
        source.beginDrag()
        itemID = source.itemID
        host.layoutSubtreeIfNeeded()
        origin = source.convert(source.bounds, to: host).origin
        pointerStart = host.convert(start, from: nil)
        let view = NSImageView(frame: source.convert(source.bounds, to: host))
        view.image = image
        view.imageScaling = .scaleAxesIndependently
        view.wantsLayer = true
        host.addSubview(view)
        floating = view
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .leftMouseDragged { self.move(event); return nil }
            if event.type == .leftMouseUp { self.move(event); self.finish(cancelled: false); return nil }
            if event.keyCode == 53 { self.finish(cancelled: true); return nil }
            return event
        }
        move(event)
    }

    private func move(_ event: NSEvent) {
        guard !landing, let view = floating, let host = view.superview else { return }
        let pointer = host.convert(event.locationInWindow, from: nil)
        let moved = pointer != lastPointer
        lastPointer = pointer
        view.setFrameOrigin(NSPoint(x: origin.x + pointer.x - pointerStart.x,
                                    y: origin.y + pointer.y - pointerStart.y))
        updateTarget(preservingReceiver: !moved)
    }

    private func updateTarget(preservingReceiver: Bool = false) {
        guard let host = floating?.superview else { return }
        let next = targets.allObjects.filter {
            $0.enabled && $0.window == host.window && !$0.isHiddenOrHasHiddenAncestor
                && $0.convert($0.bounds.intersection($0.visibleRect), to: host).contains(lastPointer)
        }.min {
            $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height
        }
        guard next !== target else {
            if next == nil && !preservingReceiver { receiver = nil }
            return
        }
        target?.targeting(false)
        hoverTask?.cancel()
        target = next
        if next != nil || !preservingReceiver { receiver = next?.receive }
        next?.targeting(true)
        if let hover = next?.hover {
            hoverTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled, let self, !self.landing else { return }
                hover()
                // Folder/page hover can replace the target underneath a stationary pointer.
                await Task.yield()
                self.floating?.window?.contentView?.layoutSubtreeIfNeeded()
                self.updateTarget(preservingReceiver: true)
            }
        }
    }

    private func finish(cancelled: Bool) {
        guard let id = itemID, !landing else { return }
        landing = true
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        hoverTask?.cancel()
        target?.targeting(false)
        // The hidden destination lays out immediately; only the visible floating icon moves.
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            if cancelled || receiver == nil { restoreSource?(id) }
            else { receiver?(id) }
        }
        target = nil
        receiver = nil
        DispatchQueue.main.async { [weak self] in self?.land(id) }
    }

    private func land(_ id: String) {
        guard let view = floating, let host = view.superview else { clear(); return }
        host.layoutSubtreeIfNeeded()
        let destination = sources.allObjects.first {
            $0.itemID == id && $0.available && $0.window == host.window
                && !$0.isHiddenOrHasHiddenAncestor && !$0.bounds.intersection($0.visibleRect).isEmpty
        }
        let rect = destination.map { $0.convert($0.bounds, to: host) }
            ?? NSRect(origin: origin, size: view.frame.size)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.24
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
            view.animator().frame = rect
        } completionHandler: { [weak self] in
            Task { @MainActor in self?.clear() }
        }
    }

    private func clear() {
        itemID = nil
        didFinish?()
        // Reveal the destination in the same display cycle as removing the floating artwork.
        floating?.window?.contentView?.layoutSubtreeIfNeeded()
        floating?.removeFromSuperview()
        floating = nil
        landing = false
    }
}

@MainActor
final class LauncherIconSurface: NSView {
    var itemID = ""
    var available = true
    var artwork: () -> NSImage? = { nil }
    var beginDrag: () -> Void = {}
    var action: () -> Void = {}
    weak var drag: LauncherIconDrag?
    private var down: NSPoint?
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) { if available { down = event.locationInWindow } }
    override func mouseDragged(with event: NSEvent) {
        guard let down, available, hypot(event.locationInWindow.x - down.x, event.locationInWindow.y - down.y) >= 4 else { return }
        drag?.begin(self, start: down, event: event)
        self.down = nil
    }
    override func mouseUp(with event: NSEvent) {
        if available, down != nil, bounds.contains(convert(event.locationInWindow, from: nil)) { action() }
        down = nil
    }
}

private struct LauncherIconInput: NSViewRepresentable {
    let id: String
    let available: Bool
    let drag: LauncherIconDrag
    let artwork: () -> NSImage?
    let begin: () -> Void
    let action: () -> Void
    func makeNSView(context: Context) -> LauncherIconSurface {
        let view = LauncherIconSurface()
        drag.register(view)
        return view
    }
    func updateNSView(_ view: LauncherIconSurface, context: Context) {
        view.itemID = id; view.available = available; view.drag = drag
        view.artwork = artwork; view.beginDrag = begin; view.action = action
    }
}

struct LauncherDraggableIcon<Artwork: View>: View {
    let id: String
    let begin: () -> Void
    let action: () -> Void
    @ViewBuilder var artwork: () -> Artwork
    @EnvironmentObject private var drag: LauncherIconDrag
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        artwork().opacity(drag.itemID == id ? 0 : 1)
            .overlay {
                LauncherIconInput(id: id, available: enabled, drag: drag, artwork: {
                    let renderer = ImageRenderer(content: artwork().environment(\.colorScheme, .dark))
                    renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
                    return renderer.nsImage
                }, begin: begin, action: action)
            }
    }
}

@MainActor
final class LauncherTargetRegion: NSView {
    var enabled = false
    var targeting: (Bool) -> Void = { _ in }
    var hover: (() -> Void)?
    var receive: (String) -> Void = { _ in }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private struct LauncherTargetInput: NSViewRepresentable {
    let drag: LauncherIconDrag
    let enabled: Bool
    let targeting: (Bool) -> Void
    let hover: (() -> Void)?
    let receive: (String) -> Void
    func makeNSView(context: Context) -> LauncherTargetRegion {
        let view = LauncherTargetRegion()
        drag.register(view)
        return view
    }
    func updateNSView(_ view: LauncherTargetRegion, context: Context) {
        view.enabled = enabled; view.targeting = targeting; view.hover = hover; view.receive = receive
    }
}

@MainActor
struct LauncherDropTarget<Content: View>: View {
    let enabled: Bool
    var outlined = false
    let currentApplication: @MainActor () -> String?
    var hover: (@MainActor @Sendable () -> Void)?
    let receive: @MainActor @Sendable (String) -> Void
    @ViewBuilder var content: (Bool) -> Content
    @EnvironmentObject private var drag: LauncherIconDrag
    @Environment(\.isEnabled) private var environmentEnabled
    @State private var targeted = false
    var body: some View {
        content(targeted && enabled)
            .contentShape(Rectangle())
            .background {
                LauncherTargetInput(drag: drag, enabled: enabled && environmentEnabled,
                    targeting: { targeted = $0 }, hover: hover, receive: receive)
            }
            .overlay {
                if outlined && targeted && enabled {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(.white.opacity(0.08))
                        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(.white.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
                        .allowsHitTesting(false)
                }
            }
    }
}
