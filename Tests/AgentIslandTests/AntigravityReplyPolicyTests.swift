import XCTest
@testable import AgentIsland

final class AntigravityReplyPolicyTests: XCTestCase {
    func testOnlyExplicitOptionsFromOneQuestionCanUseNumericPath() {
        let detail = "❓ Choose\n   [1] First\n   [2] Second"
        XCTAssertTrue(AntigravityReplyPolicy.permitsNumericReply("1", prefixKey: nil, pendingSessions: 1, detail: detail))
        XCTAssertFalse(AntigravityReplyPolicy.permitsNumericReply("3", prefixKey: nil, pendingSessions: 1, detail: detail))
        XCTAssertFalse(AntigravityReplyPolicy.permitsNumericReply("1", prefixKey: nil, pendingSessions: 2, detail: detail))
        XCTAssertFalse(AntigravityReplyPolicy.permitsNumericReply("1", prefixKey: "2", pendingSessions: 1, detail: detail))
        XCTAssertFalse(AntigravityReplyPolicy.permitsNumericReply("hello", prefixKey: nil, pendingSessions: 1, detail: detail))
        XCTAssertFalse(AntigravityReplyPolicy.permitsNumericReply("1", prefixKey: nil, pendingSessions: 1, detail: nil))
    }

    func testQueuedReplyRejectsChangedOrMissingQuestion() {
        let original = "❓ Original\n   [1] First"
        let other = "❓ Different question\n   [1] First"
        let first = AntigravityPendingIdentity(transcript: URL(fileURLWithPath: "/a"), fileID: 1, changedAt: .distantPast)
        let second = AntigravityPendingIdentity(transcript: URL(fileURLWithPath: "/b"), fileID: 2, changedAt: .distantPast)
        XCTAssertTrue(AntigravityReplyPolicy.permitsQueuedReply("1", prefixKey: nil, pendingSessions: 1, expectedDetail: original, currentDetail: original, expectedIdentity: first, currentIdentity: first))
        XCTAssertFalse(AntigravityReplyPolicy.permitsQueuedReply("1", prefixKey: nil, pendingSessions: 1, expectedDetail: original, currentDetail: other, expectedIdentity: first, currentIdentity: first))
        XCTAssertFalse(AntigravityReplyPolicy.permitsQueuedReply("1", prefixKey: nil, pendingSessions: 1, expectedDetail: nil, currentDetail: original, expectedIdentity: first, currentIdentity: first))
        XCTAssertFalse(AntigravityReplyPolicy.permitsQueuedReply("1", prefixKey: nil, pendingSessions: 2, expectedDetail: original, currentDetail: original, expectedIdentity: first, currentIdentity: first))
        XCTAssertFalse(AntigravityReplyPolicy.permitsQueuedReply("1", prefixKey: nil, pendingSessions: 1, expectedDetail: original, currentDetail: original, expectedIdentity: first, currentIdentity: second))
        XCTAssertFalse(AntigravityReplyPolicy.permitsQueuedReply("1", prefixKey: nil, pendingSessions: 1, expectedDetail: original, currentDetail: original, expectedIdentity: nil, currentIdentity: first))
    }
}
