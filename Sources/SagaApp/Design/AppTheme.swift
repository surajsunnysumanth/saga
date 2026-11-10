import SwiftUI
import AppKit

/// The app's single source of truth for the visual refresh described in
/// `docs/DESIGN.md` (section "App (SwiftUI) — CleanMyMac-inspired, still native").
///
/// Every view that takes part in the refresh reads colour, radius, type, spacing
/// and motion from here instead of hard-coding values, so parallel work cannot
/// drift apart.
///
/// Conventions
/// - Prefer the semantic groups (`Surface`, `Typography`, `Radius`, `Motion`)
///   over raw `Palette` values; `Palette` is the WhatsApp palette itself.
/// - Brand colours are fixed, surfaces resolve per appearance through
///   `dynamic(light:dark:)`, so views never branch on `colorScheme`.
/// - Motion goes through `Motion.*` plus `.themeAnimation(value:)` or
///   `Motion.perform(_:reduceMotion:)`, both of which honour Reduce Motion.
/// - Where `DESIGN.md` names a token without giving it a value (`--sand`,
///   `--violet`, `--rose`) the derived value lives here and is marked. Change it
///   in this file, never in a view.
enum AppTheme {

    // MARK: - Palette (exact values from docs/DESIGN.md)

    enum Palette {
        /// WhatsApp dark header / dark section background.
        static let teal = hex(0x075E54)
        /// Hover and pressed states on teal.
        static let tealDeep = hex(0x054C44)
        /// The accent: primary buttons, links, active state, one hero per screen.
        static let green = hex(0x25D366)
        /// Outgoing-bubble green: highlights, tags, chart fills.
        static let greenSoft = hex(0xDCF8C6)
        /// Green text on light backgrounds (better contrast than `green`).
        static let greenInk = hex(0x128C7E)
        /// WhatsApp's text black: headings and body.
        static let ink = hex(0x0B141A)
        /// Secondary text.
        static let inkSoft = hex(0x54656F)
        /// Hairlines (WhatsApp's divider grey).
        static let line = hex(0xE9EDEF)
        /// Page background, a green-tinted off-white.
        static let paper = hex(0xF7F8F6)
        /// Cards.
        static let surface = hex(0xFFFFFF)
        /// WhatsApp's chat wallpaper beige (conversation backgrounds).
        static let chatBackground = hex(0xEFEAE2)

        // Derived. DESIGN.md names these but gives no hex.
        /// `--sand`: warm neutral for day-divider pills and alternating site
        /// sections. `chatBackground` lifted towards paper so type stays legible.
        static let sand = hex(0xF1ECE3)
        /// Avatar / gradient-ring tints seen in the approved app-home mockup.
        /// Decorative only: white type on these is below body contrast, so pair
        /// them with ink initials or a `Module` gradient instead.
        static let jade = hex(0x3FAE8F)
        static let seafoam = hex(0x54B7A2)
        /// `--violet`: the site's hand-drawn accent and gradient-icon pair.
        /// Kept to the palette family; the app itself stays single-accent green.
        static let violet = hex(0x5B54D6)
        /// `--rose`: second stop of the site's icon gradient.
        static let rose = hex(0xE07A8A)
        /// Second stop of the Wrapped gradient. Kept green: the brand rules allow one
        /// colour family, and a blue stop made Wrapped the only screen off-palette.
        static let fern = hex(0x2E8E7D)
        static let mintInk = hex(0x0B4A2B)
    }

    // MARK: - Accent

    enum Accent {
        /// The accent: active state, chart fills, links, one hero element per screen.
        /// Never put white text on it (1.98:1) — use `primaryFill` for that.
        static let primary = Palette.green
        /// Filled primary buttons and pills. DESIGN.md's approved mockup paints
        /// them teal with white text (7.7:1); `palette.green` alone cannot carry
        /// white text at 13pt.
        static let primaryFill = Palette.teal
        /// Pressed / hovered fill.
        static let pressed = Palette.tealDeep
        /// Text-safe accent on light surfaces. `Palette.greenInk` is 4.14:1 on
        /// white, just under body contrast, so this darkens it for text use.
        static let text = dynamic(light: 0x0F7466, dark: 0x3FD2A0)
        /// Tinted fills: charts, tags, selection washes.
        static let tint = Palette.greenSoft
        /// Content placed on `primaryFill`.
        static let onAccent = Color.white
        /// Content placed on `tint`.
        static let onTint = Palette.ink
        /// The old app's "mine" bubble fill; still the conversation surface colour
        /// until the chat refresh lands.
        static let legacyMine = hex(0x0D755F)
    }

    // MARK: - Surfaces (light and dark)

    enum Surface {
        /// Window / page background.
        static let page = dynamic(light: Palette.paper, dark: 0x0B141A)
        /// Cards, tiles, panels.
        static let card = dynamic(light: Palette.surface, dark: 0x111B21)
        /// Sidebar and toolbar chrome.
        static let bar = dynamic(light: 0xFCFDFC, dark: 0x111B21)
        /// Sidebar body.
        static let sidebar = dynamic(light: 0xFBFCFB, dark: 0x0F1A1F)
        /// Conversation background (WhatsApp wallpaper beige in light).
        static let conversation = dynamic(light: Palette.chatBackground, dark: 0x0B141A)
        /// Text fields, search wells, segmented control wells.
        static let field = dynamic(light: 0xF1F3F1, dark: 0x1F2C34)
        /// Selected list row.
        static let selection = dynamic(light: 0xE8F6EC, dark: 0x15352B)
        /// Hovered list row / control.
        static let hover = dynamic(light: 0xF0F3F1, dark: 0x16232A)
        /// Hairline strokes and dividers.
        static let hairline = dynamic(light: Palette.line, dark: 0x222D34)
        /// Hero card wash: violet at 8% over the card colour (DESIGN.md).
        static let hero = dynamic(light: 0xF6FAF7, dark: 0x101C18)
        /// Soft accent wash for icon squircles and highlights.
        static let accentWash = dynamic(light: Palette.greenSoft, dark: 0x12352A)

        /// Primary text.
        static let textPrimary = dynamic(light: Palette.ink, dark: 0xE9EDEF)
        /// Secondary text: previews, times, captions.
        static let textSecondary = dynamic(light: Palette.inkSoft, dark: 0x8696A0)
        /// Faint text: counts, placeholders, disabled. Darkened from #667781 (3.76:1 on a
        /// card, 4.0:1 on the page) and #93A2AA (2.6:1 on white in light mode) to the
        /// first pair that clears 4.5:1 everywhere it is drawn: 5.7:1 on a card and
        /// 6.1:1 on the page in dark, 5.1:1 on white and 4.6:1 on a field in light.
        static let textTertiary = dynamic(light: 0x607178, dark: 0x8696A0)
    }

    // MARK: - Feedback (status, empty and error surfaces)

    enum Feedback {
        static let warning = dynamic(light: 0xA36200, dark: 0xF5B45A)
        static let error = dynamic(light: 0xB3261E, dark: 0xF27D72)
        static let success = dynamic(light: 0x0F7466, dark: 0x3FD2A0)
        /// Background for a warning banner.
        static let warningWash = dynamic(light: 0xFFF4E0, dark: 0x2E2413)
        static let errorWash = dynamic(light: 0xFDECEA, dark: 0x2E1715)
    }

    // MARK: - "Local only" badge (mint)

    enum Badge {
        /// Mint pill in the titlebar / sidebar: nothing leaves the Mac.
        static let localOnlyFill = dynamic(light: Palette.greenSoft, dark: 0x0F3B2E)
        static let localOnlyText = dynamic(light: Palette.mintInk, dark: 0xA7F3C9)
        static let localOnlyBorder = dynamic(light: 0xC3EFAE, dark: 0x17513E)
    }

    // MARK: - Conversation bubbles

    enum Bubble {
        /// Outgoing. The approved app-home mockup paints these `--green-soft`
        /// with ink text (WhatsApp-faithful, one accent). DESIGN.md's App bullet
        /// says `--violet` at 100%, but `--violet` has no value in the token
        /// block and the brand rules allow a single accent — flipping this one
        /// line is the whole change if the owner prefers the violet reading.
        /// Outgoing in light mode stays WhatsApp's bubble green; in dark it takes
        /// WhatsApp's own outgoing teal (`#005C4B`), because a pale green bubble on a
        /// near-black wall glares instead of receding.
        static let mine = dynamic(light: Palette.greenSoft, dark: 0x005C4B)
        static let onMine = dynamic(light: Palette.ink, dark: 0xE9EDEF)
        /// Incoming: card surface with a hairline (DESIGN.md).
        static let theirs = dynamic(light: Palette.surface, dark: 0x202C33)
        static let onTheirs = dynamic(light: Palette.ink, dark: 0xE9EDEF)
        static let border = dynamic(light: Palette.line, dark: 0x222D34)
        /// Day-divider pills on `--sand`.
        static let dayDivider = dynamic(light: Palette.sand, dark: 0x182229)
        static let dayDividerText = dynamic(light: Palette.inkSoft, dark: 0x8696A0)
        /// Ring on the message a search result jumped to.
        static let highlight = dynamic(light: 0xC9A227, dark: 0xF2C94C)
        /// How much of `onMine` the outgoing timestamp carries. 62% measured 3.61:1 on the
        /// dark bubble; 78% measures 4.8:1 there and 8.6:1 on the light bubble green.
        static let metaOnMine: Double = 0.78
        /// Bubble text measures short of the pane so long messages stay readable.
        static let maxWidth: CGFloat = 560

        // MARK: Reaction chips
        // WhatsApp draws them as their own little pill on the bubble's bottom edge, never as
        // part of the bubble fill: a white chip is a separate surface on both the green
        // outgoing bubble and the card-coloured incoming one.

        static let reactionChip = dynamic(light: Palette.surface, dark: 0x1F2C34)
        /// Hover: the chip lifts off the bubble the way every other hoverable surface does.
        static let reactionChipHover = dynamic(light: 0xFFFFFF, dark: 0x2A3942)
        static let reactionChipBorder = dynamic(light: 0xD5DDD6, dark: 0x2F3D45)
    }

    // MARK: - Modules (Home tiles, sidebar sections, Wrapped)

    /// One module's identity: title, SF Symbol and its gradient.
    struct ModuleAppearance: Sendable, Identifiable {
        let id: String
        let title: String
        let symbol: String
        /// Two or more stops, always used left-to-right on icon squircles.
        let colors: [Color]
        var gradient: LinearGradient {
            LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        /// Flat colour for charts, rules and tinted panels.
        var tint: Color { colors[colors.count / 2] }
    }

    enum Module {
        // Stops are chosen so a white SF Symbol stays readable on every point of
        // the gradient (≥ 4:1 at the lightest stop): chat-list avatars, Home tile
        // icons and sidebar marks all sit on these.
        static let chats = ModuleAppearance(
            id: "chats", title: "Chats",
            symbol: "bubble.left.and.bubble.right.fill",
            colors: [Palette.greenInk, Palette.teal])
        static let people = ModuleAppearance(
            id: "people", title: "People",
            symbol: "person.2.fill",
            colors: [hex(0x2B7F68), Palette.tealDeep])
        static let wrapped = ModuleAppearance(
            id: "wrapped", title: "Wrapped",
            symbol: "gift.fill",
            colors: [Palette.greenInk, Palette.fern])
        static let music = ModuleAppearance(
            id: "music", title: "Music & video",
            symbol: "music.note.tv",
            colors: [hex(0x2E8E7D), Palette.tealDeep])

        /// Home tile order.
        static let all: [ModuleAppearance] = [chats, people, wrapped, music]

        /// Thin gradient rule under the sidebar header (DESIGN.md).
        static var sidebarRule: LinearGradient {
            LinearGradient(colors: [Palette.green.opacity(0), Palette.greenInk, Palette.teal.opacity(0)],
                           startPoint: .leading, endPoint: .trailing)
        }
    }

    // MARK: - Radii and squircles

    enum Radius {
        /// Cards and Home tiles (DESIGN.md: 20px cards).
        static let card: CGFloat = 20
        /// Hero card.
        static let hero: CGFloat = 16
        /// Inner panels, wrapped tiles.
        static let panel: CGFloat = 16
        /// Inputs and fields (DESIGN.md: 14px inputs).
        static let input: CGFloat = 14
        /// Message bubbles (DESIGN.md App section: 18px).
        static let bubble: CGFloat = 18
        /// Small controls, search wells, thumbs.
        static let control: CGFloat = 8
        /// Gradient squircle icons inside tiles.
        static let icon: CGFloat = 12
        /// Pills and badges resolve to a capsule (DESIGN.md: 999px).
        static var pill: CGFloat { 999 }

        /// Continuous ("squircle") rectangle for any radius.
        static func squircle(_ radius: CGFloat = Radius.card) -> RoundedRectangle {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
        }

        static var cardShape: RoundedRectangle { squircle(card) }
        static var tileShape: RoundedRectangle { squircle(card) }
        static var heroShape: RoundedRectangle { squircle(hero) }
        static var bubbleShape: RoundedRectangle { squircle(bubble) }
        /// Inner panels and nested tiles.
        static var panelShape: RoundedRectangle { squircle(panel) }
        static var inputShape: RoundedRectangle { squircle(input) }
        static var controlShape: RoundedRectangle { squircle(control) }
        static var iconShape: RoundedRectangle { squircle(icon) }
    }

    // MARK: - Typography (system stack only — no external fonts)

    enum Typography {
        /// Page headline ("Good evening", "Your archive").
        static let display = Font.system(size: 34, weight: .bold)
        /// Detail-view title.
        static let title = Font.system(size: 25, weight: .bold)
        /// Card / panel heading.
        static let section = Font.system(size: 15, weight: .semibold)
        /// Chat-list row name (DESIGN.md: 15px/600).
        static let rowName = Font.system(size: 15, weight: .semibold)
        /// Chat-list preview (DESIGN.md: 13px).
        static let rowPreview = Font.system(size: 13)
        /// Row time and count (DESIGN.md: right-aligned in ink-soft).
        static let rowMeta = Font.system(size: 11)
        /// Default text.
        static let body = Font.system(size: 13)
        /// Supporting copy, toolbar labels.
        static let callout = Font.system(size: 12)
        /// Captions and hints.
        static let caption = Font.system(size: 11)
        /// Tightest label: counts in pills, media badges.
        static let micro = Font.system(size: 10)
        /// Big number in a Home tile or KPI.
        static let number = Font.system(size: 23, weight: .semibold).monospacedDigit()
        /// The archive's own number, set at the size a poster would use it.
        static let heroNumber = Font.system(size: 64, weight: .semibold).monospacedDigit()
        static let heroTracking: CGFloat = -2.0
        /// The archive's number at poster size (chrome port: 88/650, tracking −3.5).
        static let display88 = Font.system(size: 88, weight: .semibold).monospacedDigit()
        static let display88Tracking: CGFloat = -3.5
        /// The year's number inside Wrapped (chrome port: 112/700, tracking −5).
        static let display112 = Font.system(size: 112, weight: .bold).monospacedDigit()
        static let display112Tracking: CGFloat = -5
        /// Message bubble text.
        static let bubble = Font.system(size: 13)
        /// Message bubble meta (DESIGN.md: 12px meta).
        static let bubbleMeta = Font.system(size: 12)
        /// Display tracking used with `display`/`title` (-0.02em).
        static let displayTracking: CGFloat = -0.2

        /// Eyebrow label: 12px, uppercase, 0.12em tracking, secondary ink.
        static func eyebrow(_ text: String) -> some View {
            Text(text).font(Font.system(size: 12, weight: .semibold))
                .textCase(.uppercase).tracking(12 * 0.12)
        }
    }

    // MARK: - Spacing

    enum Spacing {
        static let hair: CGFloat = 2
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 6
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 24
        static let xxxl: CGFloat = 32
        /// Screen padding inside a detail pane (DESIGN.md: 24 for cards).
        static let gutter: CGFloat = 24
        /// Gap between Home cards/tiles.
        static let gap: CGFloat = 12
        /// Vertical padding inside a chat-list row.
        static let row: CGFloat = 6
        /// Horizontal padding inside a card.
        static let cardPadding: CGFloat = 16
        /// Hover lift (DESIGN.md: hover lifts 2px).
        static let lift: CGFloat = 2
    }

    // MARK: - Elevation

    struct Shadow: Sendable {
        let color: Color
        let radius: CGFloat
        let y: CGFloat
    }

    enum Elevation {
        static let card = Shadow(color: Palette.ink.opacity(0.05), radius: 2, y: 1)
        static let floating = Shadow(color: Palette.ink.opacity(0.18), radius: 18, y: 8)
    }

    // MARK: - Motion (180–240ms springs, Reduce Motion aware)

    enum Motion {
        /// Hover / press feedback: fast and barely bouncy.
        static let quick = Animation.spring(response: 0.18, dampingFraction: 0.92)
        /// Default for row selection, badges appearing, layout changes.
        static let standard = Animation.spring(response: 0.22, dampingFraction: 0.86)
        /// Opening a pane, sheet or inspector.
        static let open = Animation.spring(response: 0.28, dampingFraction: 0.82)
        /// Long, soft move: jump-to-message, hero card changes.
        static let gentle = Animation.spring(response: 0.36, dampingFraction: 0.88)

        /// What replaces a spring when Reduce Motion is on: a short cross-fade
        /// (DESIGN.md, App › Motion: "honour Reduce Motion").
        static let crossfade = Animation.easeInOut(duration: 0.16)

        /// QA aid: `SagaApp --reduce-motion <flags>` treats Reduce Motion as on,
        /// so a snapshot or a review can check the reduced path without changing
        /// the person's system settings. System Settings always wins in normal use.
        static let reduceMotionOverride = ProcessInfo.processInfo.arguments.contains("--reduce-motion")

        /// True when motion should stay switched off.
        static func isReduced(_ systemReduceMotion: Bool) -> Bool {
            systemReduceMotion || reduceMotionOverride
        }

        /// `nil` when Reduce Motion is on, so callers can pass the result
        /// straight to `withAnimation` / `.animation(_:value:)`.
        static func animation(_ animation: Animation = standard, reduceMotion: Bool) -> Animation? {
            isReduced(reduceMotion) ? nil : animation
        }

        /// Run a state change with (or without) an animation.
        @MainActor
        static func perform(_ animation: Animation = standard, reduceMotion: Bool, _ body: () -> Void) {
            withAnimation(isReduced(reduceMotion) ? nil : animation, body)
        }
    }

    /// Applies an animation to `value` changes unless Reduce Motion is on.
    fileprivate struct MotionModifier<V: Equatable>: ViewModifier {
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        let animation: Animation
        let value: V
        func body(content: Content) -> some View {
            content.animation(Motion.isReduced(reduceMotion) ? nil : animation, value: value)
        }
    }

    /// Same, but a cross-fade substitutes the spring under Reduce Motion instead
    /// of no animation at all. Use it where the change must still read as a change
    /// (a state swapping in), never for movement.
    fileprivate struct CrossfadeModifier<V: Equatable>: ViewModifier {
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        let animation: Animation
        let value: V
        func body(content: Content) -> some View {
            content.animation(Motion.isReduced(reduceMotion) ? Motion.crossfade : animation, value: value)
        }
    }

    // MARK: - Helpers

    /// A colour that resolves differently in light and dark appearance.
    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(srgb: isDark ? dark : light)
        })
    }

    /// Same, for a light value that already comes from `Palette`.
    static func dynamic(light: Color, dark: UInt32) -> Color {
        let lightColor = NSColor(light)
        return Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark ? NSColor(srgb: dark) : lightColor
        })
    }

    private static func hex(_ value: UInt32) -> Color {
        Color(.sRGB,
              red: Double((value >> 16) & 0xFF) / 255,
              green: Double((value >> 8) & 0xFF) / 255,
              blue: Double(value & 0xFF) / 255,
              opacity: 1)
    }
}

extension View {
    /// Spring animation that automatically disables itself under Reduce Motion.
    func themeAnimation<V: Equatable>(_ animation: Animation = AppTheme.Motion.standard, value: V) -> some View {
        modifier(AppTheme.MotionModifier(animation: animation, value: value))
    }

    /// Spring animation that becomes a short cross-fade under Reduce Motion, for
    /// changes that should still register as a change (an empty state appearing)
    /// rather than movement across the screen.
    func themeCrossfadeAnimation<V: Equatable>(_ animation: Animation = AppTheme.Motion.standard, value: V) -> some View {
        modifier(AppTheme.CrossfadeModifier(animation: animation, value: value))
    }

    /// Theme elevation (card or floating).
    func themeShadow(_ shadow: AppTheme.Shadow) -> some View {
        self.shadow(color: shadow.color, radius: shadow.radius, y: shadow.y)
    }
}

private extension NSColor {
    convenience init(srgb value: UInt32) {
        self.init(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                  green: CGFloat((value >> 8) & 0xFF) / 255,
                  blue: CGFloat(value & 0xFF) / 255,
                  alpha: 1)
    }
}


extension AppTheme {
    /// The field a screen sits on: one light source, never a pattern.
    enum Field {
        static let baseTop = dynamic(light: 0xF7F8F6, dark: 0x0D1A1F)
        static let baseBottom = dynamic(light: 0xEFF2EF, dark: 0x091013)
        /// Teal light behind the content, upper left.
        static let glow = Color(red: 0x07/255, green: 0x5E/255, blue: 0x54/255)
        static let glowTrailing = Color(red: 0x12/255, green: 0x8C/255, blue: 0x7E/255)
        static let glowStrengthDark: Double = 0.62
        static let glowStrengthLight: Double = 0.10
        static let warmGlowLight = Color(red: 0xDC/255, green: 0xF8/255, blue: 0xC6/255)
    }

    /// Glass: translucent fill, hairline, and a top inner highlight so panels read as
    /// material rather than as grey rectangles. One level deep only.
    enum Glass {
        static let fill = dynamic(light: 0xFFFFFF, dark: 0x111B21)
        static let fillOpacity: Double = 0.66
        static let darkFillOpacity: Double = 0.58
        static let hairlineLight: Double = 0.07
        static let hairlineDark: Double = 0.075
        static let highlightLight: Double = 0.95
        static let highlightDark: Double = 0.055
    }
}
