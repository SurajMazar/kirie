import AppKit
import ProjectDomain
import SwiftUI

extension Color {
    /// A colour that follows the system appearance.
    init(light: UInt32, dark: UInt32, alpha: Double = 1) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua, .accessibilityHighContrastVibrantDark]) != nil
            let value = isDark ? dark : light
            return NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                           blue: CGFloat(value & 0xFF) / 255, alpha: alpha)
        })
    }
}

extension NSColor {
    static func dynamic(light: UInt32, dark: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua, .accessibilityHighContrastVibrantDark]) != nil
            let value = isDark ? dark : light
            return NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                           blue: CGFloat(value & 0xFF) / 255, alpha: alpha)
        }
    }
}

/// Kirie's design tokens. Every view takes its colours, type, spacing and sizes from here so the
/// workspaces stay one design language. Neutrals are warm (a touch of red in the greys); the single
/// accent is a restrained violet used for selection, focus and the playhead.
enum Theme {
    // Surfaces
    static let window = Color(light: 0xF3F1EF, dark: 0x161415)
    static let panel = Color(light: 0xFAF9F8, dark: 0x1D1B1C)
    static let elevated = Color(light: 0xFFFFFF, dark: 0x262324)
    static let inset = Color(light: 0xEAE7E4, dark: 0x111010)
    static let hover = Color(light: 0xE9E5E2, dark: 0x2C292A)
    static let border = Color(light: 0xDCD7D3, dark: 0x302C2E)
    static let borderStrong = Color(light: 0xC6C0BB, dark: 0x443F41)

    // Text
    static let text = Color(light: 0x1C191A, dark: 0xEDE8E6)
    static let secondary = Color(light: 0x655E60, dark: 0xA09A9B)
    static let tertiary = Color(light: 0x938B8D, dark: 0x6F696B)

    // Accent and state
    static let accent = Color(light: 0x6650C8, dark: 0xA897F2)
    static let accentSoft = Color(light: 0x6650C8, dark: 0xA897F2, alpha: 0.16)
    static let onAccent = Color(light: 0xFFFFFF, dark: 0x1A1626)
    static let success = Color(light: 0x3F7D56, dark: 0x7FBF95)
    static let warning = Color(light: 0x9A6A12, dark: 0xD9A94E)
    static let danger = Color(light: 0xB0443F, dark: 0xE08A84)
    static let warningSoft = Color(light: 0x9A6A12, dark: 0xD9A94E, alpha: 0.14)

    // AppKit equivalents for the custom-drawn timeline
    enum NS {
        static let inset = NSColor.dynamic(light: 0xEAE7E4, dark: 0x111010)
        static let lane = NSColor.dynamic(light: 0xF3F1EF, dark: 0x191718)
        static let laneAlt = NSColor.dynamic(light: 0xEFECEA, dark: 0x1C1A1B)
        static let header = NSColor.dynamic(light: 0xFAF9F8, dark: 0x1D1B1C)
        static let border = NSColor.dynamic(light: 0xDCD7D3, dark: 0x302C2E)
        static let grid = NSColor.dynamic(light: 0xDCD7D3, dark: 0x302C2E, alpha: 0.6)
        static let text = NSColor.dynamic(light: 0x1C191A, dark: 0xEDE8E6)
        static let secondary = NSColor.dynamic(light: 0x655E60, dark: 0xA09A9B)
        static let tertiary = NSColor.dynamic(light: 0x938B8D, dark: 0x6F696B)
        static let accent = NSColor.dynamic(light: 0x6650C8, dark: 0xA897F2)
        static let playhead = NSColor.dynamic(light: 0x5A45BD, dark: 0xC2B5FA)
        static let warning = NSColor.dynamic(light: 0x9A6A12, dark: 0xD9A94E)
        static let clipVideo = NSColor.dynamic(light: 0xCFC8EE, dark: 0x4A4372)
        static let clipImage = NSColor.dynamic(light: 0xBFDDD8, dark: 0x30554F)
        static let clipAudio = NSColor.dynamic(light: 0xC6DDC4, dark: 0x35523A)
        static let clipText = NSColor.dynamic(light: 0xEAD7B0, dark: 0x5E4D2B)
        static let clipSolid = NSColor.dynamic(light: 0xD8D2CF, dark: 0x4A4547)
        static let waveform = NSColor.dynamic(light: 0x3F7D56, dark: 0x9BD0AC)
        static let ghost = NSColor.dynamic(light: 0x6650C8, dark: 0xA897F2, alpha: 0.28)
    }

    // 4-point grid
    enum Space {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    enum Radius {
        static let small: CGFloat = 4
        static let medium: CGFloat = 6
        static let large: CGFloat = 10
    }

    enum Size {
        static let controlCompact: CGFloat = 22
        static let control: CGFloat = 28
        static let icon: CGFloat = 13
        static let toolbar: CGFloat = 44
        static let sidebar: CGFloat = 188
        static let sidebarCollapsed: CGFloat = 48
        static let inspector: CGFloat = 272
        static let library: CGFloat = 264
    }

    enum Motion {
        static let quick = 0.12
        static let standard = 0.2
    }

    // Type scale (SF Pro via the system font)
    enum Font {
        static let workspaceTitle = SwiftUI.Font.system(size: 20, weight: .semibold)
        static let sectionTitle = SwiftUI.Font.system(size: 13, weight: .semibold)
        static let panelHeading = SwiftUI.Font.system(size: 11, weight: .semibold)
        static let body = SwiftUI.Font.system(size: 12)
        static let label = SwiftUI.Font.system(size: 11)
        static let small = SwiftUI.Font.system(size: 10)
        static let mono = SwiftUI.Font.system(size: 11, design: .monospaced)
        static let timecode = SwiftUI.Font.system(size: 13, weight: .medium, design: .monospaced)
    }
}

extension RGBAColor {
    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }

    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
        self.init(r: Double(ns.redComponent), g: Double(ns.greenComponent), b: Double(ns.blueComponent), a: Double(ns.alphaComponent))
    }
}

extension ReviewStatus {
    var tint: Color {
        switch self {
        case .pass: Theme.success
        case .fail: Theme.danger
        case .needsReview: Theme.warning
        }
    }

    /// Shape as well as colour, so status never depends on colour alone.
    var symbol: String {
        switch self {
        case .pass: "checkmark.circle.fill"
        case .fail: "xmark.octagon.fill"
        case .needsReview: "questionmark.diamond.fill"
        }
    }
}
