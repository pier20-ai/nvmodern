import AppKit
import SwiftUI

enum DesignTokens {
    enum Surface {
        /// Tab content background — intentionally matched to the tab
        /// color so the omnibox ribbon, launchpad, and miller columns blend
        /// seamlessly into the tab that hosts them.
        static let base = dynamic(dark: 0x1E1E1E, light: 0xFFFFFF)
        static let raised = dynamic(dark: 0x16161B, light: 0xFFFFFF)
        static let overlay = dynamic(dark: 0x2A2A2A, light: 0xF0F0F2)
        static let selected = dynamic(dark: 0x363636, light: 0xE4E4E8)

        /// The recessed chrome plane. The sidebar and the tab strip
        /// are the same surface — one L-shaped chrome region with the document
        /// card raised inside it. The sidebar used to paint its own
        /// `NSVisualEffectView` instead, which made it a third tone that agreed
        /// with neither the strip above it nor the content beside it; a window
        /// cannot hold one blurred plane and two flat ones and still look
        /// deliberate.
        static let chrome = dynamic(dark: 0x262629, light: 0xE8E8EA)

        /// `chrome` as an `NSColor`, for the AppKit layer that backs the
        /// sidebar. That layer has to be a real view rather than a SwiftUI fill
        /// so it can keep forwarding window drags.
        static let chromeNSColor = dynamicNSColor(dark: 0x262629, light: 0xE8E8EA)

        /// The tab strip is the same plane as the sidebar. Kept as its own name
        /// for the call sites that mean the strip.
        static let tabStrip = chrome

        /// Sidebar row states.
        ///
        /// Deliberately *not* `activeSelection`. Sidebar selection is
        /// persistent, unlike a palette highlight that exists for one
        /// keystroke, so a full-strength accent slab 32pt tall ends up the
        /// loudest object in the window — louder than the document it points
        /// at. A neutral fill plus a heavier label carries the same
        /// information without competing with the content.
        static let sidebarRowSelected = Color.primary.opacity(0.10)
        static let sidebarRowSelectedInactive = Color.primary.opacity(0.07)
        static let sidebarRowHover = Color.primary.opacity(0.045)

        /// Native list selection colors. Use these for transient, keyboard-driven
        /// highlights (palette results, tab switcher) where a loud accent is the
        /// point. For persistent list chrome prefer the sidebar row tokens above.
        static let activeSelection = Color(nsColor: .selectedContentBackgroundColor)
        static let inactiveSelection = Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
    }

    enum TextStyle {
        static let primary = dynamic(dark: 0xF2F2F5, light: 0x1A1A1F)
        static let secondary = dynamic(dark: 0xA0A0A8, light: 0x606068)
        static let tertiary = dynamic(dark: 0x606068, light: 0xA0A0A8)
    }

    enum Accent {
        static let nav = color(0x5A8DEE)
        static let intent = color(0xE0A64B)
        static let search = color(0x4FB0A6)
        /// The palette's surface wash: a cool corner and a warm corner, used at
        /// low opacity over the frost so the pane has a colour without a tint.
        static let paletteCool = color(0x7A9CF2)
        static let paletteWarm = color(0xF2A4B8)
        static let destructive = color(0xE0584B)
        static let success = color(0x5CB870)
    }

    enum Spacing {
        static let space1: CGFloat = 2
        static let space2: CGFloat = 4
        static let space3: CGFloat = 8
        static let space4: CGFloat = 12
        static let space5: CGFloat = 16
        static let space6: CGFloat = 24
        static let space7: CGFloat = 32
    }

    enum Radius {
        static let input: CGFloat = 4
        static let card: CGFloat = 8
        /// Concentric with the palette's noun pill: the pill's capsule radius
        /// (about 10.5 pt) plus its 12 pt inset from the edge.
        static let palette: CGFloat = 22
        static let pill: CGFloat = 999
    }

    enum Motion {
        static let bloomDuration: Double = 0.10
        static let collapseDuration: Double = 0.08
        static let swapDuration: Double = 0.12
        static let breadcrumbExpandDuration: Double = 0.15
        static let rowSelectDuration: Double = 0.08
        static let tabSwitchDuration: Double = 0.06

        static let bloom = Animation.timingCurve(0.2, 0, 0, 1, duration: bloomDuration)
        static let collapse = Animation.timingCurve(0.4, 0, 1, 1, duration: collapseDuration)
        static let paletteBodyReveal = Animation.timingCurve(0.2, 0, 0, 1, duration: 0.08).delay(0.015)
        static let paletteBodyHide = Animation.timingCurve(0.4, 0, 1, 1, duration: 0.05)
        static let swap = Animation.linear(duration: swapDuration)
        static let breadcrumbExpand = Animation.timingCurve(0.2, 0, 0, 1, duration: breadcrumbExpandDuration)
    }

    enum Typography {
        // Edit this to tune the palette input font size.
        static let inputPointSize: CGFloat = 16

        static let caption = Font.system(size: 11, weight: .regular)
        static let captionMono = Font.system(size: 11, weight: .regular, design: .monospaced)
        static let secondary = Font.system(size: 12, weight: .regular)
        static let body = Font.system(size: 13, weight: .regular)
        static let bodyMedium = Font.system(size: 13, weight: .medium)
        static let bodySemibold = Font.system(size: 13, weight: .semibold)
        static let bodyMono = Font.system(size: 12, weight: .regular, design: .monospaced)
        static let heading = Font.system(size: 15, weight: .semibold)
        static let display = Font.system(size: 22, weight: .semibold)
    }

    enum ControlSize {
        static let searchboxHeight: CGFloat = 32
        static let listRowHeight: CGFloat = 32
        static let segmentedControlHeight: CGFloat = 24
        static let contextButtonSize: CGFloat = 24
        static let contextButtonIconSize: CGFloat = 14
        static let millerCellHeight: CGFloat = 28
        static let tabHeight: CGFloat = 32
    }

    enum WorkspaceChrome {
        static let tabBarHeight: CGFloat = 40
        static let standardToolbarVerticalPadding: CGFloat = 3
        static let standardToolbarHeight = ControlSize.searchboxHeight
            + (standardToolbarVerticalPadding * 2)
        static let separatorColor = TextStyle.tertiary.opacity(0.16)

        static func sidebarToolbarTopInset(titlebarHeight: CGFloat) -> CGFloat {
            guard titlebarHeight > 0 else { return 0 }
            return max(0, tabBarHeight - titlebarHeight)
        }
    }

    private static func color(_ hex: Int) -> Color {
        Color(nsColor: nsColor(hex: hex))
    }

    private static func dynamic(dark: Int, light: Int) -> Color {
        Color(nsColor: dynamicNSColor(dark: dark, light: light))
    }

    private static func dynamicNSColor(dark: Int, light: Int) -> NSColor {
        NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [.darkAqua, .vibrantDark, .aqua, .vibrantLight])
            let isDark = match == .darkAqua || match == .vibrantDark
            return isDark ? nsColor(hex: dark) : nsColor(hex: light)
        }
    }

    private static func nsColor(hex: Int) -> NSColor {
        let r = CGFloat((hex >> 16) & 0xFF) / 255.0
        let g = CGFloat((hex >> 8) & 0xFF) / 255.0
        let b = CGFloat(hex & 0xFF) / 255.0
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }
}
