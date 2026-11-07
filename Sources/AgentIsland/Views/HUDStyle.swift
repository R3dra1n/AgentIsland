import SwiftUI

/// Look and motion of the floating HUD: a black "morphing capsule" in the style
/// of the Dynamic Island / Live Activities. Every number lives here so the views
/// and the tests agree on them. Nothing in this file decides *what* is shown;
/// see `docs/hud-session-rows.md` for that.
enum HUDStyle {
    // MARK: Geometry (points)

    static let closedSize = CGSize(width: 112, height: 28)
    static let closedCornerRadius: CGFloat = 14
    static let openWidth: CGFloat = 440
    static let openCornerRadius: CGFloat = 24

    static let rowHeight: CGFloat = 52
    static let rowCornerRadius: CGFloat = 15
    static let rowSpacing: CGFloat = 4
    static let rowHorizontalPadding: CGFloat = 12
    static let containerPadding: CGFloat = 9

    static let dotSize: CGFloat = 10
    static let dotSpacing: CGFloat = 10
    static let rowContentSpacing: CGFloat = 12

    /// Transparent margin kept around the capsule inside its window so the
    /// shadow (0 10 34) is not clipped.
    static let windowMargin = EdgeInsets(top: 4, leading: 40, bottom: 56, trailing: 40)

    /// Height of the open capsule: rows x 56 + 14 (52 + 4 per row, 9 + 9 padding
    /// minus the one gap that does not exist).
    static func openHeight(rows: Int) -> CGFloat {
        let n = CGFloat(max(1, rows))
        return n * (rowHeight + rowSpacing) + 2 * containerPadding - rowSpacing
    }

    /// The closed capsule is 112 wide; with many assistants it widens just enough
    /// to keep every dot inside it.
    static let iconSize: CGFloat = 16
    static let iconSpacing: CGFloat = 14

    /// Length of the closed capsule along its dot axis: the 112 pt minimum, or
    /// as long as the dots need.
    static func closedLength(dots: Int, icons: Bool = false) -> CGFloat {
        let n = CGFloat(max(0, dots))
        let size = icons ? iconSize : dotSize, spacing = icons ? iconSpacing : dotSpacing
        let needed = n * size + max(0, n - 1) * spacing + 2 * 8
        return max(closedSize.width, needed)
    }

    static func closedWidth(dots: Int, icons: Bool = false) -> CGFloat {
        closedLength(dots: dots, icons: icons)
    }

    /// The closed capsule: wide and short with dots in a row, or (the "直列"
    /// layout) a narrow pill with the dots stacked top to bottom.
    static func closedCapsule(dots: Int, icons: Bool = false, vertical: Bool = false) -> CGSize {
        let length = closedLength(dots: dots, icons: icons)
        return vertical ? CGSize(width: closedSize.height, height: length) : CGSize(width: length, height: closedSize.height)
    }

    static func capsuleSize(isOpen: Bool, rows: Int, dots: Int, icons: Bool = false, vertical: Bool = false, maxOpenHeight: CGFloat = .greatestFiniteMagnitude) -> CGSize {
        if isOpen {
            return CGSize(width: openWidth, height: min(openHeight(rows: rows), max(closedSize.height, maxOpenHeight)))
        }
        return closedCapsule(dots: dots, icons: icons, vertical: vertical)
    }

    // MARK: Edge glow

    /// The rim light, if the setting is on: red when something needs the user
    /// (it breathes), yellow while running, green when finished, a faint white
    /// rim when everything is idle.
    static func glowHex(for state: AIState) -> UInt32? {
        switch state {
        case .awaitingInput, .running, .completed: return lightHex(for: state)
        default: return nil
        }
    }
    static let glowIdleOpacity: Double = 0.14
    static func glowOpacity(for state: AIState, phase: Double) -> Double {
        switch state {
        case .awaitingInput: return 0.95 - 0.5 * phase
        case .running: return 0.65
        case .completed: return 0.75
        default: return glowIdleOpacity
        }
    }
    static func glowShadowOpacity(for state: AIState, phase: Double) -> Double {
        state == .awaitingInput ? 0.6 - 0.4 * phase : 0
    }

    /// Size of the whole window content for a capsule of `capsule`.
    static func windowSize(for capsule: CGSize) -> CGSize {
        CGSize(width: capsule.width + windowMargin.leading + windowMargin.trailing,
               height: capsule.height + windowMargin.top + windowMargin.bottom)
    }

    // MARK: Motion

    /// Time the window waits before it shrinks, so the spring has settled.
    static let morphDuration: Double = 0.55
    /// A critically-damped-ish spring, as the system Dynamic Island uses, not a
    /// fixed-time curve: it can be interrupted by a second tap or a new row and
    /// carries its velocity over instead of restarting, which is what made the
    /// old curve feel stiff. One shape animates width, height and corner radius.
    static let morph = Animation.spring(response: 0.42, dampingFraction: 0.84)
    /// How long the window gets to grow before the capsule starts to, so the
    /// first frames of the morph are not drawn while the window is resizing.
    static let windowGrowLead: Double = 0.04
    /// Closed dots fade out (and back in) in 0.2 s.
    static let dotsFade = Animation.timingCurve(0.25, 0.1, 0.25, 1, duration: 0.2)
    /// Rows fade in over 0.3 s after a 0.2 s delay, so the capsule grows first;
    /// they fade out at once when it closes.
    static func rowsFade(opening: Bool) -> Animation {
        // Closing is quick so no half-faded row is left behind, clipped, while
        // the capsule is still narrowing; opening waits for the capsule to lead.
        let curve = Animation.timingCurve(0.25, 0.1, 0.25, 1, duration: opening ? 0.28 : 0.1)
        return opening ? curve.delay(0.12) : curve
    }
    /// One full breath (dim and back) takes 2.8 s: 1.4 s each way, as specified.
    static let pulsePeriod: Double = 2.8
    /// 0 (full) ... 1 (fully dimmed), an ease-in-out wave of time. Computed from
    /// the clock rather than driven by an animation, so a layout or state change
    /// elsewhere in the HUD cannot cancel it and leave a running light static.
    static func pulsePhase(at time: TimeInterval) -> Double {
        0.5 - 0.5 * cos(2 * Double.pi * time / pulsePeriod)
    }
    static let pulseOpacity: Double = 0.45
    static let pulseScale: CGFloat = 0.8

    // MARK: Colour

    static func color(hex: UInt32, opacity: Double = 1) -> Color {
        Color(.sRGB,
              red: Double((hex >> 16) & 0xFF) / 255,
              green: Double((hex >> 8) & 0xFF) / 255,
              blue: Double(hex & 0xFF) / 255,
              opacity: opacity)
    }

    static let redHex: UInt32 = 0xFF5C5C      // needs you
    static let yellowHex: UInt32 = 0xFFC24B   // running
    static let greenHex: UInt32 = 0x3DDC84    // done, not yet viewed
    static let greyHex: UInt32 = 0x4A5164     // idle / viewed
    // The four lights above are the whole palette of the design. A failed or an
    // interrupted run still needs a light of its own, so these two are additions.
    static let failedHex: UInt32 = 0xFF9F5A
    static let interruptedHex: UInt32 = 0x8A93A6

    static let nameColor = color(hex: 0xE8EBF1)
    static let secondaryColor = color(hex: 0xAAB2C3)
    static let rowFill = Color.white.opacity(0.05)
    static let rowFillNeedsAction = color(hex: redHex, opacity: 0.16)
    static let primaryButtonFill = Color.white
    static let primaryButtonText = Color.black
    static let secondaryButtonFill = Color.white.opacity(0.14)
    static let secondaryButtonText = nameColor

    static func lightHex(for state: AIState) -> UInt32 {
        switch state {
        case .awaitingInput: return redHex
        case .running: return yellowHex
        case .completed: return greenHex
        case .failed: return failedHex
        case .interrupted: return interruptedHex
        case .idle, .unknown: return greyHex
        }
    }

    static func light(for state: AIState) -> Color { color(hex: lightHex(for: state)) }

    static func rowFill(for state: AIState) -> Color { state == .awaitingInput ? rowFillNeedsAction : rowFill }

    // MARK: When the capsule opens by itself

    /// Opens on its own only for something that needs the user (red) or is
    /// finished and not yet viewed (green). A run in progress, a failure or a
    /// stand-by assistant stays as dots until the user taps the capsule.
    /// What currently asks to open the capsule: one key per red or unviewed
    /// green row (row id and state), so a *new* one can be told from one the
    /// user has already collapsed on.
    static func attentionKeys(_ items: [AIObserverItem]) -> Set<String> {
        Set(items.filter { $0.state == .awaitingInput || $0.state == .completed }.map { "\($0.id)|\($0.state)" })
    }

    static func opensAutomatically(_ states: [AIState]) -> Bool {
        states.contains { $0 == .awaitingInput || $0 == .completed }
    }
}
