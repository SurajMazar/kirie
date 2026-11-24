import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ProjectDomain

/// Transitions between two full-canvas layers. Every transition is a pure function of
/// (outgoing image, incoming image, progress), so preview and export always agree and timing is
/// deterministic.
enum Transitions {
    private static func translate(_ image: CIImage, _ dx: CGFloat, _ dy: CGFloat) -> CIImage {
        image.transformed(by: CGAffineTransform(translationX: dx, y: dy))
    }

    private static func scaled(_ image: CIImage, by scale: CGFloat, rotation: CGFloat = 0, about center: CGPoint) -> CIImage {
        var transform = CGAffineTransform(translationX: center.x, y: center.y)
        transform = transform.rotated(by: rotation).scaledBy(x: scale, y: scale).translatedBy(x: -center.x, y: -center.y)
        return image.transformed(by: transform)
    }

    private static func solid(_ color: CIColor, _ rect: CGRect) -> CIImage { CIImage(color: color).cropped(to: rect) }

    private static func dissolve(_ a: CIImage, _ b: CIImage, _ t: Double, _ rect: CGRect) -> CIImage {
        let filter = CIFilter.dissolveTransition()
        filter.inputImage = a
        filter.targetImage = b
        filter.time = Float(max(0, min(1, t)))
        return (filter.outputImage ?? b).cropped(to: rect)
    }

    private static func masked(_ top: CIImage, over bottom: CIImage, mask: CIImage, _ rect: CGRect) -> CIImage {
        let filter = CIFilter.blendWithMask()
        filter.inputImage = top
        filter.backgroundImage = bottom
        filter.maskImage = mask
        return (filter.outputImage ?? top).cropped(to: rect)
    }

    /// Unit vector the picture travels along for a direction (CI coordinates, y up).
    private static func vector(_ direction: Direction) -> CGPoint {
        switch direction {
        case .left: CGPoint(x: -1, y: 0)
        case .right: CGPoint(x: 1, y: 0)
        case .up: CGPoint(x: 0, y: 1)
        case .down: CGPoint(x: 0, y: -1)
        }
    }

    /// Deterministic pseudo-random value in 0…1.
    static func noise(_ a: Int64, _ b: Int64) -> Double {
        var x = UInt64(bitPattern: a &* 6_364_136_223_846_793_005 &+ b &* 1_442_695_040_888_963_407 &+ 1)
        x ^= x >> 33; x = x &* 0xff51_afd7_ed55_8ccd; x ^= x >> 33
        return Double(x % 10_000) / 10_000
    }

    /// Renders `type` at linear progress `p` (0 = all outgoing, 1 = all incoming).
    static func render(_ type: TransitionType, direction: Direction, progress p: Double, from a: CIImage, to b: CIImage,
                       rect: CGRect, frame: Int64, background: CIColor) -> CIImage {
        let linear = max(0, min(1, p))
        let t = Easing.easeInOut.apply(linear)
        let w = rect.width, h = rect.height
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let v = vector(direction)
        let white = CIColor(red: 1, green: 1, blue: 1, alpha: 1), black = CIColor(red: 0, green: 0, blue: 0, alpha: 1)

        switch type {
        case .dissolve:
            return dissolve(a, b, linear, rect)

        case .dipToBlack, .dipToWhite:
            let tone = type == .dipToBlack ? (0.0, 0.0, 0.0) : (1.0, 1.0, 1.0)
            let amount = linear < 0.5 ? linear * 2 : (1 - linear) * 2
            let cover = solid(CIColor(red: tone.0, green: tone.1, blue: tone.2, alpha: CGFloat(amount)), rect)
            return cover.composited(over: linear < 0.5 ? a : b).cropped(to: rect)

        case .push:
            let outgoing = translate(a, v.x * w * t, v.y * h * t)
            let incoming = translate(b, v.x * w * (t - 1), v.y * h * (t - 1))
            return incoming.composited(over: outgoing).cropped(to: rect)

        case .slide:
            let incoming = translate(b, -v.x * w * (1 - t), -v.y * h * (1 - t))
            return incoming.composited(over: a).cropped(to: rect)

        case .panelSlide:
            // The incoming panel slides in with a white gutter and an ink line on its leading edge.
            let dx = -v.x * w * (1 - t), dy = -v.y * h * (1 - t)
            let incoming = translate(b, dx, dy)
            let gutter = max(6, min(w, h) * 0.03)
            let moved = rect.offsetBy(dx: dx, dy: dy)
            let edge: CGRect, line: CGRect
            switch direction {
            case .left: edge = CGRect(x: moved.minX - gutter, y: rect.minY, width: gutter, height: h); line = CGRect(x: moved.minX - gutter - 3, y: rect.minY, width: 3, height: h)
            case .right: edge = CGRect(x: moved.maxX, y: rect.minY, width: gutter, height: h); line = CGRect(x: moved.maxX + gutter, y: rect.minY, width: 3, height: h)
            case .up: edge = CGRect(x: rect.minX, y: moved.minY - gutter, width: w, height: gutter); line = CGRect(x: rect.minX, y: moved.minY - gutter - 3, width: w, height: 3)
            case .down: edge = CGRect(x: rect.minX, y: moved.maxY, width: w, height: gutter); line = CGRect(x: rect.minX, y: moved.maxY + gutter, width: w, height: 3)
            }
            let ink = CIColor(red: 0.12, green: 0.1, blue: 0.09, alpha: 1)
            return incoming.composited(over: solid(white, edge)).composited(over: solid(ink, line)).composited(over: a).cropped(to: rect)

        case .wipe:
            // A soft edge sweeping across; the incoming picture is revealed behind it.
            let soft = max(8, (abs(v.x) > 0 ? w : h) * 0.12)
            let travel = (abs(v.x) > 0 ? w : h) + soft
            let position = CGFloat(t) * travel
            let p0: CGPoint, p1: CGPoint
            switch direction {
            case .left: p0 = CGPoint(x: rect.maxX - position, y: 0); p1 = CGPoint(x: rect.maxX - position + soft, y: 0)
            case .right: p0 = CGPoint(x: rect.minX + position, y: 0); p1 = CGPoint(x: rect.minX + position - soft, y: 0)
            case .up: p0 = CGPoint(x: 0, y: rect.minY + position); p1 = CGPoint(x: 0, y: rect.minY + position - soft)
            case .down: p0 = CGPoint(x: 0, y: rect.maxY - position); p1 = CGPoint(x: 0, y: rect.maxY - position + soft)
            }
            let gradient = CIFilter(name: "CILinearGradient", parameters: [
                "inputPoint0": CIVector(cgPoint: p0), "inputPoint1": CIVector(cgPoint: p1), "inputColor0": black, "inputColor1": white,
            ])?.outputImage?.cropped(to: rect) ?? solid(white, rect)
            return masked(b, over: a, mask: gradient, rect)

        case .zoom:
            let outgoing = scaled(a, by: 1 + 0.8 * CGFloat(t), about: center)
            let incoming = scaled(b, by: 0.6 + 0.4 * CGFloat(t), about: center)
            return dissolve(outgoing.cropped(to: rect), incoming.cropped(to: rect), t, rect)

        case .iris:
            let reach = hypot(w, h) / 2
            let radius = CGFloat(t) * (reach + 24)
            let gradient = CIFilter(name: "CIRadialGradient", parameters: [
                kCIInputCenterKey: CIVector(cgPoint: center), "inputRadius0": max(0, radius - 24), "inputRadius1": max(0.01, radius),
                "inputColor0": white, "inputColor1": black,
            ])?.outputImage?.cropped(to: rect) ?? solid(white, rect)
            return masked(b, over: a, mask: gradient, rect)

        case .whip:
            let blur = sin(linear * .pi) * Double(max(w, h)) * 0.08
            let angle = abs(v.x) > 0 ? 0.0 : Double.pi / 2
            func smear(_ image: CIImage) -> CIImage {
                guard blur > 0.5 else { return image }
                return CIFilter(name: "CIMotionBlur", parameters: [kCIInputImageKey: image.clampedToExtent(), kCIInputRadiusKey: blur, kCIInputAngleKey: angle])?
                    .outputImage?.cropped(to: rect) ?? image
            }
            let outgoing = translate(smear(a), v.x * w * t, v.y * h * t)
            let incoming = translate(smear(b), v.x * w * (t - 1), v.y * h * (t - 1))
            return incoming.composited(over: outgoing).cropped(to: rect)

        case .spin:
            let outgoing = scaled(a, by: 1 - 0.35 * CGFloat(t), rotation: -CGFloat(t) * .pi / 2, about: center)
            let incoming = scaled(b, by: 0.65 + 0.35 * CGFloat(t), rotation: (1 - CGFloat(t)) * .pi / 2, about: center)
            let base = solid(background, rect)
            return dissolve(outgoing.composited(over: base).cropped(to: rect), incoming.composited(over: base).cropped(to: rect), t, rect)

        case .glitch:
            let strength = sin(linear * .pi)
            let base = linear < 0.5 ? a : b
            guard strength > 0.02 else { return base.cropped(to: rect) }
            // Horizontal bands flip to the incoming picture one by one and jump sideways as they do.
            var bands = CIImage.empty()
            let count: Int64 = 12
            for band in 0..<count {
                let y0 = rect.minY + h * CGFloat(band) / CGFloat(count)
                let slice = CGRect(x: rect.minX - w, y: y0, width: w * 3, height: h / CGFloat(count) + 1)
                // Each band has a fixed threshold, so it switches once and stays switched.
                let source = noise(7, band) < linear ? b : a
                let jump = (noise(frame, band) - 0.5) * 2 * strength * Double(w) * 0.12
                bands = translate(source.cropped(to: slice), jump, 0).composited(over: bands)
            }
            let shift = CGFloat(strength) * w * 0.012
            let red = CIFilter(name: "CIColorMatrix", parameters: [kCIInputImageKey: translate(bands, shift, 0),
                                                                    "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0)])?.outputImage ?? bands
            let cyan = CIFilter(name: "CIColorMatrix", parameters: [kCIInputImageKey: translate(bands, -shift, 0),
                                                                     "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0)])?.outputImage ?? bands
            // Per-channel maximum recombines the split channels without doubling alpha.
            let combined = CIFilter(name: "CIMaximumCompositing", parameters: [kCIInputImageKey: red, kCIInputBackgroundImageKey: cyan])?.outputImage ?? bands
            return combined.composited(over: base).cropped(to: rect)

        case .pageFold:
            // The outgoing page turns away on a hinge to reveal the incoming one.
            let base = solid(background, rect)
            let front = a.composited(over: base).cropped(to: rect)
            let next = b.composited(over: base).cropped(to: rect)
            let angle: Double = switch direction {
            case .left: 0
            case .right: .pi
            case .up: -.pi / 2
            case .down: .pi / 2
            }
            guard let filter = CIFilter(name: "CIPageCurlWithShadowTransition", parameters: [
                kCIInputImageKey: front, kCIInputTargetImageKey: next, "inputBacksideImage": front,
                kCIInputExtentKey: CIVector(cgRect: rect), kCIInputTimeKey: t, kCIInputAngleKey: angle,
                kCIInputRadiusKey: max(40, min(w, h) * 0.18), "inputShadowSize": 0.5, "inputShadowAmount": 0.6,
                "inputShadowExtent": CIVector(cgRect: rect),
            ]), let output = filter.outputImage else { return dissolve(front, next, linear, rect) }
            return output.cropped(to: rect)

        case .polaroidDrop:
            // The incoming picture drops in like an instant photo: tilted, with a white border, then settles flat.
            let fall = Easing.easeOut.apply(min(1, linear / 0.55))
            let settle = Easing.easeInOut.apply(max(0, (linear - 0.45) / 0.55))
            let scale = 0.8 + 0.2 * CGFloat(settle)
            let tilt = (-7 + 9 * fall) * (1 - settle) * .pi / 180 + (1 - fall) * -0.12
            let dropY = h * 1.15 * (1 - CGFloat(fall))
            let border = min(w, h) * 0.035 * (1 - CGFloat(settle))
            let frameRect = rect.insetBy(dx: -border, dy: -border)
            var photo = b.composited(over: solid(white, frameRect))
            let shadowAlpha = 0.38 * (1 - settle)
            if shadowAlpha > 0.01 {
                let shadow = CIFilter(name: "CIGaussianBlur", parameters: [
                    kCIInputImageKey: solid(CIColor(red: 0, green: 0, blue: 0, alpha: CGFloat(shadowAlpha)), frameRect).clampedToExtent(),
                    kCIInputRadiusKey: min(w, h) * 0.03,
                ])?.outputImage?.cropped(to: frameRect.insetBy(dx: -w * 0.1, dy: -h * 0.1)) ?? CIImage.empty()
                photo = photo.composited(over: translate(shadow, 0, -min(w, h) * 0.025))
            }
            let placed = translate(scaled(photo, by: scale, rotation: CGFloat(tilt), about: center), 0, dropY)
            return placed.composited(over: a).cropped(to: rect)

        case .inkSplash:
            // Ink blots spread from several points until the incoming picture covers the frame.
            let reach = hypot(w, h)
            let seeds: [(CGFloat, CGFloat, CGFloat, Double)] = [
                (0.5, 0.5, 0.62, 0), (0.18, 0.78, 0.42, 0.1), (0.82, 0.72, 0.4, 0.16), (0.25, 0.2, 0.42, 0.22),
                (0.8, 0.22, 0.44, 0.13), (0.5, 0.92, 0.3, 0.26), (0.06, 0.48, 0.3, 0.3), (0.95, 0.5, 0.3, 0.24),
            ]
            var mask = solid(black, rect)
            for seed in seeds {
                let local = max(0, min(1, (t - seed.3) / (1 - seed.3)))
                let radius = reach * seed.2 * CGFloat(Easing.easeInOut.apply(local))
                guard radius > 1 else { continue }
                let blot = CIFilter(name: "CIRadialGradient", parameters: [
                    kCIInputCenterKey: CIVector(x: rect.minX + w * seed.0, y: rect.minY + h * seed.1),
                    "inputRadius0": max(0, radius - 6), "inputRadius1": radius, "inputColor0": white,
                    "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: 0),
                ])?.outputImage?.cropped(to: rect) ?? CIImage.empty()
                mask = blot.composited(over: mask)
            }
            return masked(b, over: a, mask: mask, rect)
        }
    }

    /// An entrance for a clip that has nothing to transition from (free tracks, first clip).
    static func entrance(_ type: TransitionType, direction: Direction, progress p: Double, image: CIImage, rect: CGRect) -> CIImage {
        let linear = max(0, min(1, p))
        let t = Easing.easeOut.apply(linear)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let v = vector(direction)
        let faded = LayerEffects.opacity(linear, image)
        switch type {
        case .dissolve, .dipToBlack, .dipToWhite, .glitch, .inkSplash, .pageFold, .wipe:
            return faded
        case .push, .slide, .whip, .panelSlide:
            let distance = min(rect.width, rect.height) * 0.25
            return translate(faded, -v.x * distance * (1 - t), -v.y * distance * (1 - t))
        case .zoom, .iris, .polaroidDrop:
            return scaled(faded, by: 0.6 + 0.4 * CGFloat(Easing.back.apply(linear)), about: center)
        case .spin:
            return scaled(faded, by: 0.7 + 0.3 * CGFloat(t), rotation: (1 - CGFloat(t)) * .pi / 3, about: center)
        }
    }
}
