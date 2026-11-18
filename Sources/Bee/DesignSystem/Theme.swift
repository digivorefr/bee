import AppKit
import SwiftUI

/// The design tokens of `design/language.md`. Views never hard-code a color, a size or a spacing.
enum Theme {
    // MARK: Spacing (4 · 8 · 12 · 16 · 24 · 32)

    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    // MARK: Radii

    enum Radius {
        static let field: CGFloat = 8
        static let token: CGFloat = 5
        static let row: CGFloat = 6
    }

    // MARK: Glyphs

    enum Glyph {
        /// Disclosure chevrons.
        static let chevron: CGFloat = 10
        /// Glyph-only quiet buttons (reveal, copy).
        static let action: CGFloat = 12
        /// The lock of a secret, relative to the size of the text it sits in.
        static let lockScale: CGFloat = 0.72
        /// Room a lock takes before its token, relative to the text size.
        static let lockAdvanceScale: CGFloat = 1.05
    }

    // MARK: Opacity

    enum Opacity {
        static let disabled: Double = 0.4
    }

    // MARK: Type — two voices, three sizes

    enum Size {
        static let caption: CGFloat = 11
        static let body: CGFloat = 13
        static let headline: CGFloat = 15
    }

    /// What Bee says.
    static func text(_ size: CGFloat = Size.body, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    /// What travels on the wire.
    static func mono(_ size: CGFloat = Size.body, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    static func nsMono(_ size: CGFloat = Size.body, weight: NSFont.Weight = .regular) -> NSFont {
        .monospacedSystemFont(ofSize: size, weight: weight)
    }

    // MARK: Colors

    /// Primary text.
    static let ink = Color(nsColor: Palette.ink)
    /// Secondary text; 6:1 on paper.
    static let inkSecondary = Color(nsColor: Palette.inkSecondary)
    /// Disabled and placeholder text.
    static let inkTertiary = Color(nsColor: Palette.inkTertiary)
    /// The page.
    static let paper = Color(nsColor: Palette.paper)
    /// Send only.
    static let honey = Color(nsColor: Palette.honey)
    /// Send while pressed.
    static let honeyPressed = Color(nsColor: Palette.honeyPressed)
    /// Text on honey.
    static let onHoney = Color(nsColor: Palette.onHoney)
    /// Focus ring and caret.
    static let focus = Color(nsColor: Palette.focus)
    /// 1 px outline of what can be written or pressed.
    static let outline = Color(nsColor: Palette.outline)
    /// The one hairline between the two pages.
    static let hairline = Color(nsColor: Palette.hairline)
    /// Ground of a `{{variable}}` token.
    static let tokenGround = Color(nsColor: Palette.tokenGround)
    /// Ground of a hovered or selected row on the paper.
    static let rowHover = Color(nsColor: Palette.rowHover)
    /// The page of a fork: a request being tried, not the one of the collection.
    static let forkPaper = Color(nsColor: Palette.forkPaper)
    /// The mark and the words that say "fork".
    static let forkInk = Color(nsColor: Palette.forkInk)
    static let positive = Color(nsColor: Palette.positive)
    static let warning = Color(nsColor: Palette.warning)
    static let negative = Color(nsColor: Palette.negative)
    static let syntaxString = Color(nsColor: Palette.syntaxString)
    static let syntaxNumber = Color(nsColor: Palette.syntaxNumber)

    /// The same roles as `NSColor`, for AppKit text views.
    enum Palette {
        static let ink = dynamic(light: 0x1D1D1F, dark: 0xF5F5F7)
        static let inkSecondary = dynamic(light: 0x5E5E63, dark: 0xA1A1A6)
        static let inkTertiary = dynamic(light: 0x8E8E93, dark: 0x6E6E73)
        static let paper = dynamic(light: 0xFFFFFF, dark: 0x1C1C1E)
        static let honey = dynamic(light: 0xF2B90C, dark: 0xF2B90C)
        static let honeyPressed = dynamic(light: 0xD9A40A, dark: 0xD9A40A)
        static let onHoney = dynamic(light: 0x1D1D1F, dark: 0x1D1D1F)
        static let focus = dynamic(light: 0x8A5A00, dark: 0xF2B90C)
        static let outline = dynamic(light: 0x8E8E93, dark: 0x6E6E73)
        static let hairline = dynamic(light: 0xE3E3E8, dark: 0x38383A)
        static let tokenGround = dynamic(light: 0xEDEDF0, dark: 0x3A3A3C)
        static let rowHover = dynamic(light: 0xF4F4F6, dark: 0x2C2C2E)
        static let forkPaper = dynamic(light: 0xF1F5FB, dark: 0x1A2029)
        static let forkInk = dynamic(light: 0x33568A, dark: 0x8FB4E8)
        static let positive = dynamic(light: 0x1A7F37, dark: 0x3FB950)
        static let warning = dynamic(light: 0x9A6700, dark: 0xD29922)
        static let negative = dynamic(light: 0xC6372B, dark: 0xF85149)
        static let syntaxString = dynamic(light: 0x0B6B4F, dark: 0x7EE0B8)
        static let syntaxNumber = dynamic(light: 0x3D3DA8, dark: 0xA5A8FF)

        private static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
            NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                return NSColor(hex: isDark ? dark : light)
            }
        }
    }

    // MARK: Motion

    enum Motion {
        /// A section folding or unfolding.
        static let fold = Animation.easeOut(duration: 0.2)
        /// The response arriving, opacity only.
        static let arrive = Animation.easeOut(duration: 0.16)
    }

    // MARK: Layout

    enum Layout {
        /// Inset of a page from its edges.
        static let pageInset: CGFloat = 24
        /// Width of the hanging margin that holds disclosure chevrons and line numbers.
        static let gutter: CGFloat = 20
        /// Vertical inset of the text inside an outlined field.
        static let fieldInset: CGFloat = 6
        /// Width of the rule down the leading edge of a fork's page.
        static let forkRule: CGFloat = 3
        /// Minimum height of a button.
        static let controlHeight: CGFloat = 28
        /// Text above this many UTF-16 units is shown without syntax colors.
        static let highlightLimit = 400_000
        /// Below this detail width the response stacks under the request.
        static let facingPagesMinWidth: CGFloat = 880
    }

    /// The color that tells how the API answered.
    static func statusColor(_ code: Int) -> Color {
        switch code {
        case 100..<300: positive
        case 300..<400: warning
        default: negative
        }
    }
}

extension NSColor {
    /// An opaque sRGB color from `0xRRGGBB`.
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
