import Foundation

public enum FrameRateLimit {
    public static let presets = [60, 120]
    public static let range = 10...500

    public static func validate(_ limit: Int?) throws {
        if let limit, !range.contains(limit) {
            throw TraverseError.message("Choose a frame rate limit from \(range.lowerBound) to \(range.upperBound) FPS.")
        }
    }

    /// Caps supported translation layers: D3DMetal reads D3DM_MAX_FPS, DXMT
    /// reads d3d11.preferredMaxFrameRate, and DXVK reads DXVK_FRAME_RATE.
    /// Wine's builtin renderer has no matching environment option.
    /// Bundled DXMT and DXVK lower minimized or hidden windows to at most 30 FPS.
    static func apply(_ limit: Int?, to environment: inout [String: String]) {
        guard let limit else { return }
        let option = "d3d11.preferredMaxFrameRate=\(limit);d3d11.backgroundMaxFrameRate=\(min(limit, 30))"
        // A later entry wins, so an inherited DXMT_CONFIG keeps its other options.
        if let inherited = environment["DXMT_CONFIG"], !inherited.isEmpty {
            environment["DXMT_CONFIG"] = inherited + ";" + option
        } else {
            environment["DXMT_CONFIG"] = option
        }
        environment["DXVK_FRAME_RATE"] = String(limit)
        environment["DXVK_BACKGROUND_FRAME_RATE"] = String(min(limit, 30))
        environment["D3DM_MAX_FPS"] = String(limit)
    }
}
