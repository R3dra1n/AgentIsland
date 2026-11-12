import XCTest
import SwiftUI
import AppKit
@testable import AgentIsland

/// Real mouse events into the real `FloatingHUDView`, hosted in a window.
///
/// The island has two kinds of click: a row's logo opens that conversation, and
/// everywhere else opens or closes the capsule. Making the name and state open
/// the conversation too (1.3.9) took the click away from the capsule, so the
/// user could no longer find a place to click to close it.
@MainActor
final class HUDLogoClickTests: XCTestCase {
    private final class Recorder {
        var focused: [String] = []
        var sizes: [CGSize] = []
    }

    private static let windowSize = CGSize(width: 520, height: 300)

    private func pump(_ seconds: TimeInterval) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }

    private func click(_ window: NSWindow, x: CGFloat, top y: CGFloat) async {
        let point = NSPoint(x: x, y: Self.windowSize.height - y)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                           pressure: type == .leftMouseDown ? 1 : 0)!
            window.sendEvent(event)
            await pump(0.05)
        }
    }

    private func scenario(icons: Bool) async {
        _ = NSApplication.shared
        let state = AppState()
        // Claude is off until the user turns it on, and its rows are only shown
        // while it is on. This used to rely on whatever an earlier run had left
        // in the test runner's preferences. Put back what was there afterwards.
        let hadClaudeEnabled = UserDefaults.standard.object(forKey: "claudeEnabled")
        defer {
            if let hadClaudeEnabled { UserDefaults.standard.set(hadClaudeEnabled, forKey: "claudeEnabled") }
            else { UserDefaults.standard.removeObject(forKey: "claudeEnabled") }
        }
        state.claudeEnabled = true
        // The app's own observers read the real home directory; only what this
        // test sets may be shown.
        [state.codexObserver as any AIObserverProtocol, state.antigravityObserver, state.claudeObserver,
         state.cursorObserver, state.windsurfObserver, state.traeObserver].forEach { $0.stopObserving() }
        state.hudDisplayMode = .whenActive
        state.hudShowsIcons = icons
        // Two conversations: two rows, each with its own logo.
        state.claudeSessions = ["first", "second"].map {
            ClaudeSessionSnapshot(id: $0, state: .running, description: "执行中", actionDetail: nil,
                                  lastActiveDate: Date(), entrypoint: "claude-desktop")
        }
        state.claudeState = .running

        let recorder = Recorder()
        let hud = FloatingHUDView(appState: state, onContentSizeChange: { recorder.sizes.append($0) },
                                  onFocusRow: { recorder.focused.append($0.id) })
        // The same kind of window and hosting view as the real island
        // (`FloatingHUDWindowController.setup`): a panel that does not activate
        // the app takes clicks while another app is in front. An ordinary
        // window swallows the first click to become key, so this test only
        // passed when the test runner happened to be the front app.
        let host = DraggableHostingView(rootView: hud)
        let window = NSPanel(contentRect: NSRect(origin: .zero, size: Self.windowSize), styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        window.isFloatingPanel = true
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: Self.windowSize)
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        await pump(0.4)

        // Where things are, from the same numbers the view lays out with.
        let capsuleCentre = Self.windowSize.width / 2
        let firstRowCentre = HUDStyle.windowMargin.top + HUDStyle.containerPadding + HUDStyle.rowHeight / 2
        let secondRowCentre = firstRowCentre + HUDStyle.rowHeight + HUDStyle.rowSpacing
        let lightWidth = icons ? HUDStyle.iconSize : HUDStyle.dotSize
        let lightLeft = HUDStyle.windowMargin.leading + HUDStyle.containerPadding + HUDStyle.rowHorizontalPadding
        let lightCentre = lightLeft + lightWidth / 2
        let textX = lightLeft + lightWidth + HUDStyle.rowContentSpacing + 40

        guard let closedHeight = recorder.sizes.last?.height else { return XCTFail("no size reported") }

        // Closed: a click opens it.
        await click(window, x: capsuleCentre, top: HUDStyle.windowMargin.top + HUDStyle.closedSize.height / 2)
        await pump(1.0)
        guard let openHeight = recorder.sizes.last?.height else { return XCTFail("no size reported") }
        XCTAssertGreaterThan(openHeight, closedHeight, "a click on the closed island opens it")

        // The logo opens that conversation and leaves the island open.
        await click(window, x: lightCentre, top: firstRowCentre)
        await pump(0.5)
        XCTAssertEqual(recorder.focused.count, 1, "clicking the logo opens the conversation")
        XCTAssertEqual(recorder.sizes.last?.height, openHeight, "...and does not also close the island")

        // Each row's logo opens its own conversation.
        await click(window, x: lightCentre, top: secondRowCentre)
        await pump(0.5)
        XCTAssertEqual(recorder.focused.count, 2, "the second row's logo opens its conversation")
        if recorder.focused.count == 2 { XCTAssertNotEqual(recorder.focused[0], recorder.focused[1]) }
        XCTAssertEqual(recorder.sizes.last?.height, openHeight)

        // A bit off the drawing still counts: the light is small.
        await click(window, x: lightCentre - lightWidth / 2 - 4, top: firstRowCentre)
        await pump(0.5)
        XCTAssertEqual(recorder.focused.count, 3, "a click just beside the logo still lands on it")
        XCTAssertEqual(recorder.sizes.last?.height, openHeight)

        // The name and state do not open anything: the click closes the island.
        await click(window, x: textX, top: firstRowCentre)
        await pump(1.0)
        XCTAssertEqual(recorder.focused.count, 3, "the name and state do not open the conversation")
        XCTAssertEqual(recorder.sizes.last?.height, closedHeight, "clicking the name and state closes the island")

        // Open it again; the empty part of a row closes it too.
        await click(window, x: capsuleCentre, top: HUDStyle.windowMargin.top + HUDStyle.closedSize.height / 2)
        await pump(1.0)
        XCTAssertEqual(recorder.sizes.last?.height, openHeight)
        await click(window, x: Self.windowSize.width - 80, top: firstRowCentre)
        await pump(1.0)
        XCTAssertEqual(recorder.focused.count, 3, "the empty part of a row does not open the conversation")
        XCTAssertEqual(recorder.sizes.last?.height, closedHeight, "clicking the empty part of a row closes the island")
    }

    func testLogoOpensTheConversationAndEverythingElseOpensOrClosesTheIsland() async {
        await scenario(icons: false)
    }

    func testTheSameHoldsWhenTheLightsAreIcons() async {
        await scenario(icons: true)
    }
}
