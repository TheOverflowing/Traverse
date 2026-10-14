import Foundation
import SwiftUI

// Geometry effects can be evaluated by the renderer. The gesture handler reads
// the last displayed offset when it interrupts a settling spring.
final class PageSlidePresentation: @unchecked Sendable {
    private let lock = NSLock()
    private var offset: CGFloat = 0

    func record(_ value: CGFloat) { lock.withLock { offset = value } }
    func read() -> CGFloat { lock.withLock { offset } }
}

struct PageSlideEffect: GeometryEffect {
    var translation: CGFloat
    let base: CGFloat
    let presentation: PageSlidePresentation

    var animatableData: CGFloat {
        get { translation }
        set { translation = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        presentation.record(translation)
        return ProjectionTransform(CGAffineTransform(translationX: base + translation, y: 0))
    }
}
