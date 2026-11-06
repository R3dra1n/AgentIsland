import XCTest
@testable import AgentIsland

/// Reproduces the reported defect: Codex keeps showing unanswered questions
/// from old turns. All snapshots here are synthetic; no real session content.
final class CodexHistoricalQuestionTests: XCTestCase {
    func question(_ id: String) -> [String: Any] {
        ["type": "agentMessage", "id": id, "delivery": "async", "questions": [["title": "选择？", "options": ["A", "B"]]]]
    }

    /// `entitiesByKey` form, with an explicit `isComplete` flag.
    func snapshot(isComplete: Bool, turns: [(key: String, time: Int, status: String, call: String)]) -> [String: Any] {
        var entities: [String: [String: Any]] = [:]
        for turn in turns {
            entities[turn.key] = ["turnId": turn.key, "turnStartedAtMs": turn.time,
                                  "status": turn.status, "items": [question(turn.call)]]
        }
        return ["turnHistory": ["kind": "canonical", "history": ["isComplete": isComplete, "entitiesByKey": entities]]]
    }

    // A partial snapshot is the normal case: Codex loads history lazily, so
    // `isComplete` is usually false. "A strictly newer turn exists" is positive
    // evidence that cannot be falsified by missing turns, so it must be enough.
    func testHistoricalQuestionIsHiddenOnPartialSnapshotWithNewerTurn() {
        let partial = snapshot(isComplete: false, turns: [
            (key: "old", time: 100, status: "completed", call: "old-call"),
            (key: "newest", time: 200, status: "inProgress", call: "current-call")
        ])
        XCTAssertEqual(CodexNativeBridge.historicalAsyncCalls(partial), ["old-call"],
                       "部分快照中已存在更新轮次，旧轮次的问题就应判定为历史")
    }

    // The user's rule is "turns that already ended", not "turns that succeeded".
    func testEndedTurnStatusesOtherThanCompletedAreAlsoHistorical() {
        for status in ["completed", "failed", "interrupted", "aborted"] {
            let state = snapshot(isComplete: false, turns: [
                (key: "old", time: 100, status: status, call: "old-call"),
                (key: "newest", time: 200, status: "inProgress", call: "current-call")
            ])
            XCTAssertEqual(CodexNativeBridge.historicalAsyncCalls(state), ["old-call"],
                           "已结束轮次(\(status))的问题应判定为历史")
        }
    }

    // Two turns sharing the newest timestamp must not abandon the whole pass;
    // a strictly older turn is still unambiguously historical.
    func testTiedNewestTurnsStillHideStrictlyOlderQuestions() {
        let tied = snapshot(isComplete: false, turns: [
            (key: "old", time: 100, status: "completed", call: "old-call"),
            (key: "tie-a", time: 200, status: "completed", call: "tie-a-call"),
            (key: "tie-b", time: 200, status: "completed", call: "tie-b-call")
        ])
        XCTAssertEqual(CodexNativeBridge.historicalAsyncCalls(tied), ["old-call"],
                       "最新时间戳并列时，仍应隐藏严格更旧的问题，且不隐藏并列的最新轮次")
    }

    // Conservative direction: without a strictly newer turn there is no
    // evidence, so nothing may be hidden.
    func testNewestAndUndatedTurnsAreNeverHidden() {
        let onlyNewest = snapshot(isComplete: false, turns: [
            (key: "newest", time: 200, status: "completed", call: "current-call")
        ])
        XCTAssertTrue(CodexNativeBridge.historicalAsyncCalls(onlyNewest).isEmpty)

        let undated: [String: Any] = ["turnHistory": ["kind": "canonical", "history": ["isComplete": false, "entitiesByKey": [
            "a": ["turnId": "a", "status": "completed", "items": [question("a-call")]],
            "b": ["turnId": "b", "status": "completed", "items": [question("b-call")]]
        ]]]]
        XCTAssertTrue(CodexNativeBridge.historicalAsyncCalls(undated).isEmpty,
                      "没有可比较的时间戳时不得隐藏任何问题")
    }

    // An in-progress turn is not "ended" however old its timestamp is.
    func testInProgressTurnIsNeverHistorical() {
        let state = snapshot(isComplete: false, turns: [
            (key: "slow", time: 100, status: "inProgress", call: "slow-call"),
            (key: "newest", time: 200, status: "completed", call: "current-call")
        ])
        XCTAssertTrue(CodexNativeBridge.historicalAsyncCalls(state).isEmpty,
                      "仍在执行的轮次即使时间较旧也不是历史")
    }

    // The questions actually shown in the HUD come from the desktop IPC and
    // carry `desktopMethod == "async-question"`; they are merged in after the
    // scan, so they only ever appear in the *previous* poll's requests. If the
    // trigger ignores them, complete history is never requested for exactly
    // the sessions that need it.
    func testIPCDiscoveredAsyncQuestionRequestsCompleteHistory() {
        // A freshly discovered IPC question carries only `desktopMethod`;
        // `isAsynchronous` is set later by the merge, so it must not be relied on.
        var live = CodexPendingRequest(sessionID: "ipc-session", turnID: nil,
                                       requestID: "[\"request_user_input_async\",\"call\",0]",
                                       isQuestion: true, context: "合成问题")
        live.desktopMethod = "async-question"
        XCTAssertFalse(live.isAsynchronous)
        XCTAssertEqual(CodexObserver.sessionsNeedingHistory(scanned: [], previous: [live]), ["ipc-session"],
                       "只存在于 IPC 快照中的异步问题也必须触发完整历史载入")
    }

    func testHookDerivedAsyncQuestionStillRequestsCompleteHistory() {
        let hookDerived = CodexPendingRequest(sessionID: "hook-session", turnID: "t", requestID: "call",
                                              isQuestion: true, context: nil, isAsynchronous: true)
        XCTAssertEqual(CodexObserver.sessionsNeedingHistory(scanned: [hookDerived], previous: []), ["hook-session"])
    }

    // A command approval is not an async question and must not trigger the
    // extra history read.
    func testNonAsyncRequestsDoNotRequestCompleteHistory() {
        let approval = CodexPendingRequest(sessionID: "approval-session", turnID: "t", requestID: "42",
                                           isQuestion: false, context: "echo test")
        XCTAssertTrue(CodexObserver.sessionsNeedingHistory(scanned: [approval], previous: [approval]).isEmpty)
    }

    // The reported symptom: every source reported nothing pending, yet the
    // HUD kept showing a pile of old questions. They were not in any source —
    // they were carried in memory. A session the desktop can no longer reach
    // had its previous requests re-appended on every poll, with nothing to
    // ever expire them.
    func testCarriedRequestsExpireOnceTheDesktopStopsConfirmingTheSession() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let fresh = now.addingTimeInterval(-CodexObserver.carryOverGrace + 1)
        let stale = now.addingTimeInterval(-CodexObserver.carryOverGrace - 1)
        XCTAssertTrue(CodexObserver.mayCarryOver(lastConfirmed: fresh, now: now),
                      "短暂的 IPC 失败期间应保留，避免闪烁")
        XCTAssertFalse(CodexObserver.mayCarryOver(lastConfirmed: stale, now: now),
                       "桌面端长时间无法确认的会话，其请求不得永久停留")
    }

    // A request the log scanner derives is rebuilt from the transcript every
    // poll, so there is nothing to bridge and nothing to resurrect.
    func testNeverConfirmedSessionIsNotCarried() {
        XCTAssertFalse(CodexObserver.mayCarryOver(lastConfirmed: nil, now: Date()))
    }

    // A hook installed through the app writes under AgentIsland; the observer
    // read the pre-rename folder, so those events were never seen.
    func testHookJournalIsReadFromTheCurrentLocation() {
        let home = URL(fileURLWithPath: "/tmp/home")
        XCTAssertTrue(CodexObserver.hookJournalURL(home: home, fileExists: { _ in false }).path
            .hasSuffix("Library/Application Support/AgentIsland/events/codex.jsonl"))
        XCTAssertTrue(CodexObserver.hookJournalURL(home: home, fileExists: { $0.contains("/AgentIsland/events/") }).path
            .contains("/AgentIsland/events/"))
    }

    // Someone who still has only an old journal keeps being read; once a current
    // one exists it takes over.
    func testTheOldJournalIsOnlyUsedWhenItIsTheOnlyOne() {
        let home = URL(fileURLWithPath: "/tmp/home")
        let onlyOld = CodexObserver.hookJournalURL(home: home, fileExists: { $0.contains("/AiKeyboardLight/events/") })
        XCTAssertTrue(onlyOld.path.contains("/AiKeyboardLight/events/"))
        let both = CodexObserver.hookJournalURL(home: home, fileExists: { _ in true })
        XCTAssertTrue(both.path.contains("/AgentIsland/events/"))
    }

    // End-to-end at the merge layer: a historical call id removes the live
    // request and the carried-over queued copy, leaving no pending request so
    // the aggregate state can fall through to 执行中 instead of 需操作.
    func testHistoricalCallIsRemovedFromBothLiveAndCarriedRequests() {
        let callID = "old-call"
        let requestID = "[\"request_user_input_async\",\"old-call\",0]"
        var live = CodexPendingRequest(sessionID: "s", turnID: nil, requestID: requestID,
                                       isQuestion: true, context: "旧问题")
        live.desktopMethod = "async-question"
        let carried = CodexPendingRequest(sessionID: "s", turnID: "t", requestID: callID,
                                          isQuestion: true, context: "旧问题", isAsynchronous: true)
        let merged = CodexObserver.mergeRequests([carried], live: [live], session: "s",
                                                 historicalAsyncCallIDs: [callID])
        XCTAssertTrue(merged.isEmpty, "被判定为历史的问题不应留在待处理列表中")
    }
}
