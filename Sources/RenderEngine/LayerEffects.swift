import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ProjectDomain

/// Colour, looks, keying, masks and blending, all as GPU-backed Core Image operations.
enum LayerEffects {
    // MARK: Colour

    static func applyColor(_ adjust: ColorAdjust, to image: CIImage) -> CIImage {
        guard !adjust.isNeutral else { return image }
        var output = image
        if adjust.exposure != 0 {
            let filter = CIFilter.exposureAdjust()
            filter.inputImage = output
            filter.ev = Float(adjust.exposure)
            output = filter.outputImage ?? output
        }
        if adjust.temperature != 0 || adjust.tint != 0 {
            let filter = CIFilter.temperatureAndTint()
            filter.inputImage = output
            // Positive temperature warms the picture; positive tint leans magenta.
            filter.neutral = CIVector(x: 6500 + CGFloat(adjust.temperature) * 2500, y: CGFloat(adjust.tint) * 80)
            filter.targetNeutral = CIVector(x: 6500, y: 0)
            output = filter.outputImage ?? output
        }
        if adjust.highlights != 0 || adjust.shadows != 0 {
            let filter = CIFilter.highlightShadowAdjust()
            filter.inputImage = output
            filter.highlightAmount = Float(1 + min(0, adjust.highlights) * 0.9)
            filter.shadowAmount = Float(adjust.shadows)
            output = filter.outputImage ?? output
            if adjust.highlights > 0 {
                // Lifting highlights: a gentle gamma below 1 on the bright end.
                let gamma = CIFilter.gammaAdjust()
                gamma.inputImage = output
                gamma.power = Float(1 - adjust.highlights * 0.25)
                output = gamma.outputImage ?? output
            }
        }
        if adjust.contrast != 0 || adjust.saturation != 0 {
            let filter = CIFilter.colorControls()
            filter.inputImage = output
            filter.contrast = Float(1 + adjust.contrast * 0.5)
            filter.saturation = Float(1 + adjust.saturation)
            filter.brightness = 0
            output = filter.outputImage ?? output
        }
        if adjust.sharpen > 0 {
            let filter = CIFilter.sharpenLuminance()
            filter.inputImage = output
            filter.sharpness = Float(adjust.sharpen * 2)
            output = filter.outputImage ?? output
        }
        if adjust.vignette > 0 {
            let filter = CIFilter.vignette()
            filter.inputImage = output
            filter.intensity = Float(adjust.vignette * 2)
            filter.radius = Float(max(image.extent.width, image.extent.height) * 0.6)
            output = filter.outputImage ?? output
        }
        return output.cropped(to: image.extent)
    }

    // MARK: Looks and effects

    static func applyFilters(_ filters: [AppliedFilter], to image: CIImage, frame: Int64) -> CIImage {
        var output = image
        for filter in filters where filter.enabled && filter.intensity > 0 {
            output = apply(filter.kind, intensity: filter.intensity, to: output, frame: frame)
        }
        return output
    }

    private static func mix(_ original: CIImage, _ treated: CIImage, _ amount: Double) -> CIImage {
        guard amount < 0.999 else { return treated.cropped(to: original.extent) }
        let filter = CIFilter.dissolveTransition()
        filter.inputImage = original
        filter.targetImage = treated.cropped(to: original.extent)
        filter.time = Float(amount)
        return (filter.outputImage ?? treated).cropped(to: original.extent)
    }

    private static func named(_ name: String, _ image: CIImage, _ parameters: [String: Any] = [:]) -> CIImage {
        var all = parameters
        all[kCIInputImageKey] = image
        return CIFilter(name: name, parameters: all)?.outputImage ?? image
    }

    static func apply(_ kind: FilterKind, intensity: Double, to image: CIImage, frame: Int64) -> CIImage {
        let extent = image.extent
        let reference = max(extent.width, extent.height)
        switch kind {
        case .mono: return mix(image, named("CIPhotoEffectMono", image), intensity)
        case .noir: return mix(image, named("CIPhotoEffectNoir", image), intensity)
        case .fade: return mix(image, named("CIPhotoEffectFade", image), intensity)
        case .chrome: return mix(image, named("CIPhotoEffectChrome", image), intensity)
        case .instant: return mix(image, named("CIPhotoEffectInstant", image), intensity)
        case .process: return mix(image, named("CIPhotoEffectProcess", image), intensity)
        case .tonal: return mix(image, named("CIPhotoEffectTonal", image), intensity)
        case .transfer: return mix(image, named("CIPhotoEffectTransfer", image), intensity)
        case .sepia: return named("CISepiaTone", image, [kCIInputIntensityKey: intensity]).cropped(to: extent)
        case .vivid:
            let vibrant = named("CIVibrance", image, ["inputAmount": 1.0])
            return mix(image, named("CIColorControls", vibrant, [kCIInputSaturationKey: 1.25, kCIInputContrastKey: 1.06]), intensity)
        case .warm:
            return applyColor(ColorAdjust(saturation: 0.08 * intensity, temperature: 0.55 * intensity), to: image)
        case .cool:
            return applyColor(ColorAdjust(saturation: 0.04 * intensity, temperature: -0.55 * intensity), to: image)
        case .blur:
            return named("CIGaussianBlur", image.clampedToExtent(), [kCIInputRadiusKey: reference * 0.03 * intensity]).cropped(to: extent)
        case .pixellate:
            return named("CIPixellate", image.clampedToExtent(), [kCIInputScaleKey: max(2, reference * 0.035 * intensity),
                                                                    kCIInputCenterKey: CIVector(x: extent.midX, y: extent.midY)]).cropped(to: extent)
        case .bloom:
            return named("CIBloom", image.clampedToExtent(), [kCIInputRadiusKey: reference * 0.02, kCIInputIntensityKey: intensity]).cropped(to: extent)
        case .halftone:
            let dots = named("CICMYKHalftone", image.clampedToExtent(), [kCIInputWidthKey: max(4, reference * 0.008), kCIInputSharpnessKey: 0.8,
                                                                         kCIInputCenterKey: CIVector(x: extent.midX, y: extent.midY)])
            return mix(image, dots, intensity)
        case .inkOutline:
            return mix(image, named("CIComicEffect", image), intensity)
        case .posterize:
            return mix(image, named("CIColorPosterize", image, ["inputLevels": 5.0]), intensity)
        case .vhs:
            // Colour fringing plus soft scanlines.
            let shift = reference * 0.004 * intensity
            let red = named("CIColorMatrix", image.transformed(by: CGAffineTransform(translationX: shift, y: 0)),
                            ["inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0)])
            let cyan = named("CIColorMatrix", image.transformed(by: CGAffineTransform(translationX: -shift, y: 0)),
                             ["inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0)])
            let fringed = named("CIMaximumCompositing", red, [kCIInputBackgroundImageKey: cyan]).cropped(to: extent)
            let lines = CIFilter(name: "CIStripesGenerator", parameters: [
                "inputColor0": CIColor(red: 0, green: 0, blue: 0, alpha: 0.18 * intensity), "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: 0),
                kCIInputWidthKey: max(2, reference * 0.003), kCIInputSharpnessKey: 0.6,
            ])?.outputImage?.transformed(by: CGAffineTransform(rotationAngle: .pi / 2)).cropped(to: extent)
            let softened = named("CIColorControls", fringed, [kCIInputSaturationKey: 1.15, kCIInputContrastKey: 0.95])
            return (lines?.composited(over: softened) ?? softened).cropped(to: extent)
        case .grain:
            guard let noise = CIFilter(name: "CIRandomGenerator")?.outputImage else { return image }
            // Shift the noise field every frame pair so the grain lives without strobing.
            let offset = CGFloat((frame / 2) % 97) * 13
            let mono = named("CIColorMatrix", noise.transformed(by: CGAffineTransform(translationX: offset, y: offset * 0.7)), [
                "inputRVector": CIVector(x: 0.6, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0.6, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 0.6, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: 0.2, y: 0.2, z: 0.2, w: CGFloat(0.22 * intensity)),
            ]).cropped(to: extent)
            let textured = named("CISoftLightBlendMode", mono, [kCIInputBackgroundImageKey: image])
            // Keep the picture's own transparency.
            return named("CIBlendWithAlphaMask", textured, [kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: image]).cropped(to: extent)
        }
    }

    // MARK: Chroma key

    private static let cubeCache = NSCache<NSString, NSData>()

    static func applyChromaKey(_ key: ChromaKey, to image: CIImage) -> CIImage {
        let size = 32
        let cacheKey = "\(key.color.hex)-\(key.tolerance)-\(key.softness)" as NSString
        let data: NSData
        if let cached = cubeCache.object(forKey: cacheKey) {
            data = cached
        } else {
            let keyHue = hue(key.color.r, key.color.g, key.color.b)
            var cube = [Float](repeating: 0, count: size * size * size * 4)
            var offset = 0
            for b in 0..<size {
                for g in 0..<size {
                    for r in 0..<size {
                        let red = Double(r) / Double(size - 1), green = Double(g) / Double(size - 1), blue = Double(b) / Double(size - 1)
                        let maxValue = max(red, green, blue), minValue = min(red, green, blue)
                        let saturation = maxValue > 0 ? (maxValue - minValue) / maxValue : 0
                        var distance = abs(hue(red, green, blue) - keyHue)
                        distance = min(distance, 1 - distance)
                        var alpha = 1.0
                        // Only saturated, reasonably bright pixels near the key hue are removed.
                        if saturation > 0.25, maxValue > 0.2 {
                            let inner = key.tolerance * 0.5, outer = inner + max(0.005, key.softness * 0.5)
                            if distance <= inner { alpha = 0 } else if distance < outer { alpha = (distance - inner) / (outer - inner) }
                        }
                        cube[offset] = Float(red * alpha); cube[offset + 1] = Float(green * alpha)
                        cube[offset + 2] = Float(blue * alpha); cube[offset + 3] = Float(alpha)
                        offset += 4
                    }
                }
            }
            data = cube.withUnsafeBufferPointer { NSData(bytes: $0.baseAddress, length: $0.count * MemoryLayout<Float>.size) }
            cubeCache.setObject(data, forKey: cacheKey)
        }
        let filter = CIFilter.colorCube()
        filter.inputImage = image
        filter.cubeDimension = Float(size)
        filter.cubeData = data as Data
        return filter.outputImage?.cropped(to: image.extent) ?? image
    }

    private static func hue(_ r: Double, _ g: Double, _ b: Double) -> Double {
        let maxValue = max(r, g, b), minValue = min(r, g, b)
        let delta = maxValue - minValue
        guard delta > 1e-9 else { return 0 }
        var h: Double
        if maxValue == r { h = ((g - b) / delta).truncatingRemainder(dividingBy: 6) } else if maxValue == g { h = (b - r) / delta + 2 } else { h = (r - g) / delta + 4 }
        h /= 6
        return h < 0 ? h + 1 : h
    }

    // MARK: Masks

    static func applyMask(_ mask: ClipMask, to image: CIImage) -> CIImage {
        let extent = image.extent
        // Mask rect in image pixels (flip the y axis: model is top-left origin).
        let rect = CGRect(x: extent.minX + mask.rect.x * extent.width, y: extent.minY + (1 - mask.rect.maxY) * extent.height,
                          width: mask.rect.width * extent.width, height: mask.rect.height * extent.height)
        let feather = max(0.5, mask.feather * min(rect.width, rect.height) * 0.5)
        let white = CIColor(red: 1, green: 1, blue: 1, alpha: 1), black = CIColor(red: 0, green: 0, blue: 0, alpha: 1)
        var shape: CIImage
        switch mask.shape {
        case .rectangle:
            let solid = CIImage(color: white).cropped(to: rect.insetBy(dx: feather, dy: feather))
            shape = solid.composited(over: CIImage(color: black).cropped(to: extent))
            shape = (CIFilter(name: "CIGaussianBlur", parameters: [kCIInputImageKey: shape.clampedToExtent(), kCIInputRadiusKey: feather * 0.5])?.outputImage ?? shape).cropped(to: extent)
        case .ellipse:
            let radius = min(rect.width, rect.height) / 2
            let gradient = CIFilter(name: "CIRadialGradient", parameters: [
                kCIInputCenterKey: CIVector(x: 0, y: 0), "inputRadius0": max(0, radius - feather), "inputRadius1": radius,
                "inputColor0": white, "inputColor1": black,
            ])?.outputImage ?? CIImage(color: white)
            // Stretch the circle into the rect's ellipse.
            let stretch = CGAffineTransform(translationX: rect.midX, y: rect.midY)
                .scaledBy(x: rect.width / max(1, radius * 2), y: rect.height / max(1, radius * 2))
            shape = gradient.transformed(by: stretch).cropped(to: extent)
        case .linear, .mirror:
            let gradient = CIFilter(name: "CILinearGradient", parameters: [
                "inputPoint0": CIVector(x: rect.minX, y: rect.minY), "inputPoint1": CIVector(x: rect.minX, y: rect.minY + max(1, feather * 2)),
                "inputColor0": black, "inputColor1": white,
            ])?.outputImage?.cropped(to: extent) ?? CIImage(color: white).cropped(to: extent)
            if mask.shape == .mirror {
                let top = CIFilter(name: "CILinearGradient", parameters: [
                    "inputPoint0": CIVector(x: rect.minX, y: rect.maxY), "inputPoint1": CIVector(x: rect.minX, y: rect.maxY - max(1, feather * 2)),
                    "inputColor0": black, "inputColor1": white,
                ])?.outputImage?.cropped(to: extent) ?? gradient
                shape = CIFilter(name: "CIMultiplyCompositing", parameters: [kCIInputImageKey: gradient, kCIInputBackgroundImageKey: top])?.outputImage ?? gradient
            } else {
                shape = gradient
            }
        }
        if mask.inverted {
            shape = CIFilter(name: "CIColorInvert", parameters: [kCIInputImageKey: shape])?.outputImage ?? shape
        }
        let filter = CIFilter.blendWithMask()
        filter.inputImage = image
        filter.backgroundImage = CIImage.empty()
        filter.maskImage = shape
        return filter.outputImage?.cropped(to: extent) ?? image
    }

    // MARK: Blending

    static func blend(_ top: CIImage, over bottom: CIImage, mode: BlendMode) -> CIImage {
        let name: String? = switch mode {
        case .normal: nil
        case .multiply: "CIMultiplyBlendMode"
        case .screen: "CIScreenBlendMode"
        case .overlay: "CIOverlayBlendMode"
        case .softLight: "CISoftLightBlendMode"
        case .hardLight: "CIHardLightBlendMode"
        case .darken: "CIDarkenBlendMode"
        case .lighten: "CILightenBlendMode"
        case .colorDodge: "CIColorDodgeBlendMode"
        case .colorBurn: "CIColorBurnBlendMode"
        case .difference: "CIDifferenceBlendMode"
        }
        guard let name, let filter = CIFilter(name: name, parameters: [kCIInputImageKey: top, kCIInputBackgroundImageKey: bottom]),
              let output = filter.outputImage else { return top.composited(over: bottom) }
        return output
    }

    static func opacity(_ value: Double, _ image: CIImage) -> CIImage {
        guard value < 0.999 else { return image }
        let filter = CIFilter.colorMatrix()
        filter.inputImage = image
        filter.aVector = CIVector(x: 0, y: 0, z: 0, w: CGFloat(max(0, value)))
        return filter.outputImage ?? image
    }
}
