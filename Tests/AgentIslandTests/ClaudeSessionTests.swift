import XCTest
@testable import AgentIsland

/// Several Claude Code conversations at once. Records follow the shapes of the
/// real transcript and hook journal; every value here is synthetic.
final class ClaudeSessionEvaluatorTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 3_000_000)
    typealias Reading = ClaudeHookJournal.Reading

    func tool(_ name: String = "Bash", input: [String: Any] = ["command": "swift test"]) -> ClaudeTranscript.PendingTool {
        .init(id: "t1", name: name, input: input)
    }

    func question() -> ClaudeTranscript.PendingTool {
        .init(id: "q1", name: "AskUserQuestion",
              input: ["questions": [["question": "要先修哪一个？", "options": [["label": "甲"], ["label": "乙"]]]]])
    }

    func evaluate(age: TimeInterval = 1, pending: [ClaudeTranscript.PendingTool] = [], endsWithText: Bool = false,
                  hook: Reading = .init()) -> ClaudeSessionSnapshot? {
        ClaudeSessionEvaluator.evaluate(id: "s", modified: now.addingTimeInterval(-age), pending: pending,
                                        endsWithAssistantText: endsWithText, hook: hook, now: now)
    }

    // Someone answering a question may well be away from the keyboard, so it
    // must outlive the freshness window that gates everything else. The old
    // single-session code dropped it after two minutes.
    func testQuestionHasNoAgeLimit() throws {
        let snapshot = try XCTUnwrap(evaluate(age: 3 * 3600, pending: [question()]))
        XCTAssertEqual(snapshot.state, .awaitingInput)
        XCTAssertTrue(try XCTUnwrap(snapshot.actionDetail).hasPrefix("❓ 要先修哪一个？"))
    }

    // An abandoned conversation's unanswered question is waiting on no one.
    func testSessionEndedAfterItsLastWriteIsNotShown() {
        let ended = Reading(endedAt: now.addingTimeInterval(-3600 + 1))
        XCTAssertNil(evaluate(age: 3600, pending: [question()], hook: ended))
        // A write after the end means the conversation was resumed.
        let resumed = Reading(endedAt: now.addingTimeInterval(-3600))
        XCTAssertNotNil(evaluate(age: 60, pending: [question()], hook: resumed))
    }

    func testPermissionRequestShowsTheToolAndTheRealCommand() throws {
        let snapshot = try XCTUnwrap(evaluate(pending: [tool()], hook: Reading(awaitingApproval: ["Bash"])))
        XCTAssertEqual(snapshot.state, .awaitingInput)
        let detail = try XCTUnwrap(snapshot.actionDetail)
        XCTAssertTrue(detail.hasPrefix("🔒 等待授权：Bash"))
        XCTAssertTrue(detail.contains("swift test"))
    }

    // The host's own Stop is authoritative even when the transcript still shows
    // a tool call with no result.
    func testHookCompletionOutranksADanglingToolCall() throws {
        let stopped = now.addingTimeInterval(-5)
        let snapshot = try XCTUnwrap(evaluate(pending: [tool()], hook: Reading(turnState: .completed, turnStateAt: stopped)))
        XCTAssertEqual(snapshot.state, .completed)
        XCTAssertEqual(snapshot.completedAt, stopped)
    }

    func testFailedTurnIsShownBrieflyThenDropped() throws {
        let failedAt = now.addingTimeInterval(-ClaudeSessionEvaluator.failedVisible + 1)
        XCTAssertEqual(evaluate(hook: Reading(turnState: .failed, turnStateAt: failedAt))?.state, .failed)
        let old = now.addingTimeInterval(-ClaudeSessionEvaluator.failedVisible - 1)
        XCTAssertNil(evaluate(hook: Reading(turnState: .failed, turnStateAt: old)))
    }

    func testRunningTurnShowsTheCurrentToolButDoesNotOutliveADeadSession() throws {
        let running = Reading(turnState: .running, turnStateAt: now)
        let working = try XCTUnwrap(evaluate(age: 30, pending: [tool()], hook: running))
        XCTAssertEqual(working.state, .running)
        XCTAssertTrue(try XCTUnwrap(working.actionDetail).contains("swift test"))
        // A long command keeps the turn alive however quiet the transcript is.
        XCTAssertEqual(evaluate(age: 3600, pending: [tool()], hook: running)?.state, .running)
        // Nothing outstanding and a transcript that stopped moving long ago is
        // a session that died without reporting it.
        XCTAssertNotNil(evaluate(age: ClaudeSessionEvaluator.runningStale - 1, hook: running))
        XCTAssertNil(evaluate(age: ClaudeSessionEvaluator.runningStale + 1, hook: running))
    }

    func testWithoutAHookOnlyFreshTranscriptsAreTrusted() {
        XCTAssertEqual(evaluate(age: 10, pending: [tool()])?.state, .running)
        XCTAssertNil(evaluate(age: ClaudeSessionEvaluator.recentWindow + 1, pending: [tool()]))
        XCTAssertEqual(evaluate(age: 2)?.state, .running)
        XCTAssertNil(evaluate(age: 30))
    }

    // The assistant's text and its tool call are separate records, so the gap
    // between them looks like a finished turn until the transcript goes quiet.
    func testWithoutAHookCompletionNeedsTheTranscriptToGoQuiet() {
        XCTAssertNotEqual(evaluate(age: ClaudeTranscript.quietTurnEnd - 1, endsWithText: true)?.state, .completed)
        XCTAssertEqual(evaluate(age: ClaudeTranscript.quietTurnEnd + 1, endsWithText: true)?.state, .completed)
        XCTAssertNil(evaluate(age: ClaudeSessionEvaluator.recentWindow + 1, endsWithText: true))
    }

    func testLeadingSessionIsTheOneThatNeedsTheUserMost() throws {
        func session(_ id: String, _ state: AIState, _ seconds: TimeInterval) -> ClaudeSessionSnapshot {
            .init(id: id, state: state, description: id, actionDetail: nil, lastActiveDate: now.addingTimeInterval(seconds))
        }
        XCTAssertEqual(ClaudeSessionEvaluator.leading([session("run", .running, 0), session("ask", .awaitingInput, -50),
                                                       session("done", .completed, 0)])?.id, "ask")
        // Equal needs: the most recently active one leads.
        XCTAssertEqual(ClaudeSessionEvaluator.leading([session("old", .running, -10), session("new", .running, 0)])?.id, "new")
        XCTAssertNil(ClaudeSessionEvaluator.leading([]))
    }
}

final class ClaudeSessionScannerTests: XCTestCase {
    var root: URL!
    var projects: URL { root.appendingPathComponent("projects") }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("claude-scan-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    func record(_ role: String, _ blocks: [[String: Any]], type: String? = nil) -> String {
        let object: [String: Any] = ["type": type ?? role, "message": ["role": role, "content": blocks]]
        return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    func toolUse(_ id: String, _ name: String, _ input: [String: Any]) -> [String: Any] {
        ["type": "tool_use", "id": id, "name": name, "input": input]
    }

    @discardableResult
    func write(_ lines: [String], project: String = "proj", session: String, age: TimeInterval = 1,
               now: Date) throws -> URL {
        let folder = projects.appendingPathComponent(project)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(session + ".jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: url.path)
        return url
    }

    func scanner(hook: URL? = nil) -> ClaudeSessionScanner {
        ClaudeSessionScanner(projects: projects,
                             journal: ClaudeHookJournal(url: hook ?? root.appendingPathComponent("none.jsonl")))
    }

    // The reported defect: two conversations ran at once and only the most
    // recently written one was ever shown, so the display jumped between them.
    func testTwoConversationsAreBothReported() async throws {
        let now = Date()
        try write([record("assistant", [toolUse("a", "Bash", ["command": "ls"])])], session: "aaaa", now: now)
        try write([record("assistant", [toolUse("q", "AskUserQuestion",
                    ["questions": [["question": "选哪个？", "options": [["label": "甲"]]]]])])],
                  project: "other", session: "bbbb", now: now)
        let sessions = await scanner().scan(now: now)
        XCTAssertEqual(Set(sessions.map(\.id)), ["aaaa", "bbbb"])
        XCTAssertEqual(sessions.first { $0.id == "aaaa" }?.state, .running)
        XCTAssertEqual(sessions.first { $0.id == "bbbb" }?.state, .awaitingInput)
    }

    func testSubagentFilesOldTranscriptsAndOtherFilesAreIgnored() async throws {
        let now = Date()
        try write([record("assistant", [toolUse("a", "Bash", ["command": "ls"])])], session: "live", now: now)
        // Deeper than projects/<project>/<session>.jsonl: a subagent, not a conversation.
        let deeper = projects.appendingPathComponent("proj/live/subagents")
        try FileManager.default.createDirectory(at: deeper, withIntermediateDirectories: true)
        try (record("assistant", [toolUse("s", "Bash", ["command": "ls"])]) + "\n")
            .write(to: deeper.appendingPathComponent("agent-1.jsonl"), atomically: true, encoding: .utf8)
        // Older than the inspection window.
        try write([record("assistant", [toolUse("o", "Bash", ["command": "ls"])])], session: "stale",
                  age: ClaudeSessionScanner.window + 60, now: now)
        // Not a transcript at all.
        try "x".write(to: projects.appendingPathComponent("proj/notes.txt"), atomically: true, encoding: .utf8)
        let sessions = await scanner().scan(now: now)
        XCTAssertEqual(sessions.map(\.id), ["live"])
    }

    // Parsing is cached per file, so a change has to invalidate the cache or a
    // conversation would stay frozen at whatever it looked like on first sight.
    func testAChangedTranscriptIsReadAgain() async throws {
        let now = Date()
        let url = try write([record("assistant", [toolUse("a", "Bash", ["command": "ls"])])], session: "aaaa", now: now)
        let watcher = scanner()
        let first = await watcher.scan(now: now)
        XCTAssertEqual(first.first?.state, .running)

        // The tool call is answered: the next scan must notice without a restart.
        let answered = record("user", [["type": "tool_result", "tool_use_id": "a", "content": "ok"]])
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd(); try handle.write(contentsOf: Data((answered + "\n").utf8)); try handle.close()
        let later = now.addingTimeInterval(3)
        try FileManager.default.setAttributes([.modificationDate: later], ofItemAtPath: url.path)
        let after = await watcher.scan(now: later.addingTimeInterval(1))
        XCTAssertEqual(after.first?.state, .running, "新写入后一秒内仍在交互中")
        XCTAssertTrue(after.first?.actionDetail == nil, "已回应的工具不应再显示为进行中的命令")
    }

    func testTheHookJournalDecidesEachConversationSeparately() async throws {
        let now = Date()
        try write([record("assistant", [toolUse("a", "Bash", ["command": "ls"])])], session: "finished", now: now)
        try write([record("assistant", [toolUse("b", "Bash", ["command": "ls"])])], session: "working", now: now)
        let journal = root.appendingPathComponent("claude.jsonl")
        var lines = Data()
        for event: [String: Any] in [
            ["hook_event_name": "Stop", "session_id": "finished", "received_at": now.timeIntervalSince1970 - 1],
            ["hook_event_name": "PreToolUse", "session_id": "working", "tool_name": "Bash", "tool_use_id": "b",
             "received_at": now.timeIntervalSince1970 - 1]
        ] {
            lines.append(try JSONSerialization.data(withJSONObject: event)); lines.append(0x0a)
        }
        try lines.write(to: journal)
        let sessions = await scanner(hook: journal).scan(now: now)
        XCTAssertEqual(sessions.first { $0.id == "finished" }?.state, .completed)
        XCTAssertEqual(sessions.first { $0.id == "working" }?.state, .running)
    }

    func testNoTranscriptsMeansNoSessions() async {
        let sessions = await scanner().scan(now: Date())
        XCTAssertTrue(sessions.isEmpty)
    }
}

final class ClaudeHookLifecycleTests: XCTestCase {
    let clock = Date(timeIntervalSince1970: 1_000_000)

    func event(_ name: String, at offset: TimeInterval = 0) -> [String: Any] {
        ["hook_event_name": name, "session_id": "s", "received_at": clock.addingTimeInterval(offset).timeIntervalSince1970]
    }

    func testSessionEndIsRecordedAndAnyLaterEventRevivesTheSession() {
        var state = ClaudeHookState()
        state.consume(event("SessionEnd"))
        XCTAssertEqual(state.endedAt(session: "s"), clock)
        state.consume(event("PreToolUse", at: 5))
        XCTAssertNil(state.endedAt(session: "s"), "会话在结束后又有事件，说明已被续用")
    }

    func testTurnStateTimeIsReportedUnderTheSameStalenessRule() {
        var state = ClaudeHookState()
        state.consume(event("Stop"))
        XCTAssertEqual(state.turnStateTime(session: "s", now: clock), clock)
        XCTAssertNil(state.turnStateTime(session: "s", now: clock.addingTimeInterval(ClaudeHookState.staleAfter + 1)))
    }

    func testSubagentRecordsDoNotDecideWhetherTheMainConversationFinished() {
        func record(_ role: String, _ blocks: [[String: Any]], sidechain: Bool) -> [String: Any] {
            ["type": role, "isSidechain": sidechain, "message": ["role": role, "content": blocks]]
        }
        let records = [record("assistant", [["type": "text", "text": "主会话说完了"]], sidechain: false),
                       // A subagent's text arrives afterwards and must not be credited as the end.
                       record("assistant", [["type": "text", "text": "子代理的输出"]], sidechain: true)]
        XCTAssertTrue(ClaudeTranscript.endsWithAssistantText(records))
        XCTAssertFalse(ClaudeTranscript.endsWithAssistantText([record("assistant", [["type": "text", "text": "子代理"]], sidechain: true)]))
    }
}

@MainActor
final class ClaudeSessionRowTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 4_000_000)

    func session(_ id: String, _ state: AIState, completedAgo: TimeInterval? = nil) -> ClaudeSessionSnapshot {
        .init(id: id, state: state, description: "d-\(id)", actionDetail: "detail-\(id)",
              lastActiveDate: now, completedAt: completedAgo.map { now.addingTimeInterval(-$0) })
    }

    func provider(enabled: Bool = true) -> AIObserverItem {
        .init(id: "claude", name: "Claude", icon: "claude", isEnabled: enabled, state: .running, description: "d")
    }

    func testTwoConversationsBecomeTwoRowsWithStableNames() {
        let rows = AppState.expandClaudeSessions([provider()], sessions: [session("b", .awaitingInput), session("a", .running)],
                                                 labels: ["a": 1, "b": 2])
        XCTAssertEqual(rows.map(\.name), ["Claude · 会话 1", "Claude · 会话 2"])
        XCTAssertEqual(rows.map(\.state), [.running, .awaitingInput])
        XCTAssertEqual(rows.map { $0.id }, [AppState.claudeSessionPrefix + "a", AppState.claudeSessionPrefix + "b"])
        XCTAssertTrue(rows.allSatisfy { $0.icon == "claude" })
    }

    // One conversation keeps the plain provider row, so people who only ever
    // run one see no change.
    func testASingleConversationKeepsTheProviderRow() {
        let single = AppState.expandClaudeSessions([provider()], sessions: [session("a", .running)], labels: ["a": 1])
        XCTAssertEqual(single.map(\.id), ["claude"])
        XCTAssertEqual(AppState.expandClaudeSessions([provider()], sessions: [], labels: [:]).map(\.id), ["claude"])
    }

    func testOtherProvidersAreLeftAlone() {
        let codex = AIObserverItem(id: "codex", name: "Codex", icon: "codex", isEnabled: true, state: .idle, description: "")
        let rows = AppState.expandClaudeSessions([codex, provider()], sessions: [session("a", .running), session("b", .running)],
                                                 labels: ["a": 1, "b": 2])
        XCTAssertEqual(rows.map(\.id).first, "codex")
        XCTAssertEqual(rows.count, 3)
    }

    func testAcknowledgingOneFinishedConversationLeavesTheOtherAlone() {
        let sessions = [session("a", .completed, completedAgo: 10), session("b", .completed, completedAgo: 10),
                        session("c", .running)]
        // The viewed conversation drops out instead of sitting there as a grey row.
        let rows = AppState.expandClaudeSessions([provider()], sessions: sessions, labels: ["a": 1, "b": 2, "c": 3],
                                                 acknowledged: ["a": now])
        XCTAssertEqual(rows.map(\.state), [.completed, .running])
        XCTAssertEqual(rows.map(\.name), ["Claude · 会话 2", "Claude · 会话 3"])
        // New activity after the acknowledgement brings it back.
        let reopened = AppState.expandClaudeSessions([provider()], sessions: sessions, labels: ["a": 1, "b": 2, "c": 3],
                                                     acknowledged: ["a": now.addingTimeInterval(-60)])
        XCTAssertEqual(reopened.map(\.state), [.completed, .completed, .running])
    }

    // Only a finished conversation can be acknowledged; a running one is not "viewed".
    func testRunningConversationIsNeverTreatedAsViewed() {
        let rows = AppState.expandClaudeSessions([provider()], sessions: [session("a", .running), session("b", .running)],
                                                 labels: ["a": 1, "b": 2], acknowledged: ["a": now.addingTimeInterval(3600)])
        XCTAssertEqual(rows.map(\.state), [.running, .running])
    }
}

/// The reported defect, end to end: a conversation finishes, drops out of the
/// live list two minutes later while its "done" is still on screen, and
/// clicking that row then had nothing to go on, assumed a terminal, and
/// brought one forward. For a desktop-app conversation nothing visible happened.
final class ClaudeFinishedRowStillOpensTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("claude-open-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("projects/proj"), withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    @MainActor private func eventually(_ seconds: TimeInterval = 8, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return condition()
    }

    @MainActor func testRowStillKnowsWhereToGoAfterTheConversationLeavesTheLiveList() async throws {
        _ = NSApplication.shared
        let state = AppState()
        // The app's own observers read the real home directory; only the one
        // under test may report here.
        [state.codexObserver as any AIObserverProtocol, state.antigravityObserver, state.claudeObserver,
         state.cursorObserver, state.windsurfObserver, state.traeObserver].forEach { $0.stopObserving() }
        state.lastAcknowledgedDates = [:]

        func line(_ object: [String: Any]) -> String {
            String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        }
        let transcript = root.appendingPathComponent("projects/proj/finished-session.jsonl")
        let lines = [
            line(["type": "user", "entrypoint": "claude-desktop", "message": ["role": "user", "content": "hi"]]),
            line(["type": "assistant", "entrypoint": "claude-desktop",
                  "message": ["role": "assistant", "content": [["type": "text", "text": "done"]]]]),
        ]
        try (lines.joined(separator: "\n") + "\n").write(to: transcript, atomically: true, encoding: .utf8)
        func age(_ seconds: TimeInterval) throws {
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-seconds)], ofItemAtPath: transcript.path)
        }
        // Finished a few seconds ago, with no hook: shown as done.
        try age(10)

        let observer = ClaudeObserver(root: root, hookURL: root.appendingPathComponent("no-hook.jsonl"))
        observer.delegate = state
        observer.startObserving()
        defer { observer.stopObserving() }

        let appeared = await eventually { state.claudeState == .completed && !state.claudeSessions.isEmpty }
        XCTAssertTrue(appeared, "the finished conversation should show as done")
        XCTAssertEqual(state.lastKnownClaudeSession?.entrypoint, "claude-desktop")

        // Two minutes on, the conversation is no longer live, but "done" stays
        // on screen until it is viewed.
        try age(ClaudeSessionEvaluator.recentWindow + 60)
        let gone = await eventually { state.claudeSessions.isEmpty }
        XCTAssertTrue(gone, "an old hook-less conversation leaves the live list")
        XCTAssertEqual(state.claudeState, .completed, "the done mark outlives the live list")

        // Which is exactly when the row used to know nothing about where to go.
        XCTAssertNil(AppState.mostRelevantClaudeSession(state.claudeSessions))
        let target = AppState.claudeSessionToOpen(live: state.claudeSessions, remembered: state.lastKnownClaudeSession)
        XCTAssertEqual(target?.id, "finished-session")
        XCTAssertEqual(AppState.claudeOpenTarget(entrypoint: target?.entrypoint, state: target?.state ?? .idle), .desktopApp)
    }

    private func snap(_ id: String, _ state: AIState, _ entry: String?) -> ClaudeSessionSnapshot {
        ClaudeSessionSnapshot(id: id, state: state, description: "d", actionDetail: "old question",
                              lastActiveDate: Date(timeIntervalSince1970: 1000), entrypoint: entry)
    }

    func testLiveConversationsWinOverTheRememberedOne() {
        let picked = AppState.claudeSessionToOpen(live: [snap("live", .running, "cli")], remembered: snap("old", .completed, "claude-desktop"))
        XCTAssertEqual(picked?.id, "live")
    }

    func testRememberedConversationNoLongerClaimsToBeWaiting() {
        // A question that was answered since must not send the app to
        // "needs input" for a conversation that is no longer asking.
        let picked = AppState.claudeSessionToOpen(live: [], remembered: snap("asked", .awaitingInput, "claude-desktop"))
        XCTAssertEqual(picked?.state, .completed)
        XCTAssertNil(picked?.actionDetail)
        XCTAssertEqual(AppState.claudeOpenTarget(entrypoint: picked?.entrypoint, state: picked?.state ?? .idle), .desktopApp)
    }

    func testNothingLiveAndNothingRememberedStillHasNoAnswer() {
        XCTAssertNil(AppState.claudeSessionToOpen(live: [], remembered: nil))
    }
}

/// The reported defect: opening one of two finished Claude conversations turned
/// both grey. Bringing the desktop app forward announced an activation, which was
/// taken as the user switching over to look at everything the app hosts.
@MainActor
final class ClaudeOpeningMarksOnlyThatConversationTests: XCTestCase {
    private let desktop = (name: "Claude", bundle: "com.anthropic.claudefordesktop")

    private func makeState(_ sessions: [ClaudeSessionSnapshot]) -> AppState {
        _ = NSApplication.shared
        let state = AppState()
        // The app's own observers read the real home directory; they must not
        // report into this test.
        [state.codexObserver as any AIObserverProtocol, state.antigravityObserver, state.claudeObserver,
         state.cursorObserver, state.windsurfObserver, state.traeObserver].forEach { $0.stopObserving() }
        state.lastAcknowledgedDates = [:]
        state.claudeAcknowledgedSessions = [:]
        state.claudeSessions = sessions
        state.claudeState = sessions.contains { $0.state == .completed } ? .completed : .running
        state.claudeNeedsAck = sessions.contains { $0.state == .completed }
        return state
    }

    private func session(_ id: String, _ state: AIState, finishedAgo: TimeInterval = 30) -> ClaudeSessionSnapshot {
        let t = Date().addingTimeInterval(-finishedAgo)
        return ClaudeSessionSnapshot(id: id, state: state, description: "d", actionDetail: nil, lastActiveDate: t,
                                     completedAt: state == .completed ? t : nil, entrypoint: "claude-desktop")
    }

    private func viewed(_ state: AppState, _ id: String) -> Bool {
        guard let s = state.claudeSessions.first(where: { $0.id == id }), let done = s.completedAt else { return false }
        return (state.claudeAcknowledgedSessions[id] ?? .distantPast) >= done
    }

    func testOpeningOneOfTwoFinishedConversationsLeavesTheOtherAsItWas() {
        let a = session("a", .completed), b = session("b", .completed)
        let state = makeState([a, b])

        state.noteClaudeConversationOpened(a)
        // The app comes forward and says so a moment later.
        state.acknowledgeClaudeConversationsViewedByActivating(frontName: desktop.name, frontBundle: desktop.bundle, now: Date())

        XCTAssertTrue(viewed(state, "a"), "the conversation that was opened has been looked at")
        XCTAssertFalse(viewed(state, "b"), "the other one has not")
        XCTAssertEqual(state.claudeState, .completed, "so the provider still has something to show")
        XCTAssertTrue(state.claudeNeedsAck)
    }

    func testOpeningTheLastUnviewedConversationClearsTheProvider() {
        let a = session("a", .completed), b = session("b", .completed)
        let state = makeState([a, b])
        state.noteClaudeConversationOpened(a)
        state.noteClaudeConversationOpened(b)
        XCTAssertTrue(viewed(state, "a") && viewed(state, "b"))
        XCTAssertEqual(state.claudeState, .idle)
        XCTAssertFalse(state.claudeNeedsAck)
    }

    func testOpeningARunningConversationDoesNotClearAFinishedOne() {
        let running = session("run", .running), done = session("done", .completed)
        let state = makeState([running, done])
        state.noteClaudeConversationOpened(running)
        state.acknowledgeClaudeConversationsViewedByActivating(frontName: desktop.name, frontBundle: desktop.bundle, now: Date())
        XCTAssertFalse(viewed(state, "done"), "going to look at one conversation is not looking at the finished one")
    }

    func testTheUserSwitchingToTheAppStillViewsWhatItHosts() {
        // Nothing was opened by the island, so this is the user's own doing.
        let state = makeState([session("a", .completed), session("b", .completed)])
        state.acknowledgeClaudeConversationsViewedByActivating(frontName: desktop.name, frontBundle: desktop.bundle, now: Date())
        XCTAssertTrue(viewed(state, "a") && viewed(state, "b"))
    }

    func testTheIslandsOwnActivationIsOnlyIgnoredForAMoment() {
        let a = session("a", .completed), b = session("b", .completed)
        let state = makeState([a, b])
        state.noteClaudeConversationOpened(a)
        let opened = state.claudeOpenedByIslandAt!
        // Well after the island's own switch, coming back to the app is the user's.
        state.acknowledgeClaudeConversationsViewedByActivating(frontName: desktop.name, frontBundle: desktop.bundle,
                                                               now: opened.addingTimeInterval(AppState.ownActivationWindow + 1))
        XCTAssertTrue(viewed(state, "b"))
        XCTAssertFalse(AppState.isOwnClaudeActivation(openedAt: nil, now: Date()))
        XCTAssertTrue(AppState.isOwnClaudeActivation(openedAt: opened, now: opened.addingTimeInterval(1)))
        XCTAssertFalse(AppState.isOwnClaudeActivation(openedAt: opened, now: opened.addingTimeInterval(AppState.ownActivationWindow + 1)))
    }

    func testAFinishedConversationThatLeftTheLiveListIsClearedWhenOpened() {
        // Nothing live, "done" still showing: the row opens the remembered
        // conversation, and that has been looked at.
        let state = makeState([])
        state.claudeState = .completed
        state.claudeNeedsAck = true
        state.noteClaudeConversationOpened(session("gone", .completed))
        XCTAssertEqual(state.claudeState, .idle)
        XCTAssertFalse(state.claudeNeedsAck)
    }
}
