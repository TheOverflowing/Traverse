import Foundation

public struct PageSwipeState: Sendable {
    public private(set) var translation: Double = 0
    public private(set) var active = false
    public private(set) var velocity: Double = 0
    private var accumulatedTranslation: Double = 0

    public init() {}

    public mutating func begin(translation initialTranslation: Double = 0,
                              page: Int = 0, pageCount: Int = 1, width: Double = 0) {
        accumulatedTranslation = initialTranslation
        if width > 0, (page <= 0 && initialTranslation > 0 || page >= pageCount - 1 && initialTranslation < 0) {
            // The new gesture starts from an already rubberbanded presentation.
            let bounded = min(abs(initialTranslation), width * 0.2)
            let raw = bounded * width / (0.25 * (width - bounded))
            accumulatedTranslation = initialTranslation < 0 ? -raw : raw
        }
        translation = initialTranslation
        velocity = 0
        active = true
    }

    public mutating func track(delta: Double, elapsed: Double, page: Int, pageCount: Int, width: Double) {
        guard active, width > 0 else { return }
        accumulatedTranslation = min(width, max(-width, accumulatedTranslation + delta))
        if elapsed > 0 {
            velocity = delta / max(1.0 / 240.0, elapsed)
        } else {
            velocity = 0
        }

        let atBeginning = page <= 0 && accumulatedTranslation > 0
        let atEnd = page >= max(0, pageCount - 1) && accumulatedTranslation < 0
        if atBeginning || atEnd {
            translation = rubberband(accumulatedTranslation, dimension: width)
        } else {
            translation = accumulatedTranslation
        }
    }

    public mutating func finish(page: Int, pageCount: Int, width: Double) -> Int {
        let currentPage = min(max(0, page), max(0, pageCount - 1))
        guard active else { return currentPage }
        active = false
        guard width > 0 else { return currentPage }
        let projectedTranslation = translation + velocity * 0.12
        let threshold = max(50, width * 0.18)
        guard abs(projectedTranslation) >= threshold else { return currentPage }
        let destination = currentPage + (projectedTranslation < 0 ? 1 : -1)
        return min(max(0, destination), max(0, pageCount - 1))
    }

    public mutating func cancel() {
        accumulatedTranslation = 0
        translation = 0
        velocity = 0
        active = false
    }

    private func rubberband(_ distance: Double, dimension: Double) -> Double {
        let resistance = 0.25
        return distance * dimension * resistance / (dimension + resistance * abs(distance))
    }
}
