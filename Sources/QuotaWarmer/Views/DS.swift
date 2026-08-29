import AppKit
import SwiftUI

/// Design tokens, drawn from the system palette rather than hand-picked hexes.
///
/// The previous values were a fixed light-mode web palette (Tailwind slate),
/// which is why the panel read as a web page transplanted onto macOS and why
/// it never followed the system appearance. Everything below now resolves
/// through AppKit's semantic colors, so the panel tracks light/dark, Increase
/// Contrast and accent settings the way every native Mac app does — and dark
/// mode works without a second palette to maintain.
enum DS {
    enum C {
        // Surfaces
        /// The bright page surface documents use — white in light, near-black in
        /// dark, and it does not pick up desktop wallpaper tint.
        static let bg          = Color(nsColor: .textBackgroundColor)
        /// The rail sits on the same surface as the content on purpose: giving it
        /// its own tint (plus a divider) split the panel into two glued-together
        /// halves instead of one window.
        static let sidebar     = Color(nsColor: .textBackgroundColor)
        static let surface     = Color(nsColor: .textBackgroundColor)
        static let surfaceHigh = Color(nsColor: .controlColor)   // quiet button fill
        static let track       = Color.primary.opacity(0.12)     // progress track
        static let ink         = Color.primary                   // bar fill

        // Borders
        static let border      = Color(nsColor: .separatorColor)
        static let borderSoft  = Color(nsColor: .separatorColor).opacity(0.6)

        // Text
        static let text        = Color.primary
        static let textSub     = Color.secondary
        static let textMuted   = Color(nsColor: .tertiaryLabelColor)

        // Status — the system traffic-light palette, so the dots and bars match
        // every other status indicator on the machine.
        static let green  = Color(nsColor: .systemGreen)
        static let yellow = Color(nsColor: .systemYellow)
        static let red    = Color(nsColor: .systemRed)
        static let blue   = Color(nsColor: .systemBlue)

        // Usage-bar fills. A healthy window draws in neutral graphite, not
        // green: colour here means "look at this", and a panel where every bar
        // is coloured spends that signal on windows that are perfectly fine.
        // Softened against the system hues, which read as alarm lights at full
        // strength across a bar this wide — most visibly in light mode.
        static let meterNormal   = Color.primary.opacity(0.55)
        static let meterLow      = Color(nsColor: .systemOrange).opacity(0.80)
        static let meterCritical = Color(nsColor: .systemRed).opacity(0.80)

        /// Per-tool brand accent. Kept as-is to preserve product identity.
        static func accent(_ tool: ToolID) -> Color {
            tool == .claude
                ? Color(red: 0.90, green: 0.38, blue: 0.05)   // Anthropic orange
                : Color(red: 0.38, green: 0.24, blue: 0.90)   // OpenAI indigo
        }
    }

    // MARK: - Spacing
    enum Space {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 20
    }

    // MARK: - Radii
    enum R {
        static let sm: CGFloat = 7    // badges / small chips
        static let md: CGFloat = 10   // buttons / inputs
        static let lg: CGFloat = 14   // cards
        static let xl: CGFloat = 18   // outer panel
    }

    // MARK: - Layout
    // The panel is laid out at totalWidth × totalHeight and rendered 1:1.
    // A non-integral panelScale resamples text that was already rasterised at
    // full size, which reads as blurry rather than merely small — so the sizes
    // below are tuned to need no downscaling at all. Keep this at 1.0.
    static let panelScale: CGFloat = 1.0
    // A narrow rail that shares the content's surface reads as a margin holding
    // icons; a wide tinted one reads as a second pane bolted to the first.
    static let sidebarWidth: CGFloat = 34
    static let contentWidth: CGFloat = 320
    static let totalWidth:   CGFloat = sidebarWidth + contentWidth
    // Tall enough to show both providers' windows plus history without
    // scrolling — the panel exists to be read in one glance, and a scroll bar
    // hides exactly the row (a depleted weekly window) worth noticing.
    static let totalHeight: CGFloat = 560

    // MARK: - Typography
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

// MARK: - View modifiers

extension View {
    /// Grouped card in the macOS System Settings idiom: a quiet system fill and
    /// no border. Outlining every card was the web habit that made the panel
    /// look boxed-in; the fill alone carries the grouping, and it follows the
    /// system appearance for free.
    func dsCard(radius: CGFloat = DS.R.lg) -> some View {
        self.background {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(.quaternary)
        }
    }

    /// Uppercase, letter-spaced section label (e.g. "WINDOW STATUS").
    func dsSectionLabel() -> some View {
        self.font(.system(size: 11, weight: .semibold))
            .foregroundStyle(DS.C.textMuted)
            .tracking(0.6)
            .textCase(.uppercase)
    }
}
