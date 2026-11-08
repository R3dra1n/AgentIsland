import XCTest
@testable import AgentIsland

/// Codex used to be one row however many conversations were open, so a second
/// Codex window finishing next to the first was invisible. The conversations
/// are rows now, as Claude's are.
final class CodexSessionSnapshotTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ secondsAgo: TimeInterval) -> Date { now.addingTimeInterval(-secondsAgo) }
    private func live(_ id: String, _ state: AIState, started: TimeInterval) -> CodexLiveActivity {
        .init(sessionID: id, turnID: nil, state: state, startedAt: at(started))
    }
    private func build(live: [CodexLiveActivity] = [], fallback: [String: AIState] = [:], finished: [CodexLiveActivity] = [],
                       requests: [CodexPendingRequest] = []) -> [CodexSessionSnapshot] {
        CodexObserver.sessionSnapshots(live: live, fallback: fallback, finished: finished, requests: requests, now: now)
    }

    // The reported case: two conversations finished a minute apart, and the
    // desktop answers for only one of them.
    func testTwoFinishedConversationsAreTwoSessionsEvenWhenTheDesktopAnswersForOne() {
        let sessions = build(live: [live("desktop-open", .completed, started: 200)],
                             finished: [live("desktop-open", .completed, started: 120), live("not-open", .completed, started: 70)])
        XCTAssertEqual(Set(sessions.map(\.id)), ["desktop-open", "not-open"])
        XCTAssertTrue(sessions.allSatisfy { $0.state == .completed })
        // The open one is dated by when it finished, not when its turn began.
        XCTAssertEqual(sessions.first { $0.id == "desktop-open" }?.completedAt, at(120))
    }

    func testRunningBeatsWhatTheTranscriptRemembersOfAnEarlierTurn() {
        let sessions = build(live: [live("a", .running, started: 10)], finished: [live("a", .completed, started: 500)])
        XCTAssertEqual(sessions.map(\.state), [.running])
    }

    func testAnUnansweredRequestMakesTheConversationWaiting() {
        let request = CodexPendingRequest(sessionID: "a", turnID: nil, requestID: "r", isQuestion: false, context: "run ls")
        let sessions = build(live: [live("a", .running, started: 10)], requests: [request])
        XCTAssertEqual(sessions.first?.state, .awaitingInput)
        XCTAssertEqual(sessions.first?.actionDetail, "run ls")
    }

    func testFallbackActiveConversationsShowWhenTheDesktopCannotAnswer() {
        let sessions = build(fallback: ["x": .running, "y": .awaitingInput])
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0.state) }), ["x": .running, "y": .awaitingInput])
    }

    func testConversationsFinishedLongAgoAreHistory() {
        let sessions = build(live: [live("old", .completed, started: CodexObserver.sessionWindow + 60)],
                             finished: [live("older", .completed, started: CodexObserver.sessionWindow + 600),
                                        live("fresh", .completed, started: 60)])
        XCTAssertEqual(sessions.map(\.id), ["fresh"])
    }

    func testOldestComesFirstSoTheNumberingFollowsTheOrderTheyNeededAttention() {
        let sessions = build(finished: [live("late", .completed, started: 10), live("early", .completed, started: 100)])
        XCTAssertEqual(sessions.map(\.id), ["early", "late"])
    }
}

@MainActor
final class CodexSessionRowsTests: XCTestCase {
    private let now = Date()
    private func provider(_ state: AIState = .completed) -> AIObserverItem {
        AIObserverItem(id: "codex", name: "Codex", icon: "codex", isEnabled: true, state: state, description: "Codex")
    }
    private func session(_ id: String, _ state: AIState, finishedAgo: TimeInterval = 60) -> CodexSessionSnapshot {
        let t = now.addingTimeInterval(-finishedAgo)
        return CodexSessionSnapshot(id: id, state: state, description: "Codex：\(state.title)", lastActiveDate: t,
                                    completedAt: state == .completed ? t : nil)
    }
    private let labels = ["a": 1, "b": 2]

    func testTwoFinishedConversationsAreTwoRows() {
        let rows = AppState.expandCodexSessions([provider()], sessions: [session("a", .completed), session("b", .completed)],
                                                labels: labels, acknowledged: [:], providerAcknowledgedAt: nil)
        XCTAssertEqual(rows.map(\.name), ["Codex · 会话 1", "Codex · 会话 2"])
        XCTAssertEqual(rows.map(\.id), ["codex-session:a", "codex-session:b"])
        XCTAssertTrue(rows.allSatisfy { $0.icon == "codex" && $0.state == .completed })
    }

    func testOneConversationKeepsTheProviderRow() {
        let rows = AppState.expandCodexSessions([provider()], sessions: [session("a", .completed), session("b", .running, finishedAgo: 5)],
                                                labels: labels, acknowledged: ["a": now], providerAcknowledgedAt: nil)
        // a is viewed: only b needs anything, so the provider's own row stays.
        XCTAssertEqual(rows.map(\.id), ["codex"])
    }

    func testViewingOneLeavesTheOtherAsARowOfItsOwn() {
        let rows = AppState.expandCodexSessions([provider()], sessions: [session("a", .completed), session("b", .completed), session("c", .running)],
                                                labels: ["a": 1, "b": 2, "c": 3], acknowledged: ["a": now], providerAcknowledgedAt: nil)
        XCTAssertEqual(rows.map(\.name), ["Codex · 会话 2", "Codex · 会话 3"])
    }

    // What was acknowledged before conversations had rows must keep counting, or
    // every conversation finished earlier today would come back as "done".
    func testTheProviderLevelMarkStillCoversWhatItCovered() {
        let sessions = [session("a", .completed, finishedAgo: 600), session("b", .completed, finishedAgo: 300), session("c", .completed, finishedAgo: 10)]
        let rows = AppState.expandCodexSessions([provider()], sessions: sessions, labels: ["a": 1, "b": 2, "c": 3],
                                                acknowledged: [:], providerAcknowledgedAt: now.addingTimeInterval(-100))
        // Only c finished after the provider was acknowledged.
        XCTAssertEqual(rows.map(\.id), ["codex"])
        XCTAssertTrue(AppState.codexSessionIsViewed(sessions[0], acknowledged: [:], providerAcknowledgedAt: now.addingTimeInterval(-100)))
        XCTAssertFalse(AppState.codexSessionIsViewed(sessions[2], acknowledged: [:], providerAcknowledgedAt: now.addingTimeInterval(-100)))
    }

    func testARunningConversationIsNeverViewed() {
        XCTAssertFalse(AppState.codexSessionIsViewed(session("a", .running), acknowledged: ["a": now.addingTimeInterval(3600)],
                                                     providerAcknowledgedAt: now.addingTimeInterval(3600)))
    }

    func testNumbersStartAtOneAndAreGivenBackWhenAConversationIsGone() {
        var labels = AppState.assignCodexLabels(existing: [:], visible: ["a", "b"])
        XCTAssertEqual(labels, ["a": 1, "b": 2])
        // A new one arrives: the others keep their numbers.
        labels = AppState.assignCodexLabels(existing: labels, visible: ["a", "b", "c"])
        XCTAssertEqual(labels, ["a": 1, "b": 2, "c": 3])
        // a is viewed and leaves; b and c do not move, and the next one takes 1.
        labels = AppState.assignCodexLabels(existing: labels, visible: ["b", "c"])
        XCTAssertEqual(labels, ["b": 2, "c": 3])
        labels = AppState.assignCodexLabels(existing: labels, visible: ["b", "c", "d"])
        XCTAssertEqual(labels, ["b": 2, "c": 3, "d": 1])
    }

    func testMoreThanThreeFoldIntoAChipThatKeepsTheWorstState() {
        let ids = ["a", "b", "c", "d"]
        let sessions = ids.map { session($0, $0 == "d" ? .awaitingInput : .completed) }
        let labels = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0 + 1) })
        let rows = AppState.expandCodexSessions([provider()], sessions: sessions, labels: labels, acknowledged: [:], providerAcknowledgedAt: nil)
        XCTAssertEqual(rows.count, 4)
        XCTAssertTrue(rows.contains { $0.id == "codex-session:d" }, "the one that needs an answer keeps its row")
        XCTAssertEqual(rows.last?.id, "overflow:codex")
        XCTAssertEqual(rows.last?.name, "+1")
    }
}

/// Opening one Codex conversation marks only that one, and the Codex app coming
/// forward because the island asked is not the user switching to look at all.
@MainActor
final class CodexOpeningMarksOnlyThatConversationTests: XCTestCase {
    private func makeState(_ sessions: [CodexSessionSnapshot]) -> AppState {
        _ = NSApplication.shared
        let state = AppState()
        [state.codexObserver as any AIObserverProtocol, state.antigravityObserver, state.claudeObserver,
         state.cursorObserver, state.windsurfObserver, state.traeObserver].forEach { $0.stopObserving() }
        state.lastAcknowledgedDates = [:]
        state.codexAcknowledgedSessions = [:]
        state.codexSessions = sessions
        state.codexState = .completed
        state.codexNeedsAck = true
        return state
    }

    private func finished(_ id: String, ago: TimeInterval = 30) -> CodexSessionSnapshot {
        let t = Date().addingTimeInterval(-ago)
        return CodexSessionSnapshot(id: id, state: .completed, description: "d", lastActiveDate: t, completedAt: t)
    }

    private func viewed(_ state: AppState, _ id: String) -> Bool {
        state.codexSessions.first { $0.id == id }.map {
            AppState.codexSessionIsViewed($0, acknowledged: state.codexAcknowledgedSessions, providerAcknowledgedAt: state.lastAcknowledgedDates["codex"])
        } ?? false
    }

    func testOpeningOneOfTwoLeavesTheOther() {
        let state = makeState([finished("a"), finished("b")])
        state.noteCodexConversationOpened("a")
        XCTAssertTrue(viewed(state, "a"))
        XCTAssertFalse(viewed(state, "b"))
        XCTAssertEqual(state.codexState, .completed, "so the provider still has something to show")
        XCTAssertTrue(state.codexNeedsAck)
    }

    func testOpeningTheLastOneClearsTheProvider() {
        let state = makeState([finished("a"), finished("b")])
        state.noteCodexConversationOpened("a")
        state.noteCodexConversationOpened("b")
        XCTAssertEqual(state.codexState, .idle)
        XCTAssertFalse(state.codexNeedsAck)
    }

    func testTheIslandsOwnActivationIsNotTheUserLookingAtEverything() {
        let state = makeState([finished("a"), finished("b")])
        state.noteCodexConversationOpened("a")
        XCTAssertTrue(AppState.isOwnActivation(openedAt: state.codexOpenedByIslandAt, now: Date()))
    }

    func testProviderRowOpensTheOnlyConversationThatNeedsAnything() {
        let state = makeState([finished("old", ago: 600), finished("only", ago: 5)])
        state.lastAcknowledgedDates["codex"] = Date().addingTimeInterval(-100)
        XCTAssertEqual(state.codexConversationForProviderRow(), "only")
        // Two unviewed, or none: no particular conversation.
        let two = makeState([finished("a"), finished("b")])
        XCTAssertNil(two.codexConversationForProviderRow())
        let none = makeState([finished("a")])
        none.lastAcknowledgedDates["codex"] = Date()
        XCTAssertNil(none.codexConversationForProviderRow())
    }
}

/// End to end through AppState: what the island would draw for the reported case,
/// two Codex windows, one running and one just finished.
@MainActor
final class CodexDisplayedRowsTests: XCTestCase {
    func testTwoCodexWindowsAreTwoRowsInTheIsland() {
        _ = NSApplication.shared
        let state = AppState()
        state.codexEnabled = true
        // Switching Codex on starts its observer, which reads the real home
        // directory: only what this test sets may be shown.
        [state.codexObserver as any AIObserverProtocol, state.antigravityObserver, state.claudeObserver,
         state.cursorObserver, state.windsurfObserver, state.traeObserver].forEach { $0.stopObserving() }
        state.hudDisplayMode = .whenActive
        state.lastAcknowledgedDates = [:]
        state.codexAcknowledgedSessions = [:]
        let finishedAt = Date().addingTimeInterval(-20)
        state.codexSessions = [
            // Long finished and long viewed: no row, and no number taken.
            CodexSessionSnapshot(id: "history", state: .completed, description: "d", lastActiveDate: finishedAt.addingTimeInterval(-3_600),
                                 completedAt: finishedAt.addingTimeInterval(-3_600)),
            CodexSessionSnapshot(id: "running", state: .running, description: "Codex：执行中", lastActiveDate: nil),
            CodexSessionSnapshot(id: "done", state: .completed, description: "Codex：已完成", lastActiveDate: finishedAt, completedAt: finishedAt),
        ]
        state.lastAcknowledgedDates["codex"] = finishedAt.addingTimeInterval(-1_800)
        state.codexState = .running

        let rows = state.displayedObservers.filter { $0.icon == "codex" }
        XCTAssertEqual(rows.map(\.name), ["Codex · 会话 1", "Codex · 会话 2"], "numbered from one, history takes no number")
        XCTAssertEqual(Set(rows.map(\.state)), [.running, .completed])
        XCTAssertEqual(Set(rows.map(\.id)), ["codex-session:running", "codex-session:done"])

        // Opening one finished conversation leaves the running one, and the
        // finished one's row goes away once it has been looked at.
        state.noteCodexConversationOpened("done")
        let after = state.displayedObservers.filter { $0.icon == "codex" }
        XCTAssertEqual(after.map(\.id), ["codex"], "one conversation left: the provider's own row")
        XCTAssertEqual(after.first?.state, .running)
    }
}
