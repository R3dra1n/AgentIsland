import XCTest
@testable import AgentIsland

/// The transcript cannot distinguish "waiting for approval" from "still
/// running", so the recorded hook events supply that one signal. Events here
/// use the shapes the native recorder writes for `--source claude`.
final class ClaudeHookStateTests: XCTestCase {
    let session = "session-a"
    var clock = Date(timeIntervalSince1970: 1_000_000)

    func event(_ name: String, tool: String? = "Bash", useID: String? = "toolu_1",
               session: String? = nil, at offset: TimeInterval = 0) -> [String: Any] {
        var record: [String: Any] = ["hook_event_name": name,
                                     "session_id": session ?? self.session,
                                     "received_at": clock.addingTimeInterval(offset).timeIntervalSince1970]
        if let tool { record["tool_name"] = tool }
        if let useID { record["tool_use_id"] = useID }
        return record
    }

    func reduce(_ events: [[String: Any]]) -> ClaudeHookState {
        var state = ClaudeHookState()
        for event in events { state.consume(event) }
        return state
    }

    func testPermissionRequestIsOutstandingUntilTheToolRuns() {
        var state = reduce([event("PermissionRequest")])
        XCTAssertEqual(state.awaitingApproval(session: session, now: clock), ["Bash"])

        state.consume(event("PostToolUse", at: 1))
        XCTAssertTrue(state.awaitingApproval(session: session, now: clock).isEmpty)
    }

    // A denied permission is recorded as PostToolUse by the recorder, so the
    // red state must clear rather than persist after a refusal.
    func testDeniedPermissionClearsTheOutstandingRequest() {
        let state = reduce([event("PermissionRequest"), event("PostToolUse", at: 1)])
        XCTAssertTrue(state.awaitingApproval(session: session, now: clock).isEmpty)
    }

    func testTurnEndAndNextPromptClearOutstandingRequests() {
        for closing in ["Stop", "UserPromptSubmit", "SessionEnd", "SessionStart"] {
            let state = reduce([event("PermissionRequest"),
                                event(closing, tool: nil, useID: nil, at: 1)])
            XCTAssertTrue(state.awaitingApproval(session: session, now: clock).isEmpty,
                          "\(closing) 应解除未决的授权请求")
        }
    }

    func testOnlyTheMatchingToolUseIsResolved() {
        var state = reduce([event("PermissionRequest", tool: "Bash", useID: "toolu_1"),
                            event("PermissionRequest", tool: "Edit", useID: "toolu_2", at: 1)])
        XCTAssertEqual(Set(state.awaitingApproval(session: session, now: clock)), ["Bash", "Edit"])

        state.consume(event("PostToolUse", tool: "Bash", useID: "toolu_1", at: 2))
        XCTAssertEqual(state.awaitingApproval(session: session, now: clock), ["Edit"])
    }

    func testRequestsAreScopedToTheirSession() {
        let state = reduce([event("PermissionRequest", session: "session-a"),
                            event("PermissionRequest", session: "session-b", at: 1)])
        XCTAssertEqual(state.awaitingApproval(session: "session-a", now: clock), ["Bash"])
        XCTAssertEqual(state.awaitingApproval(session: "session-b", now: clock), ["Bash"])
        XCTAssertTrue(state.awaitingApproval(session: "session-c", now: clock).isEmpty)
    }

    // A request whose resolution was never recorded must not pin the HUD red.
    func testStaleRequestIsIgnored() {
        let state = reduce([event("PermissionRequest")])
        let justInside = clock.addingTimeInterval(ClaudeHookState.staleAfter - 1)
        XCTAssertEqual(state.awaitingApproval(session: session, now: justInside), ["Bash"])
        let past = clock.addingTimeInterval(ClaudeHookState.staleAfter + 1)
        XCTAssertTrue(state.awaitingApproval(session: session, now: past).isEmpty)
    }

    func testNewestRequestIsReportedFirst() {
        let state = reduce([event("PermissionRequest", tool: "Bash", useID: "toolu_1"),
                            event("PermissionRequest", tool: "Write", useID: "toolu_2", at: 5)])
        XCTAssertEqual(state.awaitingApproval(session: session, now: clock.addingTimeInterval(5)),
                       ["Write", "Bash"])
    }

    func testMalformedAndOutOfOrderRecordsAreIgnored() {
        var state = ClaudeHookState()
        state.consume(["hook_event_name": "PermissionRequest", "received_at": 1.0])          // no session
        state.consume(["session_id": session, "received_at": 1.0])                            // no event name
        state.consume(["hook_event_name": "PermissionRequest", "session_id": session])        // no timestamp
        state.consume(event("PermissionRequest", tool: nil, useID: nil))                      // nothing to key on
        XCTAssertTrue(state.awaitingApproval(session: session, now: clock).isEmpty)

        // A record that moves time backwards is dropped, so a replayed older
        // request cannot reopen a resolved one.
        state.consume(event("PermissionRequest", at: 10))
        state.consume(event("PostToolUse", at: 20))
        state.consume(event("PermissionRequest", at: 15))
        XCTAssertTrue(state.awaitingApproval(session: session, now: clock.addingTimeInterval(20)).isEmpty)
    }

    func testUnrelatedEventsDoNotCreateState() {
        let state = reduce([event("PreToolUse"), event("Notification", tool: nil, useID: nil, at: 1)])
        XCTAssertTrue(state.awaitingApproval(session: session, now: clock).isEmpty)
    }

    // The host's own turn lifecycle is the authoritative end-of-turn signal,
    // because the transcript cannot distinguish a finished turn from one that
    // is about to call a tool.
    func testTurnStateFollowsTheHostLifecycle() {
        var state = reduce([event("UserPromptSubmit", tool: nil, useID: nil)])
        XCTAssertEqual(state.turnState(session: session, now: clock), .running)

        state.consume(event("PreToolUse", at: 1))
        XCTAssertEqual(state.turnState(session: session, now: clock), .running)

        state.consume(event("PermissionRequest", at: 2))
        XCTAssertEqual(state.turnState(session: session, now: clock), .awaitingInput)

        state.consume(event("PostToolUse", at: 3))
        XCTAssertEqual(state.turnState(session: session, now: clock), .running)

        state.consume(event("Stop", tool: nil, useID: nil, at: 4))
        XCTAssertEqual(state.turnState(session: session, now: clock), .completed)
    }

    func testFailedStopIsReportedAsFailed() {
        var record = event("Stop", tool: nil, useID: nil)
        record["has_error"] = true
        XCTAssertEqual(reduce([record]).turnState(session: session, now: clock), .failed)
    }

    func testTurnStateIsScopedStaleCheckedAndClearedOnSessionEnd() {
        var state = reduce([event("Stop", tool: nil, useID: nil)])
        XCTAssertNil(state.turnState(session: "other", now: clock))
        XCTAssertNil(state.turnState(session: session, now: clock.addingTimeInterval(ClaudeHookState.staleAfter + 1)))
        state.consume(event("SessionEnd", tool: nil, useID: nil, at: 1))
        XCTAssertNil(state.turnState(session: session, now: clock))
    }

    func testJournalReadingReportsApprovalAndTurnTogether() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        var lines = Data()
        for record in [event("UserPromptSubmit", tool: nil, useID: nil), event("PermissionRequest", at: 1)] {
            lines.append(try JSONSerialization.data(withJSONObject: record))
            lines.append(0x0a)
        }
        try lines.write(to: url)
        let reading = await ClaudeHookJournal(url: url).reading(session: session, now: clock.addingTimeInterval(1))
        XCTAssertEqual(reading.awaitingApproval, ["Bash"])
        XCTAssertEqual(reading.turnState, .awaitingInput)
    }

    // The journal is the on-disk half: a missing file means the hook is simply
    // not installed, which must not be reported as an outstanding approval.
    func testJournalWithoutAFileReportsNothingOutstanding() async {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("claude.jsonl")
        let journal = ClaudeHookJournal(url: missing)
        let result = await journal.awaitingApproval(session: session)
        XCTAssertTrue(result.isEmpty)
    }

    func testJournalReadsAppendedRecordsIncrementally() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }

        func append(_ event: [String: Any]) throws {
            let line = try JSONSerialization.data(withJSONObject: event) + Data([0x0a])
            if FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } else {
                try line.write(to: url)
            }
        }

        let journal = ClaudeHookJournal(url: url)
        try append(event("PermissionRequest"))
        var result = await journal.awaitingApproval(session: session, now: clock)
        XCTAssertEqual(result, ["Bash"])

        // A later read must see only the new record and still resolve it.
        try append(event("PostToolUse", at: 1))
        result = await journal.awaitingApproval(session: session, now: clock)
        XCTAssertTrue(result.isEmpty)
    }
}
