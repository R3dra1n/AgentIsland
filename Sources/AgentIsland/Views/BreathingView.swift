import SwiftUI
import AppKit
import QuartzCore

/// Breathes its content (fades and shrinks it, then back, forever) with Core
/// Animation.
///
/// The lights used to breathe from a `TimelineView`. While one was running,
/// SwiftUI laid out and rendered the whole capsule on every screen refresh,
/// whatever interval the timeline asked for: measured on a real day's data that
/// was about 12% of a core for as long as any assistant was working, three
/// quarters of everything this app used. A layer animation is played by the
/// window server; the app does nothing per frame.
///
/// The content is drawn once, in its own small hosting view, and only that
/// view's layer is animated. Clicks pass straight through to whatever is
/// underneath, so a light inside a button still presses the button.
struct BreathingView<Content: View>: NSViewRepresentable {
    /// Breathe, or hold still at full strength.
    var active: Bool
    /// Opacity at the bottom of a breath, as a fraction of the resting opacity.
    var lowOpacity: Double = HUDStyle.pulseOpacity
    /// Scale at the bottom of a breath.
    var lowScale: CGFloat = HUDStyle.pulseScale
    /// Take all the room offered (a rim around something) instead of the
    /// content's own size (a light). A shape has no size of its own.
    var fills: Bool = false
    @ViewBuilder var content: Content

    func makeNSView(context: Context) -> BreathingHost<Content> { BreathingHost(rootView: content) }

    func updateNSView(_ view: BreathingHost<Content>, context: Context) {
        view.hosting.rootView = content
        view.breath = active ? .init(lowOpacity: lowOpacity, lowScale: lowScale) : nil
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: BreathingHost<Content>, context: Context) -> CGSize? {
        fills ? proposal.replacingUnspecifiedDimensions() : nsView.hosting.fittingSize
    }
}

struct Breath: Equatable {
    var lowOpacity: Double
    var lowScale: CGFloat
}

final class BreathingHost<Content: View>: NSView {
    static var animationKey: String { "AgentIsland.breath" }

    let hosting: NSHostingView<Content>
    var breath: Breath? { didSet { if breath != oldValue { apply() } } }
    private var animatedSize: CGSize = .zero

    init(rootView: Content) {
        hosting = NSHostingView(rootView: rootView)
        super.init(frame: .zero)
        wantsLayer = true
        hosting.wantsLayer = true
        addSubview(hosting)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: NSSize { hosting.fittingSize }

    // Never the target of a click: the SwiftUI view around this one handles it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        hosting.frame = bounds
        // The scale is about the centre, so it depends on the size.
        if bounds.size != animatedSize { apply() }
    }

    // A layer's animations are dropped when it leaves the window.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        apply()
    }

    private func apply() {
        guard let layer = hosting.layer else { return }
        layer.removeAnimation(forKey: Self.animationKey)
        animatedSize = bounds.size
        guard let breath, window != nil, let animation = Self.animation(for: breath, size: bounds.size, now: CACurrentMediaTime()) else { return }
        layer.add(animation, forKey: Self.animationKey)
    }

    /// One breath out and back in `HUDStyle.pulsePeriod`, the same curve the
    /// lights have always followed (`HUDStyle.pulsePhase`). Every light takes
    /// its phase from the clock, so they all breathe together.
    static func animation(for breath: Breath, size: CGSize, now: CFTimeInterval) -> CAAnimationGroup? {
        guard size.width > 0, size.height > 0 else { return nil }
        let half = HUDStyle.pulsePeriod / 2

        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = 1.0
        opacity.toValue = breath.lowOpacity

        // An AppKit layer is anchored at its corner; shrink about the centre.
        let centre = CGPoint(x: size.width / 2, y: size.height / 2)
        var shrunk = CATransform3DMakeTranslation(centre.x, centre.y, 0)
        shrunk = CATransform3DScale(shrunk, breath.lowScale, breath.lowScale, 1)
        shrunk = CATransform3DTranslate(shrunk, -centre.x, -centre.y, 0)
        let scale = CABasicAnimation(keyPath: "transform")
        scale.fromValue = NSValue(caTransform3D: CATransform3DIdentity)
        scale.toValue = NSValue(caTransform3D: shrunk)

        let group = CAAnimationGroup()
        group.animations = breath.lowScale == 1 ? [opacity] : [opacity, scale]
        group.duration = half
        group.autoreverses = true
        group.repeatCount = .infinity
        // The usual bezier for a sine ease, which is what `pulsePhase` is.
        group.timingFunction = CAMediaTimingFunction(controlPoints: 0.37, 0, 0.63, 1)
        // Started at the last whole period of the clock, so that separate
        // lights (and ones that appear later) are in step.
        group.beginTime = now - now.truncatingRemainder(dividingBy: HUDStyle.pulsePeriod)
        group.isRemovedOnCompletion = false
        return group
    }
}
