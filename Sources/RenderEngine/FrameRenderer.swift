import CoreImage
import CoreMedia
import Foundation
import ProjectDomain

/// Composes one output frame from a render model. Pure: the same model and time always produce the
/// same image. Used by the AVFoundation compositor (preview and export) and directly by tests.
public enum FrameRenderer {
    /// Shared GPU context. Core Image compiles the whole frame graph into Metal shaders.
    public static let context: CIContext = {
        var options: [CIContextOption: Any] = [.cacheIntermediates: false, .name: "kirie.render"]
        if let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) { options[.workingColorSpace] = space }
        return CIContext(options: options)
    }()

    public static var outputColorSpace: CGColorSpace {
        CGColorSpace(name: CGColorSpace.itur_709) ?? CGColorSpaceCreateDeviceRGB()
    }

    public typealias FrameSource = (CMPersistentTrackID) -> CIImage?

    public static func render(model: RenderModel, at time: RationalTime, sourceFrame: FrameSource) -> CIImage {
        let output = CGRect(origin: .zero, size: model.outputSize)
        let canvas = model.canvasRect
        let frame = time.frameIndex(rate: model.frameRate)
        let background = model.background.ciColor
        var result = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1)).cropped(to: output)
        result = CIImage(color: background).cropped(to: canvas).composited(over: result)

        for track in model.tracks {
            let active = track.layers.filter { $0.clip.range.contains(time) }
            guard !active.isEmpty else { continue }
            if track.kind.isMagnetic, active.count >= 2, let incoming = active.last, let transition = incoming.clip.transitionIn,
               transition.duration.isPositive {
                // Two main-track clips overlap exactly for the length of the incoming clip's transition.
                let outgoing = active[active.count - 2]
                let progress = (time - incoming.clip.start).seconds / transition.duration.seconds
                let a = layerImage(outgoing, model: model, time: time, frame: frame, sourceFrame: sourceFrame)
                let b = layerImage(incoming, model: model, time: time, frame: frame, sourceFrame: sourceFrame)
                let type = model.options.reduceMotion ? transition.type.reducedMotionAlternative : transition.type
                let mixed = Transitions.render(type, direction: transition.direction, progress: progress, from: a, to: b,
                                               rect: canvas, frame: frame, background: background)
                result = mixed.composited(over: result)
                continue
            }
            for layer in active {
                var image = layerImage(layer, model: model, time: time, frame: frame, sourceFrame: sourceFrame)
                if let transition = layer.clip.transitionIn, transition.duration.isPositive {
                    let progress = (time - layer.clip.start).seconds / transition.duration.seconds
                    if progress < 1 {
                        let type = model.options.reduceMotion ? transition.type.reducedMotionAlternative : transition.type
                        image = Transitions.entrance(type, direction: transition.direction, progress: progress, image: image, rect: canvas)
                    }
                }
                result = LayerEffects.blend(image.cropped(to: canvas), over: result, mode: layer.clip.blendMode)
            }
        }
        return result.cropped(to: output)
    }

    // MARK: Layers

    static func layerImage(_ layer: RenderLayer, model: RenderModel, time: RationalTime, frame: Int64, sourceFrame: FrameSource) -> CIImage {
        let clip = layer.clip
        let canvas = model.canvasRect
        let local = time - clip.start
        let opacity = clip.value(of: .opacity, at: local)

        switch layer.source {
        case .text:
            return textImage(clip, model: model, local: local, frame: frame)
        case .solid(let color):
            return LayerEffects.opacity(opacity, CIImage(color: color.ciColor).cropped(to: canvas))
        case .offline(let name):
            return LayerEffects.opacity(opacity, offlineImage(name: name, model: model))
        case .image(let url):
            guard let image = model.images.image(at: url) else { return offlineImage(name: clip.name, model: model) }
            return place(image, clip: clip, model: model, local: local, frame: frame)
        case .video(let trackID, let rotation):
            guard var image = sourceFrame(trackID) else { return CIImage.empty() }
            switch rotation {
            case 90: image = image.oriented(.right)
            case 180: image = image.oriented(.down)
            case 270: image = image.oriented(.left)
            default: break
            }
            image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
            return place(image, clip: clip, model: model, local: local, frame: frame)
        }
    }

    /// Crops, grades, fits and transforms a picture into canvas space.
    static func place(_ source: CIImage, clip: Clip, model: RenderModel, local: RationalTime, frame: Int64) -> CIImage {
        let canvas = model.canvasRect
        let extent = source.extent
        guard extent.width > 0, extent.height > 0, !extent.isInfinite else { return CIImage.empty() }
        let crop = clip.transform.crop
        // Model crops use a top-left origin; Core Image's origin is bottom-left.
        let cropRect = CGRect(x: extent.minX + crop.x * extent.width, y: extent.minY + (1 - crop.maxY) * extent.height,
                              width: crop.width * extent.width, height: crop.height * extent.height).integral.intersection(extent)
        guard cropRect.width >= 1, cropRect.height >= 1 else { return CIImage.empty() }
        var picture = source.cropped(to: cropRect).transformed(by: CGAffineTransform(translationX: -cropRect.minX, y: -cropRect.minY))

        if let key = clip.chromaKey { picture = LayerEffects.applyChromaKey(key, to: picture) }
        picture = LayerEffects.applyColor(clip.color, to: picture)
        picture = LayerEffects.applyFilters(clip.filters, to: picture, frame: frame)
        if let mask = clip.mask { picture = LayerEffects.applyMask(mask, to: picture) }

        let w = cropRect.width, h = cropRect.height
        var sx: CGFloat, sy: CGFloat
        switch clip.transform.fit {
        case .contain: sx = min(canvas.width / w, canvas.height / h); sy = sx
        case .cover: sx = max(canvas.width / w, canvas.height / h); sy = sx
        case .fill: sx = canvas.width / w; sy = canvas.height / h
        }
        let scale = CGFloat(clip.value(of: .scale, at: local))
        let rotation = CGFloat(clip.value(of: .rotation, at: local)) * .pi / 180
        let center = CGPoint(x: canvas.minX + CGFloat(clip.value(of: .positionX, at: local)) * canvas.width,
                             y: canvas.maxY - CGFloat(clip.value(of: .positionY, at: local)) * canvas.height)
        sx *= scale * (clip.transform.flipHorizontal ? -1 : 1)
        sy *= scale * (clip.transform.flipVertical ? -1 : 1)
        // Clockwise on screen is a negative angle in Core Image's y-up space.
        let transform = CGAffineTransform(translationX: center.x, y: center.y).rotated(by: -rotation).scaledBy(x: sx, y: sy)
            .translatedBy(x: -w / 2, y: -h / 2)
        var placed = picture.samplingLinear().transformed(by: transform)

        switch clip.transform.backdrop {
        case .none:
            break
        case .color:
            let color = clip.transform.backdropColor ?? model.background
            placed = placed.composited(over: CIImage(color: color.ciColor).cropped(to: canvas))
        case .blur:
            let cover = max(canvas.width / w, canvas.height / h) * 1.08
            let fillTransform = CGAffineTransform(translationX: canvas.midX, y: canvas.midY).scaledBy(x: cover, y: cover).translatedBy(x: -w / 2, y: -h / 2)
            let filled = picture.transformed(by: fillTransform).cropped(to: canvas)
            let blurred = CIFilter(name: "CIGaussianBlur", parameters: [kCIInputImageKey: filled.clampedToExtent(), kCIInputRadiusKey: canvas.width * 0.045])?
                .outputImage?.cropped(to: canvas) ?? filled
            let dimmed = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.28)).cropped(to: canvas).composited(over: blurred)
            placed = placed.composited(over: dimmed)
        }
        return LayerEffects.opacity(clip.value(of: .opacity, at: local), placed.cropped(to: canvas))
    }

    private static func offlineImage(name: String, model: RenderModel) -> CIImage {
        let canvas = model.canvasRect
        let base = CIImage(color: CIColor(red: 0.16, green: 0.14, blue: 0.15, alpha: 1)).cropped(to: canvas)
        var style = TextStyle(fontName: "Helvetica Neue Medium", fontSize: 40, color: RGBAColor(r: 0.85, g: 0.82, b: 0.8), shadow: nil)
        style.maxWidth = 0.8
        guard let label = TextRasterizer.shared.block("Media offline\n\(name)", style: style, scale: model.textScale, maxWidth: canvas.width * 0.8) else { return base }
        let extent = label.image.extent
        let moved = label.image.transformed(by: CGAffineTransform(translationX: canvas.midX - extent.width / 2, y: canvas.midY - extent.height / 2))
        return moved.composited(over: base)
    }

    // MARK: Text

    static func textImage(_ clip: Clip, model: RenderModel, local: RationalTime, frame: Int64) -> CIImage {
        guard let content = clip.text else { return CIImage.empty() }
        let canvas = model.canvasRect
        let seconds = local.seconds
        if content.role == .lyric, content.lyric != nil {
            let lettering = LyricRenderer.layer(clip: clip, local: seconds, canvas: canvas, scale: model.textScale, frame: frame)
            return LayerEffects.opacity(clip.value(of: .opacity, at: local), lettering)
        }
        let string = TextRasterizer.displayString(content)
        let duration = clip.duration.seconds
        var highlight: Range<Int>?
        var visible: Int?
        var alpha = 1.0
        var scaleFactor: CGFloat = 1
        var offsetY: CGFloat = 0

        switch content.animation {
        case .none:
            break
        case .fade:
            alpha = max(0, min(1, seconds / 0.25, (duration - seconds) / 0.25))
        case .pop:
            scaleFactor = 0.6 + 0.4 * CGFloat(Easing.back.apply(min(1, seconds / 0.22)))
            alpha = min(1, seconds / 0.08)
        case .bounce:
            let t = min(1, seconds / 0.6)
            offsetY = -44 * model.textScale * CGFloat((1 - Easing.bounce.apply(t)))
            alpha = min(1, seconds / 0.06)
        case .typewriter:
            let count = string.count
            let span = min(duration * 0.7, Double(count) * 0.05)
            visible = span > 0 ? min(count, Int(Double(count) * seconds / span) + 1) : count
        case .karaoke:
            highlight = karaokeRange(content: content, string: string, seconds: seconds, duration: duration)
        }

        guard let rendered = TextRasterizer.shared.block(string, style: content.style, scale: model.textScale,
                                                         maxWidth: canvas.width * CGFloat(content.style.maxWidth),
                                                         highlight: highlight, visibleCharacters: visible) else { return CIImage.empty() }
        let extent = rendered.image.extent
        let scale = CGFloat(clip.value(of: .scale, at: local)) * scaleFactor
        let rotation = CGFloat(clip.value(of: .rotation, at: local)) * .pi / 180
        let center = CGPoint(x: canvas.minX + CGFloat(clip.value(of: .positionX, at: local)) * canvas.width,
                             y: canvas.maxY - CGFloat(clip.value(of: .positionY, at: local)) * canvas.height - offsetY)
        let transform = CGAffineTransform(translationX: center.x, y: center.y).rotated(by: -rotation).scaledBy(x: scale, y: scale)
            .translatedBy(x: -extent.width / 2, y: -extent.height / 2)
        let placed = rendered.image.transformed(by: transform)
        return LayerEffects.opacity(clip.value(of: .opacity, at: local) * alpha, placed).cropped(to: canvas)
    }

    /// Character range of the word being sung at `seconds`.
    static func karaokeRange(content: TextContent, string: String, seconds: Double, duration: Double) -> Range<Int>? {
        // Character ranges of the whitespace-separated words in the displayed string.
        var ranges: [Range<Int>] = []
        var start: Int?
        for (index, character) in string.enumerated() {
            if character.isWhitespace {
                if let s = start { ranges.append(s..<index); start = nil }
            } else if start == nil {
                start = index
            }
        }
        if let s = start { ranges.append(s..<string.count) }
        guard !ranges.isEmpty else { return nil }
        if content.words.count == ranges.count {
            for (index, word) in content.words.enumerated() where seconds >= word.start.seconds && seconds < word.end.seconds {
                return ranges[index]
            }
            return nil
        }
        // No word timing: move through the words evenly.
        guard duration > 0 else { return nil }
        let index = min(ranges.count - 1, max(0, Int(seconds / duration * Double(ranges.count))))
        return ranges[index]
    }

    // MARK: Stills

    /// Renders a frame of a model that needs no decoded video (stills, text, solids) to a bitmap.
    public static func renderImage(model: RenderModel, at time: RationalTime, sourceFrame: FrameSource = { _ in nil }) -> CGImage? {
        let image = render(model: model, at: time, sourceFrame: sourceFrame)
        return context.createCGImage(image, from: CGRect(origin: .zero, size: model.outputSize), format: .RGBA8,
                                     colorSpace: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB())
    }
}
