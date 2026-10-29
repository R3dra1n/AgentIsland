import AppKit
import SwiftUI
import Combine

@MainActor
public final class StatusItemPopoverController: NSObject {
    public static let shared = StatusItemPopoverController()

    private var statusItem: NSStatusItem?
    private var panel: NSPanel?
    private var appState: AppState?
    private var cancellables = Set<AnyCancellable>()
    private var outsideClickMonitor: Any?
    private var localClickMonitor: Any?
    private var keyMonitor: Any?
    private var workspaceMonitor: Any?

    public override init() {
        super.init()
    }

    public func setup(with state: AppState) {
        self.appState = state

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        self.statusItem = item

        // 2. Create custom Borderless NSPanel for the popover
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 358, height: 510),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.isMovableByWindowBackground = false
        panel.acceptsMouseMovedEvents = true

        let popoverView = PopoverContentView(appState: state)
        panel.contentView = NSHostingView(rootView: popoverView)
        self.panel = panel

        // 3. Observe state changes to update status item button image
        let publishers: [AnyPublisher<Void, Never>] = [
            state.$codexState.map { _ in () }.eraseToAnyPublisher(),
            state.$antigravityState.map { _ in () }.eraseToAnyPublisher(),
            state.$claudeState.map { _ in () }.eraseToAnyPublisher(),
            state.$cursorState.map { _ in () }.eraseToAnyPublisher(),
            state.$windsurfState.map { _ in () }.eraseToAnyPublisher(),
            state.$traeState.map { _ in () }.eraseToAnyPublisher(),
            state.$showMenuBarIcon.map { _ in () }.eraseToAnyPublisher(),
            state.$showMenuBarDot.map { _ in () }.eraseToAnyPublisher(),
            state.$showMenuBarText.map { _ in () }.eraseToAnyPublisher(),
            state.$codexEnabled.map { _ in () }.eraseToAnyPublisher(),
            state.$antigravityEnabled.map { _ in () }.eraseToAnyPublisher(),
            state.$claudeEnabled.map { _ in () }.eraseToAnyPublisher(),
            state.$cursorEnabled.map { _ in () }.eraseToAnyPublisher(),
            state.$windsurfEnabled.map { _ in () }.eraseToAnyPublisher(),
            state.$traeEnabled.map { _ in () }.eraseToAnyPublisher(),
            state.$testModeActive.map { _ in () }.eraseToAnyPublisher()
        ]

        Publishers.MergeMany(publishers)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateStatusItemImage()
            }
            .store(in: &cancellables)

        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateStatusItemImage()
            }
        }

        updateStatusItemImage()
    }

    public func updateStatusItemImage() {
        guard let button = statusItem?.button, let state = appState else { return }
        let isDark: Bool = {
            if let match = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) {
                return match == .darkAqua
            }
            if let style = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") {
                return style.caseInsensitiveCompare("Dark") == .orderedSame
            }
            return false
        }()
        let image = MenuBarLabelView.generateMenuBarImage(appState: state, isDark: isDark)
        button.image = image
        button.imagePosition = .imageOnly
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        guard let event = NSApp.currentEvent else {
            togglePopover()
            return
        }
        
        if event.type == .rightMouseUp {
            if panel?.isVisible == true {
                hidePopover()
            }
            let menu = NSMenu()
            menu.addItem(withTitle: "退出 AgentIsland", action: #selector(quitApp), keyEquivalent: "q").target = self
            if let button = statusItem?.button {
                menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 5), in: button)
            }
        } else {
            togglePopover()
        }
    }
    
    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    public func togglePopover() {
        if panel?.isVisible == true {
            hidePopover()
        } else {
            showPopover()
        }
    }

    public func showPopover() {
        guard let panel = panel, statusItem?.button != nil, let state = appState else { return }

        // Refresh view content
        let hostingView = NSHostingView(rootView: PopoverContentView(appState: state))
        panel.contentView = hostingView

        positionPanel()

        panel.alphaValue = 0
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1.0
        }

        installEventMonitors()
    }

    public func hidePopover() {
        guard let panel = panel, panel.isVisible else { return }
        removeEventMonitors()

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.10
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0.0
        }, completionHandler: {
            DispatchQueue.main.async {
                panel.orderOut(nil)
                panel.alphaValue = 1.0
            }
        })
    }

    private func positionPanel() {
        guard let panel = panel, let button = statusItem?.button, let buttonWindow = button.window else { return }

        guard let hostingView = panel.contentView else { return }
        hostingView.layoutSubtreeIfNeeded()
        let contentFittingSize = hostingView.fittingSize

        let panelWidth = contentFittingSize.width > 100 ? contentFittingSize.width : 358
        let panelHeight = contentFittingSize.height > 100 ? contentFittingSize.height : 510
        panel.setContentSize(NSSize(width: panelWidth, height: panelHeight))

        let buttonWindowFrame = buttonWindow.frame
        let buttonFrameOnScreen = buttonWindow.convertToScreen(button.frame)

        // Reliably locate the exact screen containing the status item button
        let buttonCenter = CGPoint(x: buttonFrameOnScreen.midX, y: buttonFrameOnScreen.midY)
        let targetScreen = NSScreen.screens.first(where: { $0.frame.contains(buttonCenter) })
            ?? buttonWindow.screen
            ?? NSScreen.main
            ?? NSScreen.screens.first!
        let screenVisibleFrame = targetScreen.visibleFrame

        var x = buttonFrameOnScreen.midX - panelWidth / 2.0

        // Boundary clamp strictly within targetScreen's visible bounds
        if x + panelWidth > screenVisibleFrame.maxX - 10 {
            x = screenVisibleFrame.maxX - panelWidth - 10
        }
        if x < screenVisibleFrame.minX + 10 {
            x = screenVisibleFrame.minX + 10
        }

        // Snug fit: align right below the menu bar bottom edge with zero excess gap
        let y = buttonWindowFrame.minY - panelHeight + 2
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func installEventMonitors() {
        removeEventMonitors()

        // 1. Dismiss when clicking outside panel
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self = self, let panel = self.panel, panel.isVisible else { return }
            let clickLoc = NSEvent.mouseLocation

            if let button = self.statusItem?.button, let buttonWindow = button.window {
                if buttonWindow.frame.contains(clickLoc) {
                    return // Handled by button action
                }
            }

            if !panel.frame.contains(clickLoc) {
                self.hidePopover()
            }
        }

        // 2. Local monitor for inside-app clicks outside popover
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self = self, let panel = self.panel, panel.isVisible else { return event }
            let clickLoc = NSEvent.mouseLocation

            if let button = self.statusItem?.button, let buttonWindow = button.window {
                if buttonWindow.frame.contains(clickLoc) {
                    return event
                }
            }

            if !panel.frame.contains(clickLoc) {
                self.hidePopover()
            }
            return event
        }

        // 3. Dismiss on Escape key
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // ESC
                self?.hidePopover()
                return nil
            }
            return event
        }

        // 4. Dismiss when another application is activated
        workspaceMonitor = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.hidePopover()
            }
        }
    }

    private func removeEventMonitors() {
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
        if let monitor = localClickMonitor {
            NSEvent.removeMonitor(monitor)
            localClickMonitor = nil
        }
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
        if let monitor = workspaceMonitor {
            NSWorkspace.shared.notificationCenter.removeObserver(monitor)
            workspaceMonitor = nil
        }
    }
}
