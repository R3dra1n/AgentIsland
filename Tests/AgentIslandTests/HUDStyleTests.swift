import XCTest
import SwiftUI
@testable import AgentIsland

/// The HUD's look is a spec (a black morphing capsule); these pin its numbers
/// and the one rule with behavioural weight: when the capsule opens by itself.
final class HUDStyleTests: XCTestCase {
    func testClosedCapsuleIs112By28() {
        let size = HUDStyle.capsuleSize(isOpen: false, rows: 3, dots: 3)
        XCTAssertEqual(size.width, 112)
        XCTAssertEqual(size.height, 28)
    }

    func testClosedCapsuleWidensOnlyWhenDotsDoNotFit() {
        XCTAssertEqual(HUDStyle.closedWidth(dots: 0), 112)
        XCTAssertEqual(HUDStyle.closedWidth(dots: 5), 112)
        XCTAssertGreaterThan(HUDStyle.closedWidth(dots: 6), 112)
    }

    func testOpenHeightIsRowsTimes56Plus14() {
        for rows in 1...8 {
            XCTAssertEqual(HUDStyle.openHeight(rows: rows), CGFloat(rows * 56 + 14))
        }
        XCTAssertEqual(HUDStyle.capsuleSize(isOpen: true, rows: 2, dots: 2).width, 440)
    }

    func testOpenHeightIsCappedToTheScreen() {
        let size = HUDStyle.capsuleSize(isOpen: true, rows: 20, dots: 6, maxOpenHeight: 500)
        XCTAssertEqual(size.height, 500)
    }

    func testWindowKeepsRoomForTheShadow() {
        let window = HUDStyle.windowSize(for: CGSize(width: 440, height: 126))
        XCTAssertGreaterThanOrEqual(window.width - 440, 2 * 34)
        XCTAssertGreaterThanOrEqual(window.height - 126, 10 + 34)
    }

    func testStatusLightColours() {
        XCTAssertEqual(HUDStyle.lightHex(for: .awaitingInput), 0xFF5C5C)
        XCTAssertEqual(HUDStyle.lightHex(for: .running), 0xFFC24B)
        XCTAssertEqual(HUDStyle.lightHex(for: .completed), 0x3DDC84)
        XCTAssertEqual(HUDStyle.lightHex(for: .idle), 0x4A5164)
        XCTAssertEqual(HUDStyle.lightHex(for: .unknown), 0x4A5164)
        // Failed and interrupted must not borrow the "needs you" red.
        XCTAssertNotEqual(HUDStyle.lightHex(for: .failed), HUDStyle.redHex)
        XCTAssertNotEqual(HUDStyle.lightHex(for: .interrupted), HUDStyle.redHex)
    }

    func testOpensByItselfOnlyForRedOrUnviewedGreen() {
        XCTAssertTrue(HUDStyle.opensAutomatically([.idle, .awaitingInput]))
        XCTAssertTrue(HUDStyle.opensAutomatically([.running, .completed]))
        XCTAssertFalse(HUDStyle.opensAutomatically([]))
        XCTAssertFalse(HUDStyle.opensAutomatically([.idle, .unknown]))
        XCTAssertFalse(HUDStyle.opensAutomatically([.running, .running]))
        XCTAssertFalse(HUDStyle.opensAutomatically([.failed, .interrupted]))
    }

    func testRowSpacingMatchesTheSpec() {
        XCTAssertEqual(HUDStyle.rowHeight, 52)
        XCTAssertEqual(HUDStyle.rowCornerRadius, 15)
        XCTAssertEqual(HUDStyle.rowHorizontalPadding, 12)
        XCTAssertEqual(HUDStyle.rowSpacing, 4)
        XCTAssertEqual(HUDStyle.containerPadding, 9)
        XCTAssertEqual(HUDStyle.dotSize, 10)
        XCTAssertEqual(HUDStyle.dotSpacing, 10)
    }

    // Collapsing an automatically opened capsule must stick for that attention,
    // yet a new red or unviewed-green row must open it again.
    func testAttentionKeysIdentifyRowsThatAskToOpen() {
        func item(_ id: String, _ state: AIState) -> AIObserverItem {
            AIObserverItem(id: id, name: id, icon: id, isEnabled: true, state: state, description: "")
        }
        let first = HUDStyle.attentionKeys([item("a", .completed), item("b", .running), item("c", .idle)])
        XCTAssertEqual(first, ["a|completed"])
        let dismissed = first
        // The same row, same state: still dismissed.
        XCTAssertTrue(HUDStyle.attentionKeys([item("a", .completed)]).subtracting(dismissed).isEmpty)
        // A different row, or the same row now needing the user: new, so it opens.
        XCTAssertFalse(HUDStyle.attentionKeys([item("a", .completed), item("d", .completed)]).subtracting(dismissed).isEmpty)
        XCTAssertFalse(HUDStyle.attentionKeys([item("a", .awaitingInput)]).subtracting(dismissed).isEmpty)
        XCTAssertTrue(HUDStyle.attentionKeys([item("a", .running)]).isEmpty)
    }
}

final class HUDIconStyleTests: XCTestCase {
    func testIconsWidenTheClosedCapsuleOnlyWhenNeeded() {
        XCTAssertEqual(HUDStyle.closedWidth(dots: 3, icons: true), HUDStyle.closedSize.width)
        XCTAssertGreaterThan(HUDStyle.closedWidth(dots: 6, icons: true), HUDStyle.closedWidth(dots: 6, icons: false))
    }
}

final class HUDPulseTests: XCTestCase {
    func testPulsePhaseIsAFullBreathEveryPeriod() {
        XCTAssertEqual(HUDStyle.pulsePhase(at: 0), 0, accuracy: 1e-9)
        XCTAssertEqual(HUDStyle.pulsePhase(at: HUDStyle.pulsePeriod / 2), 1, accuracy: 1e-9)
        XCTAssertEqual(HUDStyle.pulsePhase(at: HUDStyle.pulsePeriod), 0, accuracy: 1e-9)
        for t in stride(from: 0.0, to: 6.0, by: 0.13) {
            let p = HUDStyle.pulsePhase(at: t)
            XCTAssertTrue((0...1).contains(p))
        }
    }

    func testVerticalClosedCapsuleStacksDots() {
        let flat = HUDStyle.closedCapsule(dots: 3)
        let tall = HUDStyle.closedCapsule(dots: 3, vertical: true)
        XCTAssertEqual(flat, CGSize(width: 112, height: 28))
        XCTAssertEqual(tall, CGSize(width: 28, height: 112))
        XCTAssertGreaterThan(HUDStyle.closedCapsule(dots: 8, vertical: true).height, 112)
        // Opening is the same shape either way.
        XCTAssertEqual(HUDStyle.capsuleSize(isOpen: true, rows: 2, dots: 2, vertical: true),
                       HUDStyle.capsuleSize(isOpen: true, rows: 2, dots: 2))
    }

    func testGlowFollowsTheMostPressingState() {
        XCTAssertEqual(HUDStyle.glowHex(for: .awaitingInput), HUDStyle.redHex)
        XCTAssertEqual(HUDStyle.glowHex(for: .running), HUDStyle.yellowHex)
        XCTAssertEqual(HUDStyle.glowHex(for: .completed), HUDStyle.greenHex)
        XCTAssertNil(HUDStyle.glowHex(for: .idle))
        // Red breathes; only red casts a halo.
        XCTAssertGreaterThan(HUDStyle.glowOpacity(for: .awaitingInput, phase: 0), HUDStyle.glowOpacity(for: .awaitingInput, phase: 1))
        XCTAssertEqual(HUDStyle.glowShadowOpacity(for: .running, phase: 0), 0)
    }

    @MainActor func testClosedCapsuleHasOneLightPerRow() {
        let rows = [
            AIObserverItem(id: "claude-session:a", name: "Claude · 会话 1", icon: "claude", isEnabled: true, state: .running, description: ""),
            AIObserverItem(id: "claude-session:b", name: "Claude · 会话 2", icon: "claude", isEnabled: true, state: .completed, description: ""),
            AIObserverItem(id: "codex", name: "Codex", icon: "codex", isEnabled: true, state: .idle, description: ""),
        ]
        let lights = HUDStyle.closedLights(rows)
        XCTAssertEqual(lights.map(\.state), [.running, .completed, .idle])
        XCTAssertEqual(Set(lights.map(\.id)).count, 3)
        XCTAssertEqual(lights.map(\.icon), ["claude", "claude", "codex"])
        XCTAssertEqual(lights[0].name, "Claude")
    }
}
