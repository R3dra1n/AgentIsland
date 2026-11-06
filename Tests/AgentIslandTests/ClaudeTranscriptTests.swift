import XCTest
@testable import AgentIsland

/// Record shapes follow Claude Code's session transcript; all content here is
/// synthetic. The previous implementation emitted a fixed placeholder string,
/// so the real question text never reached the HUD.
final class ClaudeTranscriptTests: XCTestCase {
    func assistant(_ blocks: [[String: Any]], type: String = "assistant") -> [String: Any] {
        ["type": type, "message": ["role": "assistant", "content": blocks]]
    }

    func user(_ blocks: [[String: Any]], type: String = "user") -> [String: Any] {
        ["type": type, "message": ["role": "user", "content": blocks]]
    }

    func toolUse(_ id: String, _ name: String, _ input: [String: Any]) -> [String: Any] {
        ["type": "tool_use", "id": id, "name": name, "input": input]
    }

    func toolResult(_ id: String) -> [String: Any] {
        ["type": "tool_result", "tool_use_id": id, "content": "ok"]
    }

    func askQuestion(_ question: String, options: [String], multiSelect: Bool = false) -> [String: Any] {
        ["questions": [["question": question, "header": "标题", "multiSelect": multiSelect,
                        "options": options.map { ["label": $0, "description": "说明"] }]]]
    }

    // The reported defect: options showed up but the question text did not.
    func testSingleQuestionRendersRealQuestionAndSelectableOptions() throws {
        let input = askQuestion("要先修哪一个？", options: ["历史问题", "执行中状态"])
        let detail = try XCTUnwrap(ClaudeTranscript.questionDetail(input))
        XCTAssertEqual(detail, """
        ❓ 要先修哪一个？
           [1] 历史问题
           [2] 执行中状态
        """)
        // The panel turns "   [n] " lines into replies and shows the first
        // line as the summary, so the question must lead.
        XCTAssertTrue(detail.hasPrefix("❓ 要先修哪一个？"))
    }

    // A single choice cannot answer a multi-select question, so no reply
    // affordance may be offered for one.
    func testMultiSelectQuestionListsOptionsWithoutReplyAffordance() throws {
        let detail = try XCTUnwrap(ClaudeTranscript.questionDetail(
            askQuestion("选择要启用的功能", options: ["A", "B"], multiSelect: true)))
        XCTAssertTrue(detail.contains("❓ 选择要启用的功能"))
        XCTAssertFalse(detail.contains("   [1] "), "可多选时不得产生单选回覆项")
        XCTAssertTrue(detail.contains("   • A"))
        XCTAssertTrue(detail.contains("请在 Claude Code 中回答"))
    }

    func testSeveralQuestionsInOneCallAreShownButNotAnswerable() throws {
        let input: [String: Any] = ["questions": [
            ["question": "第一个问题", "options": [["label": "A"]]],
            ["question": "第二个问题", "options": [["label": "B"]]]
        ]]
        let detail = try XCTUnwrap(ClaudeTranscript.questionDetail(input))
        XCTAssertTrue(detail.contains("❓ 第一个问题"))
        XCTAssertTrue(detail.contains("❓ 第二个问题"))
        XCTAssertFalse(detail.contains("   [1] "), "多个问题时单一数字回覆是歧义的")
    }

    func testOptionsMayAlsoBePlainStrings() throws {
        let input: [String: Any] = ["questions": [["question": "问题", "options": ["甲", "乙"]]]]
        let detail = try XCTUnwrap(ClaudeTranscript.questionDetail(input))
        XCTAssertTrue(detail.contains("   [1] 甲"))
        XCTAssertTrue(detail.contains("   [2] 乙"))
    }

    func testQuestionWithoutUsableTextProducesNoDetail() {
        XCTAssertNil(ClaudeTranscript.questionDetail([:]))
        XCTAssertNil(ClaudeTranscript.questionDetail(["questions": []]))
        XCTAssertNil(ClaudeTranscript.questionDetail(["questions": [["question": "   "]]]))
    }

    func testUnansweredQuestionIsPendingAndAnsweredOneIsNot() {
        let waiting = [assistant([toolUse("t1", "AskUserQuestion", askQuestion("问题", options: ["A"]))])]
        XCTAssertEqual(ClaudeTranscript.pendingTools(waiting).map(\.name), ["AskUserQuestion"])

        let answered = waiting + [user([toolResult("t1")])]
        XCTAssertTrue(ClaudeTranscript.pendingTools(answered).isEmpty)
    }

    // `api-request-*` records replay the entire conversation. Consuming them
    // resurrects tool calls that were answered long ago; against a real
    // transcript that produced 24 phantom pending calls on an idle session.
    func testReplayedRequestRecordsDoNotResurrectAnsweredTools() {
        let records = [
            assistant([toolUse("t1", "Bash", ["command": "echo hi"])]),
            user([toolResult("t1")]),
            // The replay repeats the tool call without its result.
            assistant([toolUse("t1", "Bash", ["command": "echo hi"])], type: "api-request-blob"),
            assistant([toolUse("t2", "Edit", ["file_path": "/tmp/a.swift"])], type: "api-request")
        ]
        XCTAssertTrue(ClaudeTranscript.pendingTools(records).isEmpty,
                      "只有 assistant/user 记录是真正的对话，重放记录不得产生待处理项")
    }

    func testPendingToolsKeepFileOrderAndLatestWins() {
        let records = [
            assistant([toolUse("t1", "Bash", ["command": "sleep 1"])]),
            assistant([toolUse("t2", "AskUserQuestion", askQuestion("问题", options: ["A"]))])
        ]
        XCTAssertEqual(ClaudeTranscript.pendingTools(records).map(\.id), ["t1", "t2"])
    }

    func testActivityDetailShowsRealCommandAndFile() throws {
        let bash = ClaudeTranscript.PendingTool(id: "t", name: "Bash",
            input: ["command": "swift test --filter Codex", "description": "跑测试"])
        let detail = try XCTUnwrap(ClaudeTranscript.activityDetail(bash))
        XCTAssertTrue(detail.hasPrefix("🖥 执行命令: swift test --filter Codex"))
        XCTAssertTrue(detail.contains("跑测试"))

        let edit = ClaudeTranscript.PendingTool(id: "t", name: "Edit",
            input: ["file_path": "/tmp/project/Sources/Thing.swift"])
        XCTAssertEqual(ClaudeTranscript.activityDetail(edit), "📝 修改 Thing.swift")

        let unknown = ClaudeTranscript.PendingTool(id: "t", name: "SomeTool", input: [:])
        XCTAssertEqual(ClaudeTranscript.activityDetail(unknown), "🔧 SomeTool")
    }

    func testMultilineCommandIsFlattenedAndBounded() throws {
        let long = String(repeating: "x", count: 500)
        let bash = ClaudeTranscript.PendingTool(id: "t", name: "Bash",
            input: ["command": "line one\n\n   line two " + long])
        let detail = try XCTUnwrap(ClaudeTranscript.activityDetail(bash))
        XCTAssertFalse(detail.contains("\n\n"))
        XCTAssertTrue(detail.contains("line one line two"))
        XCTAssertTrue(detail.hasSuffix("…"))
    }

    // Regression: a typed user message carries a plain string rather than a
    // block list. Skipping it credited an earlier assistant turn, so sending a
    // new prompt made the HUD jump straight to 已完成.
    func testTypedUserMessageWithStringContentEndsTheSearch() {
        let records: [[String: Any]] = [
            assistant([["type": "text", "text": "上一轮说完了"]]),
            ["type": "user", "message": ["role": "user", "content": "继续做下一件事"]]
        ]
        XCTAssertFalse(ClaudeTranscript.endsWithAssistantText(records),
                       "使用者刚送出讯息时不得判为已完成")
    }

    // Regression: the assistant's text and its tool call are separate records,
    // so a text-only record mid-turn is not the end of the turn.
    func testAssistantTextRecordAloneIsNotProofTheTurnEnded() {
        // This is the shape seen between the two records; the caller must also
        // require the transcript to have gone quiet.
        let records = [assistant([["type": "thinking", "thinking": "…"]]),
                       assistant([["type": "text", "text": "先跑个测试"]])]
        XCTAssertTrue(ClaudeTranscript.endsWithAssistantText(records))
        // Once the tool call lands it is unambiguous again.
        let withCall = records + [assistant([toolUse("t1", "Bash", ["command": "ls"])])]
        XCTAssertFalse(ClaudeTranscript.endsWithAssistantText(withCall))
    }

    func testUserToolResultAlsoEndsTheSearch() {
        let records = [assistant([["type": "text", "text": "完成"]]), user([toolResult("t1")])]
        XCTAssertFalse(ClaudeTranscript.endsWithAssistantText(records))
    }

    func testAssistantTextEndsTurnButToolCallDoesNot() {
        XCTAssertTrue(ClaudeTranscript.endsWithAssistantText([assistant([["type": "text", "text": "完成了"]])]))
        XCTAssertFalse(ClaudeTranscript.endsWithAssistantText([
            assistant([["type": "text", "text": "先跑个测试"], toolUse("t1", "Bash", ["command": "ls"])])]))
        XCTAssertFalse(ClaudeTranscript.endsWithAssistantText([user([["type": "text", "text": "继续"]])]))
        // A trailing replay record must not decide the turn either.
        XCTAssertTrue(ClaudeTranscript.endsWithAssistantText([
            assistant([["type": "text", "text": "完成了"]]),
            assistant([toolUse("t9", "Bash", ["command": "ls"])], type: "api-request-blob")]))
    }
}
