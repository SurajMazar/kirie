import Foundation

/// How one panel (or picture) is framed on the canvas, and whether its subject stays fully visible.
public struct FramingPlan: Hashable, Sendable, Codable {
    public var fit: FitMode
    public var scaleFrom: Double
    public var scaleTo: Double
    public var positionFrom: UnitPoint2D
    public var positionTo: UnitPoint2D
    /// Part of the picture visible at the tightest moment, picture-normalised.
    public var visibleRect: UnitRect
    /// PASS/FAIL for the crop-safety check.
    public var subjectSafe: Bool
    public var note: String
}

/// Pure geometry for subject-aware framing. Aspect ratios are width ÷ height.
public enum FramingPlanner {
    /// Size of the picture relative to the canvas (canvas = `canvasAspect` × 1) at scale 1.
    static func baseSize(pictureAspect: Double, canvasAspect: Double, fit: FitMode) -> (w: Double, h: Double) {
        switch fit {
        case .contain:
            let h = min(1, canvasAspect / pictureAspect)
            return (pictureAspect * h, h)
        case .cover:
            let h = max(1, canvasAspect / pictureAspect)
            return (pictureAspect * h, h)
        case .fill:
            return (canvasAspect, 1)
        }
    }

    /// The picture region visible on the canvas when the picture point `center` sits at the canvas centre.
    public static func visibleRect(pictureAspect: Double, canvasAspect: Double, fit: FitMode, scale: Double,
                                   center: UnitPoint2D) -> UnitRect {
        let base = baseSize(pictureAspect: pictureAspect, canvasAspect: canvasAspect, fit: fit)
        let fw = min(1, canvasAspect / (base.w * scale))
        let fh = min(1, 1 / (base.h * scale))
        let cx = min(max(center.x, fw / 2), 1 - fw / 2)
        let cy = min(max(center.y, fh / 2), 1 - fh / 2)
        return UnitRect(x: cx - fw / 2, y: cy - fh / 2, width: fw, height: fh)
    }

    /// Canvas-normalised clip position that puts the picture point `focus` as close to the canvas
    /// centre as possible without exposing empty canvas.
    public static func position(forFocus focus: UnitPoint2D, pictureAspect: Double, canvasAspect: Double, fit: FitMode,
                                scale: Double) -> UnitPoint2D {
        let visible = visibleRect(pictureAspect: pictureAspect, canvasAspect: canvasAspect, fit: fit, scale: scale, center: focus)
        let base = baseSize(pictureAspect: pictureAspect, canvasAspect: canvasAspect, fit: fit)
        let x = 0.5 + (0.5 - visible.midX) * base.w * scale / canvasAspect
        let y = 0.5 + (0.5 - visible.midY) * base.h * scale
        return UnitPoint2D(x: x, y: y)
    }

    static func isSafe(subject: UnitRect?, visible: UnitRect, margin: Double) -> Bool {
        guard let subject else { return true }
        // Showing the whole picture is always safe: nothing is cropped by Kirie.
        if visible.width >= 1 - 1e-9, visible.height >= 1 - 1e-9 { return true }
        let insetX = visible.width >= 1 - 1e-9 ? 0 : margin * visible.width
        let insetY = visible.height >= 1 - 1e-9 ? 0 : margin * visible.height
        let safeArea = UnitRect(x: visible.x + insetX, y: visible.y + insetY, width: visible.width - 2 * insetX,
                                height: visible.height - 2 * insetY)
        return safeArea.contains(subject, tolerance: 1e-6)
    }

    /// Plans framing for a picture so the subject (plus margin) is never cut off.
    ///
    /// - `subject`: detected subject bounds, picture-normalised. Nil = unknown (treated as safe).
    /// - `focus`: manual focal point; overrides the subject centre.
    /// - `maxZoom`: end scale of the gentle push-in (1 = no motion).
    public static func plan(pictureAspect: Double, canvasAspect: Double, subject: UnitRect?, focus: UnitPoint2D?,
                            requestedFit: FitMode, maxZoom: Double = 1.06, margin: Double = 0.04) -> FramingPlan {
        let aspect = pictureAspect.isFinite && pictureAspect > 0 ? pictureAspect : 1
        let canvas = canvasAspect.isFinite && canvasAspect > 0 ? canvasAspect : 1
        let zoom = max(1, min(maxZoom.isFinite ? maxZoom : 1, 3))
        let center = focus ?? subject.map { UnitPoint2D(x: $0.midX, y: $0.midY) } ?? .center

        func make(_ fit: FitMode, _ from: Double, _ to: Double, _ note: String) -> FramingPlan {
            let tight = visibleRect(pictureAspect: aspect, canvasAspect: canvas, fit: fit, scale: to, center: center)
            return FramingPlan(
                fit: fit, scaleFrom: from, scaleTo: to,
                positionFrom: position(forFocus: center, pictureAspect: aspect, canvasAspect: canvas, fit: fit, scale: from),
                positionTo: position(forFocus: center, pictureAspect: aspect, canvasAspect: canvas, fit: fit, scale: to),
                visibleRect: tight, subjectSafe: isSafe(subject: subject, visible: tight, margin: margin), note: note)
        }

        /// Largest zoom in 1…zoom that keeps the subject safe for this fit, or nil if even 1 is unsafe.
        func safeZoom(_ fit: FitMode) -> Double? {
            func safe(_ s: Double) -> Bool {
                isSafe(subject: subject, visible: visibleRect(pictureAspect: aspect, canvasAspect: canvas, fit: fit, scale: s, center: center), margin: margin)
            }
            guard safe(1) else { return nil }
            if safe(zoom) { return zoom }
            var lo = 1.0, hi = zoom
            for _ in 0..<24 {
                let mid = (lo + hi) / 2
                if safe(mid) { lo = mid } else { hi = mid }
            }
            return lo
        }

        if requestedFit == .cover {
            if let z = safeZoom(.cover) {
                return make(.cover, 1, z, z < zoom - 1e-6 ? "Push-in reduced to keep the subject inside the frame." : "Fills the frame; subject clear of the edges.")
            }
            let fallback = safeZoom(.contain) ?? 1
            return make(.contain, 1, fallback, "Filling the frame would cut off the subject, so the whole panel is shown.")
        }
        if requestedFit == .fill {
            return make(.fill, 1, 1, "Stretched to the canvas.")
        }
        if let z = safeZoom(.contain) {
            return make(.contain, 1, z, z < zoom - 1e-6 ? "Push-in reduced to keep the subject inside the frame." : "Whole panel shown with a gentle push-in.")
        }
        return make(.contain, 1, 1, "Whole panel shown without motion.")
    }
}
