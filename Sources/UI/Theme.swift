// Design tokens (T3 Code-like neutral look). Names are FROZEN; values may be tuned by the UI shell.
import SwiftUI
import AppKit

enum Theme {
    // Surfaces (adaptive light/dark)
    static let window      = Color.dynamic(dark: 0x141414, light: 0xFAFAFA)
    static let sidebar     = Color.dynamic(dark: 0x181818, light: 0xF2F2F2)
    static let surface     = Color.dynamic(dark: 0x1C1C1C, light: 0xFFFFFF)
    static let raised      = Color.dynamic(dark: 0x232323, light: 0xFFFFFF)
    static let hairline    = Color.dynamic(dark: 0xFFFFFF, light: 0x000000, darkAlpha: 0.08, lightAlpha: 0.08)
    static let hairlineStrong = Color.dynamic(dark: 0xFFFFFF, light: 0x000000, darkAlpha: 0.14, lightAlpha: 0.14)

    // Text
    static let textPrimary   = Color.dynamic(dark: 0xEDEDED, light: 0x1A1A1A)
    static let textSecondary = Color.dynamic(dark: 0x9A9A9A, light: 0x6B6B6B)
    static let textTertiary  = Color.dynamic(dark: 0x636363, light: 0xA0A0A0)

    // Accents — one muted accent; warm backlight only inside visualizers.
    static let accent  = Color.dynamic(dark: 0x7C9CFF, light: 0x3B5BDB)
    static let ok      = Color.dynamic(dark: 0x4ADE80, light: 0x16A34A)
    static let warn    = Color.dynamic(dark: 0xF5B544, light: 0xB7791F)
    static let err     = Color.dynamic(dark: 0xF87171, light: 0xDC2626)
    static let glow    = Color.dynamic(dark: 0xFFB45A, light: 0xE8922E)
    /// Empty meter track / inactive indicator on a card surface.
    static let track   = Color.dynamic(dark: 0x2A2A2A, light: 0xE4E4E7)
    static let keyOff  = Color.dynamic(dark: 0x262626, light: 0xF2F2F3)
    static let keyBase = Color.dynamic(dark: 0x1A1A1A, light: 0xE2E2E4)

    // Geometry
    enum Radius { static let window: CGFloat = 10; static let card: CGFloat = 10; static let control: CGFloat = 6; static let chip: CGFloat = 4; static let key: CGFloat = 5 }
    static let pageWidth: CGFloat = 880
    enum Space { static let xs: CGFloat = 4; static let s: CGFloat = 8; static let m: CGFloat = 12; static let l: CGFloat = 16; static let xl: CGFloat = 24 }

    // Type
    enum Font {
        static let title   = SwiftUI.Font.system(size: 20, weight: .semibold)
        static let section = SwiftUI.Font.system(size: 11, weight: .semibold)
        static let body    = SwiftUI.Font.system(size: 13)
        static let label   = SwiftUI.Font.system(size: 12, weight: .medium)
        static let caption = SwiftUI.Font.system(size: 11)
        static let numeral = SwiftUI.Font.system(size: 13).monospacedDigit()
        static let bigStat = SwiftUI.Font.system(size: 28, weight: .light).monospacedDigit()
    }

    static let snappy = Animation.snappy(duration: 0.18)
}

extension Color {
    /// Adaptive color from hex for dark / light appearance.
    static func dynamic(dark: UInt32, light: UInt32, darkAlpha: CGFloat = 1, lightAlpha: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: isDark ? darkAlpha : lightAlpha)
        })
    }
}
