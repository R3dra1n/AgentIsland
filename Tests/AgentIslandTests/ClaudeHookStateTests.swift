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

    // The reported defect. A real PermissionRequest carries only the tool name,
    // never a tool_use_id, while the completion that resolves it carries the id.
    // Keyed by name, the two never matched and the approval stayed pending after
    // the user had already allowed it and the command had finished.
    func testPermissionWithoutAnIDIsResolvedByTheCallItFollowed() {
        var state = ClaudeHookState()
        state.consume(event("PreToolUse", tool: "Bash", useID: "toolu_A"))
        state.consume(event("PermissionRequest", tool: "Bash", useID: nil, at: 1))
        XCTAssertEqual(state.awaitingApproval(session: session, now: clock.addingTimeInterval(1)), ["Bash"])
        // Nothing is recorded between approving and the command finishing, so
        // the row necessarily reads as waiting for that whole time.
        XCTAssertEqual(state.awaitingApproval(session: session, now: clock.addingTimeInterval(40)), ["Bash"])
        state.consume(event("PostToolUse", tool: "Bash", useID: "toolu_A", at: 46))
        XCTAssertTrue(state.awaitingApproval(session: session, now: clock.addingTimeInterval(46)).isEmpty)
        XCTAssertEqual(state.turnState(session: session, now: clock.addingTimeInterval(46)), .running)
    }

    // A call that needed no permission finishing must not clear another call's.
    func testAnotherCallsCompletionDoesNotResolveThePermission() {
        var state = ClaudeHookState()
        state.consume(event("PreToolUse", tool: "Write", useID: "toolu_W"))
        state.consume(event("PreToolUse", tool: "Bash", useID: "toolu_B", at: 1))
        state.consume(event("PermissionRequest", tool: "Bash", useID: nil, at: 2))
        state.consume(event("PostToolUse", tool: "Write", useID: "toolu_W", at: 3))
        XCTAssertEqual(state.awaitingApproval(session: session, now: clock.addingTimeInterval(3)), ["Bash"])
        state.consume(event("PostToolUse", tool: "Bash", useID: "toolu_B", at: 4))
        XCTAssertTrue(state.awaitingApproval(session: session, now: clock.addingTimeInterval(4)).isEmpty)
    }

    // Two calls of the same tool: each permission claims its own call, newest
    // first, and finishing one leaves the other waiting.
    func testTwoPermissionsForTheSameToolEachClaimTheirOwnCall() {
        var state = ClaudeHookState()
        state.consume(event("PreToolUse", tool: "Bash", useID: "toolu_1"))
        state.consume(event("PreToolUse", tool: "Bash", useID: "toolu_2", at: 1))
        state.consume(event("PermissionRequest", tool: "Bash", useID: nil, at: 2))
        state.consume(event("PermissionRequest", tool: "Bash", useID: nil, at: 3))
        XCTAssertEqual(state.awaitingApproval(session: session, now: clock.addingTimeInterval(3)).count, 2)
        state.consume(event("PostToolUse", tool: "Bash", useID: "toolu_2", at: 4))
        XCTAssertEqual(state.awaitingApproval(session: session, now: clock.addingTimeInterval(4)).count, 1)
        state.consume(event("PostToolUse", tool: "Bash", useID: "toolu_1", at: 5))
        XCTAssertTrue(state.awaitingApproval(session: session, now: clock.addingTimeInterval(5)).isEmpty)
    }

    // A permission whose PreToolUse was never seen (the hook was installed
    // mid-call) is resolved by the next completion of the same tool.
    func testPermissionWithNoPrecedingCallIsResolvedByTheSameToolFinishing() {
        var state = ClaudeHookState()
        state.consume(event("PermissionRequest", tool: "Bash", useID: nil))
        XCTAssertEqual(state.awaitingApproval(session: session, now: clock), ["Bash"])
        state.consume(event("PostToolUse", tool: "Edit", useID: "toolu_E", at: 1))
        XCTAssertEqual(state.awaitingApproval(session: session, now: clock.addingTimeInterval(1)), ["Bash"],
                       "另一种工具的完成不应解除它")
        state.consume(event("PostToolUse", tool: "Bash", useID: "toolu_X", at: 2))
        XCTAssertTrue(state.awaitingApproval(session: session, now: clock.addingTimeInterval(2)).isEmpty)
    }

    // A refused permission ends the call the same way, and a turn that stops
    // clears whatever is left, including the open-call bookkeeping.
    func testTurnEndClearsPermissionsAndOpenCalls() {
        var state = ClaudeHookState()
        state.consume(event("PreToolUse", tool: "Bash", useID: "toolu_A"))
        state.consume(event("PermissionRequest", tool: "Bash", useID: nil, at: 1))
        state.consume(event("Stop", tool: nil, useID: nil, at: 2))
        XCTAssertTrue(state.awaitingApproval(session: session, now: clock.addingTimeInterval(2)).isEmpty)
        // A permission after the stop must not be attached to the forgotten call.
        state.consume(event("PermissionRequest", tool: "Bash", useID: nil, at: 3))
        state.consume(event("PostToolUse", tool: "Bash", useID: "toolu_A", at: 4))
        XCTAssertTrue(state.awaitingApproval(session: session, now: clock.addingTimeInterval(4)).isEmpty)
    }

    // End to end through the journal, with events shaped exactly as the
    // recorder writes them: no tool_use_id on the permission request.
    func testJournalReplayOfARealShapedApprovalEndsResolved() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        func line(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object) + Data([0x0a]) }
        var data = Data()
        data += try line(["hook_event_name": "PreToolUse", "session_id": session, "tool_name": "Bash",
                          "tool_use_id": "toolu_R", "received_at": clock.timeIntervalSince1970])
        data += try line(["hook_event_name": "PermissionRequest", "session_id": session, "tool_name": "Bash",
                          "command_digest": String(repeating: "a", count: 64), "turn_id": "p1",
                          "received_at": clock.timeIntervalSince1970 + 1])
        try data.write(to: url)
        let journal = ClaudeHookJournal(url: url)
        let waiting = await journal.reading(session: session, now: clock.addingTimeInterval(2))
        XCTAssertEqual(waiting.awaitingApproval, ["Bash"])

        let finished = try line(["hook_event_name": "PostToolUse", "session_id": session, "tool_name": "Bash",
                                 "tool_use_id": "toolu_R", "received_at": clock.timeIntervalSince1970 + 46])
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd(); try handle.write(contentsOf: finished); try handle.close()
        let after = await journal.reading(session: session, now: clock.addingTimeInterval(47))
        XCTAssertTrue(after.awaitingApproval.isEmpty)
        XCTAssertEqual(after.turnState, .running)
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

final class ClaudeOpenRoutingTests: XCTestCase {
    func testDesktopSessionOpensTheDesktopApp() {
        XCTAssertEqual(AppState.claudeOpenTarget(entrypoint: "claude-desktop", state: .completed), .desktopApp)
        XCTAssertEqual(AppState.claudeOpenTarget(entrypoint: "claude-desktop", state: .awaitingInput), .desktopNeedsInput)
    }
    func testTerminalAndUnknownSessionsUseTheTerminal() {
        XCTAssertEqual(AppState.claudeOpenTarget(entrypoint: "cli", state: .awaitingInput), .terminal)
        XCTAssertEqual(AppState.claudeOpenTarget(entrypoint: nil, state: .completed), .terminal)
    }
    func testEntrypointTakesTheNewestValue() {
        let records: [[String: Any]] = [["entrypoint": "cli"], ["type": "user"], ["entrypoint": "claude-desktop"]]
        XCTAssertEqual(ClaudeTranscript.entrypoint(records), "claude-desktop")
        XCTAssertNil(ClaudeTranscript.entrypoint([["type": "user"]]))
    }
}

final class ClaudeMostRelevantSessionTests: XCTestCase {
    private func snap(_ id: String, _ state: AIState, _ age: TimeInterval, _ entry: String?) -> ClaudeSessionSnapshot {
        ClaudeSessionSnapshot(id: id, state: state, description: "", actionDetail: nil,
                              lastActiveDate: Date(timeIntervalSince1970: 1000 - age), entrypoint: entry)
    }
    func testAwaitingBeatsRunningBeatsCompleted() {
        let picked = AppState.mostRelevantClaudeSession([snap("a", .completed, 1, "cli"), snap("b", .awaitingInput, 50, "claude-desktop"), snap("c", .running, 0, "cli")])
        XCTAssertEqual(picked?.id, "b")
    }
    func testNewestWinsWithinTheSameState() {
        XCTAssertEqual(AppState.mostRelevantClaudeSession([snap("old", .completed, 90, "cli"), snap("new", .completed, 5, "claude-desktop")])?.id, "new")
        XCTAssertNil(AppState.mostRelevantClaudeSession([]))
    }

    func testSwitchingToTheHostAppViewsItsFinishedConversations() {
        let t = Date(timeIntervalSince1970: 1_000)
        func session(_ id: String, _ state: AIState, _ entry: String?) -> ClaudeSessionSnapshot {
            ClaudeSessionSnapshot(id: id, state: state, description: "", actionDetail: nil, lastActiveDate: t, completedAt: t, entrypoint: entry)
        }
        let sessions = [session("desk-done", .completed, "claude-desktop"), session("desk-run", .running, "claude-desktop"),
                        session("cli-done", .completed, "cli")]
        // A second conversation is still running: the finished one is still viewed.
        XCTAssertEqual(AppState.claudeSessionsViewedByActivating(sessions: sessions, acknowledged: [:],
            frontName: "Claude", frontBundle: "com.anthropic.claudefordesktop", focusedDesktopTranscript: "desk-done"), ["desk-done"])
        XCTAssertEqual(AppState.claudeSessionsViewedByActivating(sessions: sessions, acknowledged: [:],
            frontName: "Terminal", frontBundle: "com.apple.Terminal"), ["cli-done"])
        XCTAssertEqual(AppState.claudeSessionsViewedByActivating(sessions: sessions, acknowledged: ["desk-done": t],
            frontName: "Claude", frontBundle: "com.anthropic.claudefordesktop", focusedDesktopTranscript: "desk-done"), [])
        XCTAssertEqual(AppState.claudeSessionsViewedByActivating(sessions: sessions, acknowledged: [:],
            frontName: "Safari", frontBundle: "com.apple.Safari"), [])
    }
}
