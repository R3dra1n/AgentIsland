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

    func testPreparedQuestionIsNotRepeatedAndChangedDetailsAreNewTarget() {
        let id = identity(), uuid = UUID()
        let question = AntigravityQuestion(cascadeID: uuid, trajectoryID: uuid, stepIndex: 0,
            question: "synthetic question", options: [], stepFingerprint: Data([1]))
        let endpoint = AntigravityLocalTransport.Endpoint(pid: 123, port: 456, certificate: Data([1]))
        let prepared = ["a": AntigravityPreparedQuestion(identity: id, detail: "synthetic question", question: question, endpoint: endpoint)]
        XCTAssertEqual(prepared["a"]?.question(matching: id, detail: "synthetic question"), question)
        XCTAssertNil(prepared["a"]?.question(matching: identity(2), detail: "synthetic question"))
        XCTAssertNil(prepared["a"]?.question(matching: id, detail: "different question"))
        let same = AntigravityPrevalidationPolicy.candidates(enabled: true, consent: true,
            sessions: [session("a", identity: id)], inFlight: [], attempted: [:], prepared: prepared, limit: 2)
        XCTAssertTrue(same.isEmpty)
        let changed = AntigravitySessionSnapshot(id: "a", state: .awaitingInput, description: "waiting",
            actionDetail: "different question", pendingIdentity: id, lastActiveDate: nil)
        let next = AntigravityPrevalidationPolicy.candidates(enabled: true, consent: true,
            sessions: [changed], inFlight: [], attempted: [:], prepared: prepared, limit: 2)
        XCTAssertEqual(next.map(\.0), ["a"])
    }
}
