import CoreText
import SwiftUI
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

public enum Theme {
    public static let windowGround = adaptiveColor(dark: 0x0D0E10, light: 0xF6F6F7)
    public static let sidebarGround = adaptiveColor(dark: 0x121316, light: 0xEEEEF0)
    public static let paneGround = adaptiveColor(dark: 0x0A0B0C, light: 0xFFFFFF)
    public static let paneHeader = adaptiveColor(dark: 0x111215, light: 0xF7F7F8)
    public static let surface = adaptiveColor(dark: 0x15171A, light: 0xFFFFFF)
    public static let surfaceRaised = adaptiveColor(dark: 0x1A1C20, light: 0xFFFFFF)
    public static let controlFill = adaptiveColor(dark: 0xFFFFFF, light: 0x000000, darkAlpha: 0.06, lightAlpha: 0.05)
    public static let selectedFill = adaptiveColor(dark: 0xFFFFFF, light: 0x000000, darkAlpha: 0.075, lightAlpha: 0.07)
    public static let hoverFill = adaptiveColor(dark: 0xFFFFFF, light: 0x000000, darkAlpha: 0.045, lightAlpha: 0.04)
    public static let hairline = adaptiveColor(dark: 0xFFFFFF, light: 0x000000, darkAlpha: 0.06, lightAlpha: 0.08)
    public static let hairlineStrong = adaptiveColor(dark: 0xFFFFFF, light: 0x000000, darkAlpha: 0.1, lightAlpha: 0.12)
    public static let textStrong = adaptiveColor(dark: 0xF1F2F4, light: 0x0B0C0E)
    public static let textPrimary = adaptiveColor(dark: 0xE6E8EB, light: 0x17181B)
    public static let textSecondary = adaptiveColor(dark: 0x9CA2AB, light: 0x5B616B)
    public static let textTertiary = adaptiveColor(dark: 0x7F8590, light: 0x737983)
    public static let textDisabled = adaptiveColor(dark: 0x4B5058, light: 0xB2B6BD)
    public static let accent = adaptiveColor(dark: 0x8EA2FF, light: 0x4257D8)
    public static let danger = adaptiveColor(dark: 0xFF9C9C, light: 0xC2383A)
    public static let success = adaptiveColor(dark: 0x6FD3A0, light: 0x1F8F5A)

    public enum Radius {
        public static let chip: CGFloat = 7
        public static let control: CGFloat = 8
        public static let field: CGFloat = 10
        public static let pane: CGFloat = 10
        public static let card: CGFloat = 12
        public static let popover: CGFloat = 12
    }

    public enum Spacing {
        public static let xxs: CGFloat = 2
        public static let xs: CGFloat = 4
        public static let sm: CGFloat = 6
        public static let md: CGFloat = 8
        public static let lg: CGFloat = 12
        public static let xl: CGFloat = 16
        public static let xxl: CGFloat = 22
        public static let section: CGFloat = 32
    }

    public enum Font {
        // Tests and the Companion may not register the bundled fonts.
        private static let availableFamilies = Set(CTFontManagerCopyAvailableFontFamilyNames() as? [String] ?? [])

        public static func ui(_ size: CGFloat, weight: SwiftUI.Font.Weight = .regular) -> SwiftUI.Font {
            availableFamilies.contains("Geist")
                ? .custom("Geist", size: size).weight(weight)
                : .system(size: size, weight: weight)
        }

        public static func mono(_ size: CGFloat, weight: SwiftUI.Font.Weight = .regular) -> SwiftUI.Font {
            availableFamilies.contains("Geist Mono")
                ? .custom("Geist Mono", size: size).weight(weight)
                : .system(size: size, weight: weight, design: .monospaced)
        }
    }

    static func adaptiveColor(
        dark: UInt32, light: UInt32, darkAlpha: Double = 1, lightAlpha: Double = 1
    ) -> Color {
        #if os(macOS)
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let rgb = isDark ? dark : light
            return NSColor(
                srgbRed: Double((rgb >> 16) & 0xFF) / 255,
                green: Double((rgb >> 8) & 0xFF) / 255,
                blue: Double(rgb & 0xFF) / 255,
                alpha: isDark ? darkAlpha : lightAlpha
            )
        })
        #elseif os(iOS)
        Color(uiColor: UIColor { traits in
            let isDark = traits.userInterfaceStyle == .dark
            let rgb = isDark ? dark : light
            return UIColor(
                red: Double((rgb >> 16) & 0xFF) / 255,
                green: Double((rgb >> 8) & 0xFF) / 255,
                blue: Double(rgb & 0xFF) / 255,
                alpha: isDark ? darkAlpha : lightAlpha
            )
        })
        #endif
    }
}
