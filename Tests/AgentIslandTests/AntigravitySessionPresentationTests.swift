import XCTest
@testable import AgentIsland

@MainActor
final class AntigravitySessionPresentationTests: XCTestCase {
    private func provider(_ id: String) -> AIObserverItem {
        AIObserverItem(id: id, name: id, icon: id, isEnabled: true, state: .running, description: "working")
    }

    private func session(_ id: String, _ state: AIState, detail: String? = nil) -> AntigravitySessionSnapshot {
        .init(id: id, state: state, description: "actual state", actionDetail: detail,
              pendingIdentity: nil, lastActiveDate: nil)
    }

    func testSessionsHaveStableDistinctRowsAndPreserveProviderOrder() {
        let providers = [provider("codex"), provider("antigravity"), provider("claude")]
        let first = session("ag:aaa", .awaitingInput, detail: "First")
        let second = session("ag:bbb", .running)
        let labels = [first.id: 1, second.id: 2]
        let rows = AppState.expandAntigravitySessions(providers, sessions: [second, first], feedback: [:], labels: labels)
        XCTAssertEqual(rows.map(\.id), ["codex", AppState.antigravitySessionPrefix + first.id,
                                       AppState.antigravitySessionPrefix + second.id, "claude"])
        XCTAssertEqual(rows[1].name, "Antigravity · 会话 1")
        XCTAssertEqual(rows[2].name, "Antigravity · 会话 2")
        XCTAssertEqual(rows[1].actionDetail, "First")
        XCTAssertEqual(rows[2].state, .running)
        XCTAssertFalse(rows[1].name.contains(first.id))
    }

    func testSessionFeedbackDoesNotMaskCompletedState() {
        let a = session("ag:aaa", .awaitingInput, detail: "Question")
        let b = session("ag:bbb", .completed)
        let rows = AppState.expandAntigravitySessions([provider("antigravity")], sessions: [a, b],
            feedback: [a.id: "正在验证", b.id: "旧错误"], labels: [a.id: 1, b.id: 2])
        XCTAssertEqual(rows.map(\.description), ["正在验证", "actual state"])
        XCTAssertEqual(rows.map(\.state), [.awaitingInput, .completed])
    }

    func testNoSessionsLeavesOriginalProviderUnchanged() {
        let original = provider("antigravity")
        XCTAssertEqual(AppState.expandAntigravitySessions([original], sessions: [], feedback: [:], labels: [:]), [original])
    }
}
