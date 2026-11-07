import AppKit
import SwiftUI
import Combine

@MainActor
public final class FloatingHUDWindowController: NSObject {
    public static let shared = FloatingHUDWindowController()

    public private(set) var panel: NSPanel?
    private var cancellables = Set<AnyCancellable>()
    private var appState: AppState?
    private var isInitialized = false
    private var measuredContentSize: CGSize = .zero
    /// While the capsule shrinks the window keeps its larger size until the morph
    /// has finished, so the animation is not cut off by the window.
    private var heldSize: CGSize?
    private var pendingShrink: DispatchWorkItem?

    public override init() {
        super.init()
    }

    public func setup(with state: AppState) {
        self.appState = state

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 46),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isMovableByWindowBackground = false
        panel.acceptsMouseMovedEvents = true

        let hudView = FloatingHUDView(appState: state) { [weak self] size in
            guard let self, size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
                  abs(self.measuredContentSize.width - size.width) >= 1 || abs(self.measuredContentSize.height - size.height) >= 1 else { return }
            self.measuredContentSize = size
            self.applyContentSize()
        }
        let hostingView = DraggableHostingView(rootView: hudView)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = hostingView

        self.panel = panel

        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self = self, self.isInitialized else { return }
                if NSEvent.pressedMouseButtons != 0 {
                    self.hasCustomUserPosition = true
                }
            }
        }

        updateWindowPosition(animated: false)
        self.isInitialized = true

        // Observe state changes to show/hide and resize dynamically
        state.$aggregatedState
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.syncVisibility() }
            .store(in: &cancellables)

        state.$hudLayoutMode
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateWindowPosition(animated: true) }
            .store(in: &cancellables)
            
        state.$isHUDEnabled
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.syncVisibility() }
            .store(in: &cancellables)
            
        state.$hudDisplayMode
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.syncVisibility() }
            .store(in: &cancellables)

        // Session rows can change while the aggregate state remains unchanged.
        state.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.syncVisibility() }
            .store(in: &cancellables)
        
        syncVisibility()
        startPreviewDemoIfRequested(state)
    }

    #if AGENTISLAND_ISOLATED_PREVIEW
    private var demoTimer: Timer?
    /// Preview builds only, and only with AGENTISLAND_DEMO=1: walks the HUD
    /// through running, done, needs-you and standby so the morph can be watched
    /// (and recorded) without real assistants. Never compiled into a release.
    private func startPreviewDemoIfRequested(_ state: AppState) {
        let env = ProcessInfo.processInfo.environment
        if env["AGENTISLAND_DEMO_POPOVER"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { StatusItemPopoverController.shared.togglePopover() }
        }
        // AGENTISLAND_DEMO=scenes (cycle) or AGENTISLAND_DEMO_SCENE=1|2|3 (hold one):
        // fixed, invented scenes for documentation images. Nothing here reads a
        // real session.
        if let scene = env["AGENTISLAND_DEMO_SCENE"].flatMap(Int.init) {
            Self.applyDemoScene(scene, to: state)
            return
        }
        // AGENTISLAND_DEMO_SEQUENCE="2:3.0,6:4.2,7:3.0": scenes with their own
        // dwell time, looping, for a storyboarded recording.
        if let sequence = env["AGENTISLAND_DEMO_SEQUENCE"] {
            let steps = sequence.split(separator: ",").compactMap { part -> (Int, Double)? in
                let bits = part.split(separator: ":")
                guard bits.count == 2, let scene = Int(bits[0]), let seconds = Double(bits[1]) else { return nil }
                return (scene, seconds)
            }
            guard !steps.isEmpty else { return }
            var index = 0
            func next() {
                let (scene, seconds) = steps[index % steps.count]
                index += 1
                Self.applyDemoScene(scene, to: state)
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { next() }
            }
            next()
            return
        }
        if env["AGENTISLAND_DEMO"] == "scenes" {
            var scene = 0
            demoTimer = Timer.scheduledTimer(withTimeInterval: 3.2, repeats: true) { _ in
                MainActor.assumeIsolated { scene = scene % 4 + 1; Self.applyDemoScene(scene, to: state) }
            }
            demoTimer?.fire()
            return
        }
        guard env["AGENTISLAND_DEMO"] == "1" else { return }
        let steps: [AIState] = [.running, .completed, .awaitingInput, .running, .idle]
        var index = 0
        demoTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            MainActor.assumeIsolated {
                state.triggerMultiTest(state: steps[index % steps.count])
                index += 1
            }
        }
        demoTimer?.fire()
    }

    private static func applyDemoScene(_ scene: Int, to state: AppState) {
        state.testModeActive = true
        state.claudeTier = "Pro"
        state.cursorState = .idle; state.windsurfState = .idle; state.traeState = .idle
        let (codex, agy, claude): (AIState, AIState, AIState)
        switch scene {
        case 1: (codex, agy, claude) = (.idle, .idle, .idle)
        case 2: (codex, agy, claude) = (.running, .idle, .running)
        case 3: (codex, agy, claude) = (.completed, .running, .awaitingInput)
        case 6: (codex, agy, claude) = (.completed, .idle, .running)
        case 7: (codex, agy, claude) = (.idle, .idle, .running)
        default: (codex, agy, claude) = (.idle, .completed, .idle)
        }
        state.codexState = codex; state.antigravityState = agy; state.claudeState = claude
        state.codexNeedsAck = codex == .completed; state.antigravityNeedsAck = agy == .completed; state.claudeNeedsAck = claude == .completed
        state.codexDescription = codex == .completed ? "测试已通过，改动已就绪" : (codex == .running ? "正在运行测试" : "待命中")
        state.antigravityDescription = agy == .completed ? "方案已生成" : (agy == .running ? "正在整理需求" : "待命中")
        state.claudeDescription = claude == .awaitingInput ? "要运行 swift build，是否允许？" : (claude == .running ? "正在阅读代码" : "待命中")
        state.aggregatedState = [codex, agy, claude].max() ?? .idle
        if let dir = ProcessInfo.processInfo.environment["AGENTISLAND_DEMO_MENUBAR_DIR"] {
            for dark in [true, false] { exportMenuBarImage(state, scene: scene, dark: dark, dir: dir) }
        }
    }

    /// The menu bar item as an image (4x, transparent), for documentation.
    private static func exportMenuBarImage(_ state: AppState, scene: Int, dark: Bool, dir: String) {
        let image = MenuBarLabelView.generateMenuBarImage(appState: state, isDark: dark)
        let scale: CGFloat = 4
        let w = Int(image.size.width * scale), h = Int(image.size.height * scale)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/mb_\(scene)_\(dark ? "dark" : "light").png"))
    }
    #else
    private func startPreviewDemoIfRequested(_ state: AppState) {}
    #endif

    public var hasCustomUserPosition = false

    public func updateWindowPosition(animated: Bool = true) {
        // If user is actively dragging or holding the mouse, NEVER interrupt with automatic frame updates!
        if NSEvent.pressedMouseButtons != 0 { return }
        guard let panel = panel, let screen = panel.screen ?? NSScreen.main else { return }

        let screenFrame = screen.frame
        // The view reports the size of the capsule's *target* state plus its
        // shadow margin; the capsule itself animates inside the window. Until the
        // first report, a closed capsule's worth of window.
        var reported = measuredContentSize == .zero
            ? HUDStyle.windowSize(for: HUDStyle.closedSize)
            : measuredContentSize
        if let held = heldSize {
            reported = CGSize(width: max(reported.width, held.width), height: max(reported.height, held.height))
        }
        let windowWidth = min(reported.width, max(100, screen.visibleFrame.width - 20))
        #if AGENTISLAND_ISOLATED_PREVIEW
        let windowHeight = min(reported.height, max(100, screen.visibleFrame.height - 130))
        #else
        let windowHeight = min(reported.height, max(100, screen.visibleFrame.height - 20))
        #endif

        let targetX: CGFloat
        let targetY: CGFloat
        if hasCustomUserPosition {
            // Keep the capsule's centre (not its left edge) fixed, so it does not
            // slide sideways when it widens or narrows.
            targetX = min(max(panel.frame.midX - windowWidth / 2, screen.visibleFrame.minX), screen.visibleFrame.maxX - windowWidth)
            targetY = min(max(panel.frame.origin.y + (panel.frame.height - windowHeight), screen.visibleFrame.minY), screen.visibleFrame.maxY - windowHeight)
        } else {
            targetX = screenFrame.origin.x + (screenFrame.width - windowWidth) / 2.0
            #if AGENTISLAND_ISOLATED_PREVIEW
            targetY = screen.visibleFrame.maxY - windowHeight - 110
            #else
            targetY = screen.visibleFrame.maxY - windowHeight + 4 // Shift up to overlap the 4pt padding
            #endif
        }


        let targetFrame = NSRect(x: targetX, y: targetY, width: windowWidth, height: windowHeight)

        // If frame is already effectively identical, skip setting frame to prevent jitter
        if abs(panel.frame.origin.x - targetFrame.origin.x) < 0.5 &&
           abs(panel.frame.origin.y - targetFrame.origin.y) < 0.5 &&
           abs(panel.frame.width - targetFrame.width) < 0.5 &&
           abs(panel.frame.height - targetFrame.height) < 0.5 {
            return
        }

        // The capsule morphs inside the window (SwiftUI), so the window itself
        // only ever jumps to the size that fits the capsule's target state.
        panel.setFrame(targetFrame, display: true)
    }

    /// Called when the view reports a new target size. Growing takes effect at
    /// once, so the capsule has room to grow into; shrinking waits for the morph.
    private func applyContentSize() {
        pendingShrink?.cancel()
        pendingShrink = nil
        heldSize = nil
        guard let panel = panel else { return }
        let current = panel.frame.size
        let shrinking = measuredContentSize.width < current.width - 1 || measuredContentSize.height < current.height - 1
        if shrinking, panel.isVisible, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            heldSize = current
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.heldSize = nil
                    self.pendingShrink = nil
                    self.updateWindowPosition(animated: false)
                }
            }
            pendingShrink = work
            DispatchQueue.main.asyncAfter(deadline: .now() + HUDStyle.morphDuration + 0.1, execute: work)
        }
        updateWindowPosition(animated: false)
    }

    public func syncVisibility() {
        guard let state = appState, let panel = panel else { return }

        guard state.isHUDEnabled else {
            panel.orderOut(nil)
            return
        }

        let shouldShow: Bool
        switch state.hudDisplayMode {
        case .always:
            shouldShow = true
        case .whenActive:
            let active = state.allObservers.filter { $0.state != .idle }
            shouldShow = !active.isEmpty || state.testModeActive
        case .onlyAwaitingInput:
            let awaiting = state.allObservers.filter { $0.state == .awaitingInput }
            shouldShow = !awaiting.isEmpty || state.testModeActive
        }

        if shouldShow {
            updateWindowPosition(animated: panel.isVisible)
            if !panel.isVisible {
                panel.alphaValue = 0
                panel.orderFrontRegardless()
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.3
                    panel.animator().alphaValue = 1.0
                }
            }
        } else {
            if panel.isVisible {
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.3
                    panel.animator().alphaValue = 0.0
                }, completionHandler: {
                    Task { @MainActor [weak self] in
                        if self?.panel?.alphaValue == 0.0 {
                            self?.panel?.orderOut(nil)
                        }
                    }
                })
            }
        }
    }
}

public final class DraggableHostingView<Content: View>: NSHostingView<Content> {
    private var initialMouseScreenLocation: NSPoint = .zero
    private var initialWindowOrigin: NSPoint = .zero
    private var isDragging = false

    public override var mouseDownCanMoveWindow: Bool {
        return false
    }

    public override func mouseDown(with event: NSEvent) {
        if let screen = NSEvent.mouseLocation as NSPoint? {
            initialMouseScreenLocation = screen
        }
        if let win = self.window {
            initialWindowOrigin = win.frame.origin
        }
        isDragging = false
        super.mouseDown(with: event)
    }

    public override func mouseDragged(with event: NSEvent) {
        let currentScreen = NSEvent.mouseLocation
        let dx = currentScreen.x - initialMouseScreenLocation.x
        let dy = currentScreen.y - initialMouseScreenLocation.y
        if abs(dx) > 3 || abs(dy) > 3 {
            isDragging = true
            if let win = self.window {
                win.setFrameOrigin(NSPoint(x: initialWindowOrigin.x + dx, y: initialWindowOrigin.y + dy))
                FloatingHUDWindowController.shared.hasCustomUserPosition = true
            }
        } else {
            super.mouseDragged(with: event)
        }
    }

    public override func mouseUp(with event: NSEvent) {
        if !isDragging {
            super.mouseUp(with: event)
        }
        isDragging = false
    }
}
