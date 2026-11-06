import Foundation

/// Parsing of Claude Code's session transcript, kept separate from file access
/// so the real record shapes can be tested without a running assistant.
///
/// The transcript is JSON Lines. Every record carries a `type`, and only
/// `assistant` and `user` records are the conversation itself: `api-request-*`
/// records replay the whole message history on each request, so consuming them
/// resurrects tool calls that were answered long ago.
enum ClaudeTranscript {
    static let conversationRecordTypes: Set<String> = ["assistant", "user"]
    /// The tool that asks the user a structured question. An unanswered one is
    /// the only unambiguous "waiting for the user" signal in the transcript.
    static let questionToolName = "AskUserQuestion"
    /// Without the `Stop` hook, a turn is only called finished once the
    /// transcript has been quiet this long: the assistant writes its text and
    /// its tool call as separate records, and the gap between them is
    /// indistinguishable from the end of a turn.
    static let quietTurnEnd: TimeInterval = 3
    private static let maximumDetail = 4000

    /// A tool call that has no matching `tool_result` yet.
    struct PendingTool {
        let id: String
        let name: String
        let input: [String: Any]
    }

    /// Tool calls still awaiting a result, oldest first. Records must be in
    /// file order; later `tool_result` blocks cancel earlier `tool_use` blocks.
    static func pendingTools(_ records: [[String: Any]]) -> [PendingTool] {
        var pending: [String: PendingTool] = [:]
        var order: [String] = []
        for record in records {
            guard conversationRecordTypes.contains(record["type"] as? String ?? ""),
                  let message = record["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { continue }
            for block in content {
                switch block["type"] as? String {
                case "tool_use":
                    guard let id = block["id"] as? String, !id.isEmpty,
                          let name = block["name"] as? String else { continue }
                    if pending[id] == nil { order.append(id) }
                    pending[id] = PendingTool(id: id, name: name, input: block["input"] as? [String: Any] ?? [:])
                case "tool_result":
                    if let id = block["tool_use_id"] as? String { pending.removeValue(forKey: id) }
                default:
                    continue
                }
            }
        }
        return order.compactMap { pending[$0] }
    }

    /// True when the last thing in the conversation is the assistant speaking
    /// without calling a tool.
    ///
    /// This is a weak end-of-turn signal and must not be used on its own: the
    /// assistant writes its text and its tool call as *separate* records, so
    /// between them the transcript looks exactly like a finished turn. The
    /// `Stop` hook event is the authoritative signal; this only backs it up
    /// when the hook is not installed, and the caller additionally requires
    /// the transcript to have gone quiet first.
    /// Where the conversation runs ("claude-desktop", "cli", ...), as the
    /// transcript records it. The newest value wins: a session can be resumed
    /// from a different host.
    static func entrypoint(_ records: [[String: Any]]) -> String? {
        for record in records.reversed() {
            if let value = record["entrypoint"] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    static func endsWithAssistantText(_ records: [[String: Any]]) -> Bool {
        for record in records.reversed() {
            guard conversationRecordTypes.contains(record["type"] as? String ?? ""),
                  // A subagent's own turns are interleaved in the same file and
                  // say nothing about whether the main conversation finished.
                  record["isSidechain"] as? Bool != true,
                  let message = record["message"] as? [String: Any] else { continue }
            // A user record ends the search whatever shape its content has:
            // a typed message carries a plain string rather than a block list,
            // and skipping it would wrongly credit an earlier assistant turn.
            guard message["role"] as? String == "assistant" else { return false }
            guard let content = message["content"] as? [[String: Any]], !content.isEmpty else { continue }
            return content.contains { $0["type"] as? String == "text" }
                && !content.contains { $0["type"] as? String == "tool_use" }
        }
        return false
    }

    /// Renders the real question and its real options in the shared HUD format:
    /// a `❓` title line, then `   [n] ` lines that the panel turns into
    /// selectable replies. A multi-select question, or several questions in one
    /// call, cannot be answered by a single choice, so those options are listed
    /// as plain bullets and no reply affordance is offered.
    static func questionDetail(_ input: [String: Any]) -> String? {
        guard let questions = input["questions"] as? [[String: Any]], !questions.isEmpty else { return nil }
        let singleChoice = questions.count == 1 && !(questions[0]["multiSelect"] as? Bool ?? false)
        var lines: [String] = []
        for question in questions {
            let text = (question["question"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            lines.append("❓ " + text)
            for (index, label) in labels(question["options"]).enumerated() {
                lines.append(singleChoice ? "   [\(index + 1)] \(label)" : "   • \(label)")
            }
        }
        guard !lines.isEmpty else { return nil }
        if !singleChoice { lines.append("   （多个问题或可多选，请在 Claude Code 中回答）") }
        return clamp(lines.joined(separator: "\n"))
    }

    /// Options are objects carrying a `label`, but tolerate a plain string list.
    private static func labels(_ value: Any?) -> [String] {
        if let objects = value as? [[String: Any]] {
            return objects.compactMap { $0["label"] as? String }.filter { !$0.isEmpty }
        }
        return (value as? [String] ?? []).filter { !$0.isEmpty }
    }

    /// Transcript records average a few KB and a single one can exceed 100 KB,
    /// so a small tail can land inside one record and decode nothing. Read a
    /// bounded window, drop the leading partial line, and keep whole records.
    static func readRecords(of fileURL: URL, bytes: Int = 512 * 1024) -> [[String: Any]] {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return [] }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return [] }
        let offset = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        guard (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.readToEnd() else { return [] }
        var lines = data.split(separator: 0x0a, omittingEmptySubsequences: true)
        // The first line is only complete when the read started at the file head.
        if offset > 0, !lines.isEmpty { lines.removeFirst() }
        return lines.compactMap { try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] }
    }

    /// What the tool is actually doing, for a tool that is not a question.
    /// Shows the real command or file instead of a generic placeholder.
    static func activityDetail(_ tool: PendingTool) -> String? {
        func text(_ key: String) -> String? {
            let value = (tool.input[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (value?.isEmpty ?? true) ? nil : value
        }
        switch tool.name {
        case "Bash":
            guard let command = text("command") else { return "🔧 Bash" }
            var line = "🖥 执行命令: " + shorten(command, limit: 600)
            if let note = text("description") { line += "\n   " + shorten(note, limit: 120) }
            return clamp(line)
        case "Edit", "Write", "NotebookEdit":
            guard let path = text("file_path") else { return "📝 " + tool.name }
            return clamp("📝 修改 " + (path.components(separatedBy: "/").last ?? path))
        case "Read":
            guard let path = text("file_path") else { return "📖 " + tool.name }
            return clamp("📖 读取 " + (path.components(separatedBy: "/").last ?? path))
        default:
            if let note = text("description") { return clamp("🔧 \(tool.name): " + shorten(note, limit: 120)) }
            return "🔧 " + tool.name
        }
    }

    private static func shorten(_ value: String, limit: Int) -> String {
        let flattened = value.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return flattened.count > limit ? String(flattened.prefix(limit)) + "…" : flattened
    }

    private static func clamp(_ value: String) -> String {
        value.count > maximumDetail ? String(value.prefix(maximumDetail)) : value
    }
}
