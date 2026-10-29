import Foundation
import XCTest
@testable import AgentIsland

final class AntigravityPrevalidationPolicyTests: XCTestCase {
    private func identity(_ generation: UInt64 = 1) -> AntigravityPendingIdentity {
        .init(transcript: URL(fileURLWithPath: "/tmp/synthetic/transcript.jsonl"), fileID: 1,
              changedAt: .distantPast, requestID: "test", generation: generation)
    }

    private func session(_ id: String, identity: AntigravityPendingIdentity? = nil) -> AntigravitySessionSnapshot {
        .init(id: id, state: .awaitingInput, description: "waiting", actionDetail: "synthetic question",
              pendingIdentity: identity, lastActiveDate: nil)
    }

    func testDisabledOrWithoutConsentNeverSchedules() {
        let sessions = [session("a", identity: identity())]
        XCTAssertTrue(AntigravityPrevalidationPolicy.candidates(enabled: false, consent: true, sessions: sessions,
            inFlight: [], attempted: [:], prepared: [:], limit: 2).isEmpty)
        XCTAssertTrue(AntigravityPrevalidationPolicy.candidates(enabled: true, consent: false, sessions: sessions,
            inFlight: [], attempted: [:], prepared: [:], limit: 2).isEmpty)
    }

    func testOnlyUnambiguousSessionsAreScheduledWithinLimit() {
        let sessions = [session("ambiguous"), session("a", identity: identity()), session("b", identity: identity()), session("c", identity: identity())]
        let result = AntigravityPrevalidationPolicy.candidates(enabled: true, consent: true, sessions: sessions,
            inFlight: ["b"], attempted: [:], prepared: [:], limit: 1)
        XCTAssertEqual(result.map(\.0), ["a"])
    }

    func testSameFailedRequestIsNotRepeatedButNewGenerationCanBeScheduled() {
        let previous = AntigravityPrevalidationTarget(identity: identity(), detail: "synthetic question")
        let attempted = ["a": previous]
        let unchanged = AntigravityPrevalidationPolicy.candidates(enabled: true, consent: true,
            sessions: [session("a", identity: identity())], inFlight: [], attempted: attempted, prepared: [:], limit: 2)
        XCTAssertTrue(unchanged.isEmpty)
        let changed = AntigravityPrevalidationPolicy.candidates(enabled: true, consent: true,
            sessions: [session("a", identity: identity(2))], inFlight: [], attempted: attempted, prepared: [:], limit: 2)
        XCTAssertEqual(changed.map(\.0), ["a"])
    }
}
