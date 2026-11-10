import XCTest
import Darwin
@testable import AgentIsland

/// The island's half of answering Claude's multiple-choice question: reading what
/// the hook helper wrote, and writing the user's click back, without ever trusting
/// a file somebody else could have made.
final class ClaudeAnswerStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("answers-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: root.appendingPathComponent("requests"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func writeRequest(id: String = "toolu_1", session: String = "s1", question: String = "Which framework?",
                              options: [[String: Any]]? = nil, created: Date = Date(), mode: mode_t = 0o600,
                              extra: [String: Any] = [:]) throws {
        var body: [String: Any] = ["session_id": session, "question": question, "created_at": created.timeIntervalSince1970,
                                   "options": options ?? [["label": "React", "description": "UI library"], ["label": "Vue"]]]
        body.merge(extra) { $1 }
        let url = root.appendingPathComponent("requests/\(id).json")
        try JSONSerialization.data(withJSONObject: body).write(to: url)
        chmod(url.path, mode)
    }

    func testAValidRequestIsRead() throws {
        try writeRequest(extra: ["header": "Framework"])
        let found = ClaudeAnswerStore.pending(directory: root)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.id, "toolu_1")
        XCTAssertEqual(found.first?.sessionID, "s1")
        XCTAssertEqual(found.first?.question, "Which framework?")
        XCTAssertEqual(found.first?.header, "Framework")
        XCTAssertEqual(found.first?.options, [.init(label: "React", description: "UI library"), .init(label: "Vue", description: nil)])
    }

    func testRequestsComeOldestFirst() throws {
        try writeRequest(id: "b", created: Date().addingTimeInterval(-3))
        try writeRequest(id: "a", created: Date().addingTimeInterval(-9))
        XCTAssertEqual(ClaudeAnswerStore.pending(directory: root).map(\.id), ["a", "b"])
    }

    func testARequestThatHasExpiredIsNotShown() throws {
        try writeRequest(created: Date().addingTimeInterval(-ClaudeAnswerStore.requestFreshness - 5))
        XCTAssertTrue(ClaudeAnswerStore.pending(directory: root).isEmpty, "the helper has given up on it, so a click would go nowhere")
    }

    func testFilesOthersCouldHaveMadeAreNotTrusted() throws {
        try writeRequest(id: "open", mode: 0o666)
        try writeRequest(id: "empty-options", options: [])
        try writeRequest(id: "blank-label", options: [["label": ""]])
        try writeRequest(id: "half-bad", options: [["label": "ok"], ["nolabel": 1]])
        try Data("not json".utf8).write(to: root.appendingPathComponent("requests/junk.json"))
        try writeRequest(id: "has space")
        try writeRequest(id: ".hidden")
        let outside = root.appendingPathComponent("outside.json")
        try JSONSerialization.data(withJSONObject: ["session_id": "s", "question": "q", "created_at": Date().timeIntervalSince1970,
                                                    "options": [["label": "x"]]]).write(to: outside)
        chmod(outside.path, 0o600)
        symlink(outside.path, root.appendingPathComponent("requests/linked.json").path)
        XCTAssertEqual(ClaudeAnswerStore.pending(directory: root).map(\.id), [])
    }

    func testAnUnsafeDirectoryShowsNothing() throws {
        try writeRequest()
        chmod(root.path, 0o777)
        XCTAssertTrue(ClaudeAnswerStore.pending(directory: root).isEmpty)
        chmod(root.path, 0o700)
        chmod(root.appendingPathComponent("requests").path, 0o770)
        XCTAssertTrue(ClaudeAnswerStore.pending(directory: root).isEmpty)
    }

    // MARK: answering

    func testAnAnswerNamesTheChosenOptionAndNothingElse() throws {
        try writeRequest()
        let request = try XCTUnwrap(ClaudeAnswerStore.pending(directory: root).first)
        try ClaudeAnswerStore.answer(request, optionIndex: 1, directory: root)
        let file = root.appendingPathComponent("responses/toolu_1.json")
        var info = stat(); XCTAssertEqual(lstat(file.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o600, "only the user can read or change it")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(body["label"] as? String, "Vue")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("responses").path)
        XCTAssertEqual(leftovers, ["toolu_1.json"], "no half-written file is left behind")
    }

    func testAnOptionThatWasNotOfferedCannotBeChosen() throws {
        try writeRequest()
        let request = try XCTUnwrap(ClaudeAnswerStore.pending(directory: root).first)
        XCTAssertThrowsError(try ClaudeAnswerStore.answer(request, optionIndex: 2, directory: root))
        XCTAssertThrowsError(try ClaudeAnswerStore.answer(request, optionIndex: -1, directory: root))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("responses/toolu_1.json").path))
    }

    func testAnIdThatCouldEscapeTheDirectoryIsRefused() {
        let evil = ClaudeAnswerRequest(id: "../../evil", sessionID: "s", question: "q", header: nil,
                                       options: [.init(label: "x", description: nil)], createdAt: Date())
        XCTAssertThrowsError(try ClaudeAnswerStore.answer(evil, optionIndex: 0, directory: root))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.deletingLastPathComponent().appendingPathComponent("evil.json").path))
    }

    func testAnUnsafeDirectoryIsNotWrittenTo() throws {
        try writeRequest()
        let request = try XCTUnwrap(ClaudeAnswerStore.pending(directory: root).first)
        chmod(root.path, 0o777)
        XCTAssertThrowsError(try ClaudeAnswerStore.answer(request, optionIndex: 0, directory: root))
    }

    // MARK: heartbeat

    func testTheHeartbeatSaysTheIslandIsRunningUntilItIsRemoved() throws {
        let ready = root.appendingPathComponent("ready")
        XCTAssertTrue(ClaudeAnswerStore.touchHeartbeat(directory: root))
        XCTAssertTrue(FileManager.default.fileExists(atPath: ready.path))

        let past = Date().addingTimeInterval(-60)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: ready.path)
        XCTAssertTrue(ClaudeAnswerStore.touchHeartbeat(directory: root))
        let touched = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: ready.path)[.modificationDate] as? Date)
        XCTAssertGreaterThan(touched.timeIntervalSinceNow, -5, "a beat refreshes the file the helper checks")

        ClaudeAnswerStore.removeHeartbeat(directory: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ready.path))
    }

    func testTheHeartbeatDoesNotFollowALink() throws {
        let target = root.appendingPathComponent("elsewhere")
        try Data().write(to: target)
        symlink(target.path, root.appendingPathComponent("ready").path)
        XCTAssertFalse(ClaudeAnswerStore.touchHeartbeat(directory: root))
    }
}

/// Which row a question belongs to, and what a click does to the state.
@MainActor
final class ClaudeAnswerStateTests: XCTestCase {
    private var root: URL!
    private var state: AppState!

    override func setUp() async throws {
        _ = NSApplication.shared
        root = FileManager.default.temporaryDirectory.appendingPathComponent("answers-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("requests"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        chmod(root.path, 0o700)
        state = AppState()
        [state.codexObserver as any AIObserverProtocol, state.antigravityObserver, state.claudeObserver,
         state.cursorObserver, state.windsurfObserver, state.traeObserver].forEach { $0.stopObserving() }
        state.claudeAnswerDirectory = root
    }

    override func tearDown() async throws {
        state.stopClaudeAnswering()
        try? FileManager.default.removeItem(at: root)
    }

    private func request(id: String = "toolu_1", session: String = "s1", question: String = "Which framework?") -> ClaudeAnswerRequest {
        ClaudeAnswerRequest(id: id, sessionID: session, question: question, header: nil,
                            options: [.init(label: "React", description: nil), .init(label: "Vue", description: nil)], createdAt: Date())
    }

    private func row(id: String, state: AIState = .awaitingInput, icon: String = "claude", question: String = "Which framework?") -> AIObserverItem {
        AIObserverItem(id: id, name: "Claude", icon: icon, isEnabled: true, state: state, description: "等待回答提问",
                       actionDetail: "❓ \(question)\n   [1] React\n   [2] Vue")
    }

    func testAConversationsRowTakesOnlyItsOwnConversationsQuestion() {
        state.claudeAnswerRequests = [request(session: "s1"), request(id: "toolu_2", session: "s2")]
        XCTAssertEqual(state.claudeAnswerRequest(forRow: row(id: "claude-session:s2"))?.id, "toolu_2")
        XCTAssertEqual(state.claudeAnswerRequest(forRow: row(id: "claude-session:s1"))?.id, "toolu_1")
        XCTAssertNil(state.claudeAnswerRequest(forRow: row(id: "claude-session:s3")), "another conversation's question is not this row's")
    }

    func testTheFoldedRowTakesTheQuestionItIsShowing() {
        state.claudeAnswerRequests = [request(question: "Which bundler?"), request(id: "toolu_2", question: "Which framework?")]
        XCTAssertEqual(state.claudeAnswerRequest(forRow: row(id: "claude"))?.id, "toolu_2")
    }

    func testAQuestionTheRowIsNotShowingIsNotOffered() {
        state.claudeAnswerRequests = [request(question: "Something else?")]
        XCTAssertNil(state.claudeAnswerRequest(forRow: row(id: "claude-session:s1")),
                     "the buttons must belong to the question on the row, or a click answers a different one")
    }

    func testOnlyAWaitingClaudeRowGetsAnswerButtons() {
        state.claudeAnswerRequests = [request()]
        XCTAssertNil(state.claudeAnswerRequest(forRow: row(id: "claude-session:s1", state: .running)))
        XCTAssertNil(state.claudeAnswerRequest(forRow: row(id: "claude-session:s1", state: .completed)))
        XCTAssertNil(state.claudeAnswerRequest(forRow: row(id: "codex", icon: "codex")))
        XCTAssertNil(state.claudeAnswerRequest(forRow: row(id: "antigravity-session:s1", icon: "antigravity")))
    }

    func testAClickWritesTheAnswerOnceAndHidesTheQuestion() throws {
        let pending = request()
        state.claudeAnswerRequests = [pending]
        state.answerClaude(pending, optionIndex: 1)
        XCTAssertTrue(state.claudeAnswerRequests.isEmpty)
        let file = root.appendingPathComponent("responses/toolu_1.json")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(body["label"] as? String, "Vue")

        // A second click, or a stale view of the same question, must not send another.
        try FileManager.default.removeItem(at: file)
        state.claudeAnswerRequests = [pending]
        state.answerClaude(pending, optionIndex: 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testAnAnsweredQuestionStaysHiddenWhileItsFileIsStillThere() throws {
        let body: [String: Any] = ["session_id": "s1", "question": "Which framework?", "created_at": Date().timeIntervalSince1970,
                                   "options": [["label": "React"], ["label": "Vue"]]]
        let file = root.appendingPathComponent("requests/toolu_1.json")
        try JSONSerialization.data(withJSONObject: body).write(to: file); chmod(file.path, 0o600)
        state.refreshClaudeAnswerRequests()
        let shown = try XCTUnwrap(state.claudeAnswerRequests.first)
        state.answerClaude(shown, optionIndex: 0)
        state.refreshClaudeAnswerRequests()
        XCTAssertTrue(state.claudeAnswerRequests.isEmpty, "the helper has not cleaned up yet, but it is answered")
        try FileManager.default.removeItem(at: file)
        state.refreshClaudeAnswerRequests()
        XCTAssertTrue(state.claudeAnsweredRequestIDs.isEmpty, "forgotten once the file is gone")
    }

    func testTheHelperIsOnlyToldTheIslandIsHereWhileClaudeIsSwitchedOn() {
        let ready = root.appendingPathComponent("ready")
        state.claudeEnabled = true
        [state.claudeObserver as any AIObserverProtocol].forEach { $0.stopObserving() }
        state.tickClaudeAnswering()
        XCTAssertTrue(FileManager.default.fileExists(atPath: ready.path))
        state.claudeEnabled = false
        state.tickClaudeAnswering()
        XCTAssertFalse(FileManager.default.fileExists(atPath: ready.path), "with Claude off nobody is there to click")
    }

    func testTheHelperIsNotToldAnythingInTheDemo() {
        state.claudeEnabled = true
        [state.claudeObserver as any AIObserverProtocol].forEach { $0.stopObserving() }
        state.testModeActive = true
        state.tickClaudeAnswering()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("ready").path))
    }
}
