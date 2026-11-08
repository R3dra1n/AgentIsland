import XCTest
@testable import AgentIsland

final class ClaudeOpenLinkTests: XCTestCase {
    private func makeRoot(_ files: [(name: String, json: [String: Any])]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("claude-sessions-\(UUID().uuidString)")
        let org = root.appendingPathComponent("account/org", isDirectory: true)
        try FileManager.default.createDirectory(at: org, withIntermediateDirectories: true)
        for file in files {
            try JSONSerialization.data(withJSONObject: file.json).write(to: org.appendingPathComponent(file.name))
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testFindsTheDesktopIDThroughTheCLISessionID() throws {
        let root = try makeRoot([
            ("local_aaa.json", ["sessionId": "local_aaa", "cliSessionId": "cli-1", "lastActivityAt": 10.0]),
            ("local_bbb.json", ["sessionId": "local_bbb", "cliSessionId": "cli-2", "lastActivityAt": 20.0]),
        ])
        XCTAssertEqual(AppState.claudeDesktopSessionID(forTranscript: "cli-2", root: root), "local_bbb")
        XCTAssertNil(AppState.claudeDesktopSessionID(forTranscript: "cli-3", root: root))
    }

    func testSkipsArchivedAndPrefersTheMostRecentlyActive() throws {
        let root = try makeRoot([
            ("local_old.json", ["sessionId": "local_old", "cliSessionId": "cli-1", "lastActivityAt": 10.0]),
            ("local_new.json", ["sessionId": "local_new", "cliSessionId": "cli-1", "lastActivityAt": 99.0]),
            ("local_gone.json", ["sessionId": "local_gone", "cliSessionId": "cli-1", "lastActivityAt": 500.0, "isArchived": true]),
        ])
        XCTAssertEqual(AppState.claudeDesktopSessionID(forTranscript: "cli-1", root: root), "local_new")
    }

    func testNeverPutsAnUnexpectedIDInALink() throws {
        let root = try makeRoot([("local_x.json", ["sessionId": "local_x&evil=1", "cliSessionId": "cli-1"])])
        XCTAssertNil(AppState.claudeDesktopSessionID(forTranscript: "cli-1", root: root))
        XCTAssertNil(AppState.claudeDeepLink(target: .desktopApp, desktopSessionID: "local_x&evil=1"))
        XCTAssertFalse(AppState.isDesktopSessionID("local_"))
        XCTAssertTrue(AppState.isDesktopSessionID("local_4a7e0e59-30f1-4cf2-9425-ddf96bd85341"))
    }

    func testMissingFolderIsNotAnError() {
        let nowhere = FileManager.default.temporaryDirectory.appendingPathComponent("nope-\(UUID().uuidString)")
        XCTAssertNil(AppState.claudeDesktopSessionID(forTranscript: "cli-1", root: nowhere))
    }

    func testLinksGoToTheConversationWhenItIsKnown() {
        XCTAssertEqual(AppState.claudeDeepLink(target: .desktopApp, desktopSessionID: "local_a")?.absoluteString,
                       "claude://code/continue?session=local_a&source=desktop_action")
        XCTAssertEqual(AppState.claudeDeepLink(target: .desktopNeedsInput, desktopSessionID: "local_a")?.absoluteString,
                       "claude://code/needs-input?session=local_a&source=desktop_action")
    }

    func testWithoutAKnownConversationOnlyAWaitingOneIsAskedFor() {
        XCTAssertEqual(AppState.claudeDeepLink(target: .desktopNeedsInput, desktopSessionID: nil)?.absoluteString,
                       "claude://code/needs-input?source=desktop_action")
        XCTAssertNil(AppState.claudeDeepLink(target: .desktopApp, desktopSessionID: nil))
        XCTAssertNil(AppState.claudeDeepLink(target: .terminal, desktopSessionID: "local_a"))
    }
}
