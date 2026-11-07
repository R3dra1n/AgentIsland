import XCTest
@testable import AgentIsland

/// The HUD showed one row per conversation ever opened: sessions the user had
/// already viewed stayed behind as grey rows, so it only ever grew. A
/// conversation now has a row only while there is something to look at.
@MainActor
final class SessionRowArrangementTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 6_000_000)

    func provider(_ id: String = "antigravity", name: String = "Antigravity") -> AIObserverItem {
        .init(id: id, name: name, icon: id, isEnabled: true, state: .idle, description: "待命中")
    }

    func ag(_ id: String, _ state: AIState, completedAgo: TimeInterval? = nil) -> AntigravitySessionSnapshot {
        .init(id: id, state: state, description: "d-\(id)", actionDetail: nil, pendingIdentity: nil,
              lastActiveDate: now, completedAt: completedAgo.map { now.addingTimeInterval(-$0) })
    }

    func claude(_ id: String, _ state: AIState, completedAgo: TimeInterval? = nil) -> ClaudeSessionSnapshot {
        .init(id: id, state: state, description: "d-\(id)", actionDetail: nil, lastActiveDate: now,
              completedAt: completedAgo.map { now.addingTimeInterval(-$0) })
    }

    func labels(_ ids: [String]) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($0.element, $0.offset + 1) })
    }

    func arrange(_ sessions: [AntigravitySessionSnapshot], acknowledged: [String: Date] = [:]) -> AppState.SessionRows {
        AppState.antigravityArrangement(provider(), sessions: sessions, feedback: [:],
                                        labels: labels(sessions.map(\.id)), acknowledged: acknowledged)
    }

    // The reported screen: two sessions already viewed, nothing happening.
    func testViewedAndIdleSessionsLeaveOnlyTheProviderIcon() {
        let sessions = [ag("a", .completed, completedAgo: 100), ag("b", .completed, completedAgo: 100), ag("c", .idle)]
        let result = arrange(sessions, acknowledged: ["a": now, "b": now])
        XCTAssertEqual(result.rows, [provider()])
        XCTAssertTrue(result.hidden.isEmpty)
        let claudeResult = AppState.claudeArrangement(provider("claude", name: "Claude"),
            sessions: [claude("a", .completed, completedAgo: 100), claude("b", .completed, completedAgo: 100)],
            labels: labels(["a", "b"]), acknowledged: ["a": now, "b": now])
        XCTAssertEqual(claudeResult.rows.map(\.id), ["claude"])
    }

    // Clicking a finished row marks it viewed, and the row goes away rather than
    // turning grey; viewing the last one returns to the single icon.
    func testViewingFinishedConversationsShrinksTheRowsOneByOne() {
        let sessions = [ag("a", .completed, completedAgo: 100), ag("b", .completed, completedAgo: 100)]
        XCTAssertEqual(arrange(sessions).rows.count, 2)
        XCTAssertEqual(arrange(sessions, acknowledged: ["a": now]).rows.count, 1)
        XCTAssertEqual(arrange(sessions, acknowledged: ["a": now, "b": now]).rows, [provider()])
    }

    // A lone conversation shows under the plain name, but keeps its own row id,
    // because an Antigravity reply is bound to that specific conversation.
    func testALoneAntigravityConversationKeepsItsRowAndItsReplyPath() {
        let rows = arrange([ag("a", .awaitingInput), ag("b", .completed, completedAgo: 100)],
                           acknowledged: ["b": now]).rows
        XCTAssertEqual(rows.map(\.id), [AppState.antigravitySessionPrefix + "a"])
        XCTAssertEqual(rows.first?.name, "Antigravity")
        XCTAssertEqual(rows.first?.state, .awaitingInput)
    }

    func testClaudeKeepsTheProviderRowUntilThereAreTwoToTell() {
        let one = AppState.claudeArrangement(provider("claude", name: "Claude"), sessions: [claude("a", .running)],
                                             labels: labels(["a"]), acknowledged: [:])
        XCTAssertEqual(one.rows.map(\.id), ["claude"])
        let two = AppState.claudeArrangement(provider("claude", name: "Claude"),
                                             sessions: [claude("a", .running), claude("b", .awaitingInput)],
                                             labels: labels(["a", "b"]), acknowledged: [:])
        XCTAssertEqual(two.rows.map(\.name), ["Claude · 会话 1", "Claude · 会话 2"])
    }

    // --- the cap ---

    func testUpToTheCapEveryConversationHasARow() {
        let sessions = (1...AppState.maximumRowsPerProvider).map { ag("s\($0)", .running) }
        let result = arrange(sessions)
        XCTAssertEqual(result.rows.count, AppState.maximumRowsPerProvider)
        XCTAssertTrue(result.hidden.isEmpty)
        XCTAssertFalse(result.rows.contains { $0.id.hasPrefix(AppState.overflowPrefix) })
    }

    // However many are open, the HUD stops growing: the cap plus one chip.
    func testBeyondTheCapTheRestFoldIntoOneChip() {
        let sessions = (1...8).map { ag("s\($0)", .running) }
        let result = arrange(sessions)
        XCTAssertEqual(result.rows.count, AppState.maximumRowsPerProvider + 1)
        XCTAssertEqual(result.hidden.count, 8 - AppState.maximumRowsPerProvider)
        let chip = try? XCTUnwrap(result.rows.last)
        XCTAssertEqual(chip?.id, AppState.overflowPrefix + "antigravity")
        XCTAssertEqual(chip?.name, "+5")
        XCTAssertEqual(chip?.icon, "antigravity")
    }

    // A conversation that needs the user must never be the one that gets hidden.
    func testTheMostPressingConversationsKeepTheirRowsAndTheChipTakesTheWorstHiddenState() {
        let sessions = [ag("s1", .completed, completedAgo: 5), ag("s2", .completed, completedAgo: 5),
                        ag("s3", .completed, completedAgo: 5), ag("s4", .awaitingInput), ag("s5", .running)]
        let result = arrange(sessions)
        let shownIDs = result.rows.filter { !$0.id.hasPrefix(AppState.overflowPrefix) }.map(\.id)
        XCTAssertTrue(shownIDs.contains(AppState.antigravitySessionPrefix + "s4"), "需操作的不能被折叠")
        XCTAssertTrue(shownIDs.contains(AppState.antigravitySessionPrefix + "s5"))
        XCTAssertEqual(result.hidden.count, 2)
        XCTAssertTrue(result.hidden.allSatisfy { $0.state == .completed })
        XCTAssertEqual(result.rows.last?.state, .completed)
    }

    func testTheChipIsRedWhenWhatItHidesNeedsTheUser() {
        // Four need attention and the cap is three, so one is hidden; make the
        // hidden one the least pressing and then the most.
        let calm = [ag("a", .awaitingInput), ag("b", .awaitingInput), ag("c", .awaitingInput), ag("d", .running)]
        XCTAssertEqual(arrange(calm).rows.last?.state, .running)
        let urgent = [ag("a", .awaitingInput), ag("b", .awaitingInput), ag("c", .awaitingInput), ag("d", .awaitingInput)]
        XCTAssertEqual(arrange(urgent).rows.last?.state, .awaitingInput)
    }

    // Rows stay where they are as states change; only which ones survive is
    // decided by urgency.
    func testShownRowsKeepTheirStableOrder() {
        let sessions = [ag("s1", .running), ag("s2", .awaitingInput), ag("s3", .running), ag("s4", .awaitingInput), ag("s5", .running)]
        let shown = arrange(sessions).rows.filter { !$0.id.hasPrefix(AppState.overflowPrefix) }.map(\.id)
        let order = shown.compactMap { id in sessions.firstIndex { AppState.antigravitySessionPrefix + $0.id == id } }
        XCTAssertEqual(order, order.sorted())
    }

    // Viewed conversations are history: they do not count toward the cap, so they
    // can neither take a row nor push a live one into the chip.
    func testViewedConversationsDoNotCountTowardTheCap() {
        var sessions = (1...3).map { ag("live\($0)", .running) }
        sessions += (1...5).map { ag("old\($0)", .completed, completedAgo: 100) }
        var acknowledged: [String: Date] = [:]
        for index in 1...5 { acknowledged["old\(index)"] = now }
        let result = arrange(sessions, acknowledged: acknowledged)
        XCTAssertEqual(result.rows.count, 3)
        XCTAssertTrue(result.hidden.isEmpty)
    }

    func testTheChipInheritsTheProviderEnabledFlagAndNeedsAttentionRules() {
        var disabled = provider(); disabled.isEnabled = false
        let sessions = (1...5).map { ag("s\($0)", .running) }
        let result = AppState.antigravityArrangement(disabled, sessions: sessions, feedback: [:],
                                                     labels: labels(sessions.map(\.id)), acknowledged: [:])
        XCTAssertEqual(result.rows.last?.isEnabled, false)
        XCTAssertFalse(AppState.needsAttention(.idle))
        XCTAssertFalse(AppState.needsAttention(.unknown))
        for state in [AIState.awaitingInput, .running, .completed, .failed, .interrupted] {
            XCTAssertTrue(AppState.needsAttention(state), "\(state)")
        }
    }

    func testViewMarkSurvivesTheHostRewritingTheFileJustAfter() {
        let finished = Date(timeIntervalSince1970: 1_000_000)
        // Marked 7 s before the host touched the file: still viewed.
        XCTAssertTrue(AppState.viewMarkCovers(acknowledgedAt: finished.addingTimeInterval(-7), finishedAt: finished))
        XCTAssertTrue(AppState.viewMarkCovers(acknowledgedAt: finished.addingTimeInterval(1), finishedAt: finished))
        // A conversation that finished well after the mark is new again.
        XCTAssertFalse(AppState.viewMarkCovers(acknowledgedAt: finished.addingTimeInterval(-120), finishedAt: finished))
        XCTAssertFalse(AppState.viewMarkCovers(acknowledgedAt: nil, finishedAt: finished))
    }
}
