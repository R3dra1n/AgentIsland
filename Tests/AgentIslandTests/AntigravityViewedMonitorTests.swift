import XCTest
import CryptoKit
@testable import AgentIsland

@MainActor
final class AntigravityViewedMonitorTests: XCTestCase {
    func testOnlyLoopbackConversationURLsResolveToOpaqueSessionIDs() {
        let uuid = "11111111-2222-4333-8444-555555555555"
        let digest = SHA256.hash(data: Data(uuid.utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(AntigravityViewedMonitor.sessionID(for: URL(string: "http://127.0.0.1:58850/c/\(uuid)?section=test")), "ag:" + digest)
        XCTAssertEqual(AntigravityViewedMonitor.sessionID(forRawURL: "127.0.0.1:58850/c/\(uuid)?section=test"), "ag:" + digest)
        XCTAssertNil(AntigravityViewedMonitor.sessionID(forRawURL: "127.0.0.1.evil.example/c/\(uuid)"))
        XCTAssertNil(AntigravityViewedMonitor.sessionID(for: URL(string: "https://example.com/c/\(uuid)")))
        XCTAssertNil(AntigravityViewedMonitor.sessionID(for: URL(string: "http://127.0.0.1:58850/settings")))
        XCTAssertNil(AntigravityViewedMonitor.sessionID(for: URL(string: "http://127.0.0.1:58850/c/not-a-uuid")))
    }

    func testOnlyClicksAfterTheMatchingCompletionCanAcknowledgeIt() {
        let now = Date(timeIntervalSince1970: 1000)
        func session(_ state: AIState, completedAt: Date?) -> AntigravitySessionSnapshot {
            .init(id: "ag:synthetic", state: state, description: "", actionDetail: nil,
                  pendingIdentity: nil, lastActiveDate: now, completedAt: completedAt)
        }
        XCTAssertTrue(AntigravityViewedMonitor.isEligible(session: session(.completed, completedAt: now), clickedAt: now))
        XCTAssertFalse(AntigravityViewedMonitor.isEligible(session: session(.completed, completedAt: now.addingTimeInterval(1)), clickedAt: now))
        XCTAssertFalse(AntigravityViewedMonitor.isEligible(session: session(.awaitingInput, completedAt: now), clickedAt: now))
        XCTAssertFalse(AntigravityViewedMonitor.isEligible(session: session(.completed, completedAt: nil), clickedAt: now))
    }
}
