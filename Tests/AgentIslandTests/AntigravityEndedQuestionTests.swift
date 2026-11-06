import XCTest
@testable import AgentIsland

/// The reported defect: an Antigravity conversation was closed with a question
/// unanswered, and the HUD kept showing it as needing action. The transcript
/// records the question being asked but nothing when the conversation is
/// cancelled, so only the language server can say it is no longer waiting.
final class AntigravityEndedQuestionTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 5_000_000)
    let transcript = URL(fileURLWithPath: "/tmp/brain/aaaa/.system_generated/logs/transcript.jsonl")

    func identity(_ id: UInt64 = 1, changedAgo: TimeInterval = 3600) -> AntigravityPendingIdentity {
        AntigravityPendingIdentity(transcript: transcript, fileID: id, changedAt: now.addingTimeInterval(-changedAgo))
    }

    func session(_ id: String, _ state: AIState, identity: AntigravityPendingIdentity? = nil, detail: String? = nil,
                 active: TimeInterval = 0) -> AntigravitySessionSnapshot {
        AntigravitySessionSnapshot(id: id, state: state, description: "d-\(id)", actionDetail: detail,
                                   pendingIdentity: identity, lastActiveDate: now.addingTimeInterval(active))
    }

    func snapshot(_ sessions: [AntigravitySessionSnapshot], state: AIState, pending: Int,
                  identity: AntigravityPendingIdentity? = nil, detail: String? = nil) -> ObserverSnapshot {
        var value = ObserverSnapshot(state: state, description: "raw", lastActiveDate: now, actionDetail: detail)
        value.antigravitySessions = sessions
        value.antigravityPendingSessions = pending
        value.antigravityPendingIdentity = identity
        return value
    }

    // --- the parser must tell "nothing is waiting" from "cannot be trusted" ---

    private func trajectory(waiting: Int) throws -> Data {
        let id = UUID().uuidString
        var steps: [[String: Any]] = [["status": "CORTEX_STEP_STATUS_DONE"], ["status": "CORTEX_STEP_STATUS_CANCELED"]]
        for _ in 0..<waiting {
            let index = steps.count
            steps.append(["status": "CORTEX_STEP_STATUS_WAITING",
                          "requestedInteraction": ["askQuestion": ["questions": [["question": "Choose"]]]],
                          "m": ["trajectoryId": id, "stepIndex": index]])
        }
        return try JSONSerialization.data(withJSONObject: ["trajectory": ["trajectoryId": id, "steps": steps]])
    }

    func testNoWaitingStepIsReportedAsNoLongerWaitingNotAsMalformed() throws {
        XCTAssertThrowsError(try AntigravityInteractionParser.parse(trajectory(waiting: 0), cascadeID: UUID())) { error in
            guard case AntigravityInteractionError.noWaitingQuestion = error else { return XCTFail("got \(error)") }
        }
    }

    // Two waiting steps are ambiguous, not "ended": hiding the question there
    // would hide one that may well be waiting.
    func testAmbiguousWaitingStepsAreStillAnInvalidStructure() throws {
        XCTAssertThrowsError(try AntigravityInteractionParser.parse(trajectory(waiting: 2), cascadeID: UUID())) { error in
            guard case AntigravityInteractionError.invalid = error else { return XCTFail("got \(error)") }
        }
    }

    func testAnUnreadableTrajectoryIsNotMistakenForAnEnding() {
        XCTAssertThrowsError(try AntigravityInteractionParser.parse(Data("not json".utf8), cascadeID: UUID())) { error in
            if case AntigravityInteractionError.noWaitingQuestion = error { XCTFail("unreadable data is not proof of an ending") }
        }
    }

    // --- grace period ---

    func testAQuestionIsOnlyTreatedAsEndedAfterTheGracePeriod() {
        let grace = AntigravityActionController.endedQuestionGrace
        XCTAssertFalse(AntigravityActionController.shouldTreatQuestionAsEnded(since: now.addingTimeInterval(-grace + 1), now: now),
                       "刚提出的问题，服务器端的视图可能落后于 transcript，不能当作已结束")
        XCTAssertTrue(AntigravityActionController.shouldTreatQuestionAsEnded(since: now.addingTimeInterval(-grace), now: now))
        XCTAssertTrue(AntigravityActionController.shouldTreatQuestionAsEnded(since: now.addingTimeInterval(-3600), now: now))
    }

    // --- applying an ending to the scanned snapshot ---

    func testAnEndedQuestionNoLongerCountsAsNeedingAction() {
        let id = identity()
        let raw = snapshot([session("a", .awaitingInput, identity: id, detail: "❓ q")], state: .awaitingInput,
                           pending: 1, identity: id, detail: "❓ q")
        let result = AntigravityObserver.reconciling(raw, ended: [id])
        XCTAssertEqual(result.snapshot.state, .idle)
        XCTAssertEqual(result.snapshot.antigravityPendingSessions, 0)
        XCTAssertNil(result.snapshot.antigravityPendingIdentity)
        XCTAssertNil(result.snapshot.actionDetail)
        XCTAssertEqual(result.snapshot.antigravitySessions.first?.state, .idle)
        XCTAssertNil(result.snapshot.antigravitySessions.first?.pendingIdentity)
        XCTAssertEqual(result.ended, [id])
    }

    func testTheProviderFallsBackToWhatElseIsHappening() {
        let id = identity()
        let raw = snapshot([session("a", .awaitingInput, identity: id, detail: "q"), session("b", .running)],
                           state: .awaitingInput, pending: 1, identity: id, detail: "q")
        let result = AntigravityObserver.reconciling(raw, ended: [id])
        XCTAssertEqual(result.snapshot.state, .running)
        XCTAssertEqual(result.snapshot.description, AntigravityObserver.description(for: .running))
    }

    // Only the confirmed-ended question is cleared; another one still waiting
    // keeps the provider red and keeps its own detail.
    func testAnotherStillWaitingQuestionIsLeftAlone() {
        let ended = identity(1), waiting = identity(2, changedAgo: 10)
        let raw = snapshot([session("a", .awaitingInput, identity: ended, detail: "old q", active: -3000),
                            session("b", .awaitingInput, identity: waiting, detail: "live q", active: -5)],
                           state: .awaitingInput, pending: 2, identity: nil, detail: "old q")
        let result = AntigravityObserver.reconciling(raw, ended: [ended])
        XCTAssertEqual(result.snapshot.state, .awaitingInput)
        XCTAssertEqual(result.snapshot.antigravityPendingSessions, 1)
        XCTAssertEqual(result.snapshot.antigravityPendingIdentity, waiting)
        XCTAssertEqual(result.snapshot.actionDetail, "live q", "聚合详情不得继续指向已结束的问题")
        XCTAssertEqual(result.snapshot.antigravitySessions.map(\.state), [.idle, .awaitingInput])
    }

    // A waiting state that did not come from these sessions (a hook, say) is
    // not something the server's answer disproves.
    func testWaitingFromOutsideTheSessionListIsNotDisproved() {
        let id = identity()
        let raw = snapshot([session("a", .awaitingInput, identity: id, detail: "q")], state: .awaitingInput,
                           pending: 2, identity: nil, detail: "q")
        let result = AntigravityObserver.reconciling(raw, ended: [id])
        XCTAssertEqual(result.snapshot.state, .awaitingInput, "不能证明另一个来源的等待也已结束")
        XCTAssertEqual(result.snapshot.antigravitySessions.first?.state, .idle, "但这个会话的行本身要更正")
    }

    // New activity changes the identity, so an old ending cannot hide a new
    // question; and endings for questions that are gone are forgotten.
    func testAnEndingDoesNotApplyToAFreshQuestionAndIsForgottenOnceStale() {
        let old = identity(1), fresh = identity(2, changedAgo: 5)
        let raw = snapshot([session("a", .awaitingInput, identity: fresh, detail: "new q")], state: .awaitingInput,
                           pending: 1, identity: fresh, detail: "new q")
        let result = AntigravityObserver.reconciling(raw, ended: [old])
        XCTAssertEqual(result.snapshot.state, .awaitingInput)
        XCTAssertEqual(result.snapshot.antigravitySessions.first?.pendingIdentity, fresh)
        XCTAssertTrue(result.ended.isEmpty, "已不存在的问题所对应的结束记录应被清掉，避免集合无界成长")
    }

    func testNothingEndedLeavesTheSnapshotUntouched() {
        let id = identity()
        let raw = snapshot([session("a", .awaitingInput, identity: id, detail: "q")], state: .awaitingInput,
                           pending: 1, identity: id, detail: "q")
        let result = AntigravityObserver.reconciling(raw, ended: [])
        XCTAssertEqual(result.snapshot.antigravitySessions, raw.antigravitySessions)
        XCTAssertEqual(result.snapshot.state, .awaitingInput)
    }
}
