import AppKit
import SwiftUI

enum PageScrollGestureEvent {
    case began
    case changed(delta: Double, elapsed: Double)
    case ended
    case cancelled
}

@MainActor
struct LauncherPageSwipe: NSViewRepresentable {
    var onGesture: @MainActor (PageScrollGestureEvent) -> Void

    func makeNSView(context: Context) -> PageSwipeView {
        let view = PageSwipeView()
        view.onGesture = onGesture
        return view
    }

    func updateNSView(_ view: PageSwipeView, context: Context) { view.onGesture = onGesture }

    static func dismantleNSView(_ view: PageSwipeView, coordinator: ()) { view.stopMonitoring() }
}

@MainActor
final class PageSwipeView: NSView {
    var onGesture: @MainActor (PageScrollGestureEvent) -> Void = { _ in }
    private enum Axis { case undecided, horizontal, vertical }
    private var monitor: Any?
    private var axis = Axis.undecided
    private var lastEvent: TimeInterval?
    private var idleTimer: Timer?
    private var consumeMomentum = false

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopMonitoring()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self else { return false }
                return self.handle(event)
            }
            return consumed ? nil : event
        }
    }

    func stopMonitoring() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        finish(cancelled: true)
        consumeMomentum = false
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard event.window === window else { return false }
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        if event.phase.contains(.began) {
            finish(cancelled: true)
            consumeMomentum = false
            guard inside else { return false }
        }
        // A claimed gesture keeps its axis and release event when the pointer
        // leaves the launchpad; only its initial movement is bounds-gated.
        guard inside || axis != .undecided || (!event.momentumPhase.isEmpty && consumeMomentum) else { return false }
        if !event.momentumPhase.isEmpty {
            let consumed = consumeMomentum
            if event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) {
                consumeMomentum = false
            }
            return consumed
        }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            let consumed = axis == .horizontal
            finish(cancelled: event.phase.contains(.cancelled))
            return consumed
        }
        if axis == .undecided, event.scrollingDeltaX != 0 || event.scrollingDeltaY != 0 {
            axis = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? .horizontal : .vertical
            consumeMomentum = axis == .horizontal
            if axis == .horizontal { onGesture(.began) }
        }
        let elapsed = lastEvent.map { max(0.001, event.timestamp - $0) } ?? 1.0 / 60.0
        lastEvent = event.timestamp
        if event.phase.isEmpty { scheduleIdleEnd() }
        guard axis == .horizontal else { return false }
        onGesture(.changed(delta: Double(event.scrollingDeltaX), elapsed: elapsed))
        return true
    }

    private func scheduleIdleEnd() {
        idleTimer?.invalidate()
        let timer = Timer(timeInterval: 0.12, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish(cancelled: false) }
        }
        idleTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func finish(cancelled: Bool) {
        idleTimer?.invalidate()
        idleTimer = nil
        let horizontal = axis == .horizontal
        axis = .undecided
        lastEvent = nil
        if horizontal { onGesture(cancelled ? .cancelled : .ended) }
    }
}
