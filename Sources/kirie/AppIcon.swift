import CoreGraphics
import Foundation
import MediaServices

/// Draws the Kirie app icon: cut paper over violet, with a play-shaped cut-out.
enum AppIcon {
    static func render(size: Int = 1024) -> CGImage? {
        guard let context = SampleMedia.makeContext(width: size, height: size) else { return nil }
        let s = CGFloat(size)
        let body = CGRect(x: s * 0.098, y: s * 0.098, width: s * 0.804, height: s * 0.804)
        context.addPath(CGPath(roundedRect: body, cornerWidth: s * 0.18, cornerHeight: s * 0.18, transform: nil))
        context.clip()
        context.setFillColor(CGColor(srgbRed: 0.105, green: 0.098, blue: 0.105, alpha: 1))
        context.fill(body)

        func sheet(_ color: CGColor, angle: CGFloat, inset: CGFloat, hole: Bool) {
            context.saveGState()
            context.translateBy(x: s / 2, y: s / 2)
            context.rotate(by: angle * .pi / 180)
            let rect = CGRect(x: -s / 2 + s * inset, y: -s / 2 + s * inset, width: s * (1 - inset * 2), height: s * (1 - inset * 2))
            let path = CGMutablePath()
            path.addRoundedRect(in: rect, cornerWidth: s * 0.03, cornerHeight: s * 0.03)
            if hole {
                // Play triangle, cut out of the paper.
                path.move(to: CGPoint(x: -s * 0.085, y: s * 0.15))
                path.addLine(to: CGPoint(x: s * 0.16, y: 0))
                path.addLine(to: CGPoint(x: -s * 0.085, y: -s * 0.15))
                path.closeSubpath()
            }
            context.addPath(path)
            context.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.35))
            context.setFillColor(color)
            context.fillPath(using: .evenOdd)
            context.restoreGState()
        }
        sheet(CGColor(srgbRed: 0.66, green: 0.59, blue: 0.95, alpha: 1), angle: -7, inset: 0.27, hole: false)
        sheet(CGColor(srgbRed: 0.957, green: 0.925, blue: 0.859, alpha: 1), angle: 5, inset: 0.27, hole: true)
        return context.makeImage()
    }
}
