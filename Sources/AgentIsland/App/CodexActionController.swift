import AppKit
import ApplicationServices
import CryptoKit

/// Codex has its own action path. Never fall back to another app, keyboard input,
/// a coordinate click, or a persistent permission decision.
@MainActor
enum CodexActionController {
    static let bundleID = "com.openai.codex"

    static func application() -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
    }

    static func focus(_ sessionID: String? = nil, activate: Bool = true) {
        guard let app = application() else { return }
        
        // 1. Try to open specific thread if we have a session ID
        if let sessionID = sessionID, !sessionID.isEmpty,
           let url = URL(string: "codex://threads/\(sessionID)"), let appURL = app.bundleURL {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = activate
            NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: configuration, completionHandler: nil)
            return
        }
        
        // 2. Fallback to just bringing the app to the front reliably on macOS 14+
        if activate {
            if #available(macOS 14.0, *), let appURL = app.bundleURL {
                let config = NSWorkspace.OpenConfiguration()
                config.activates = true
                NSWorkspace.shared.openApplication(at: appURL, configuration: config, completionHandler: nil)
            } else {
                app.activate(options: .activateIgnoringOtherApps)
            }
        }
    }

    static func perform(approve: Bool, state: AppState) {
        guard let request = state.codexPendingRequests.first, state.codexPendingRequests.count == 1 else {
            // Cannot auto-approve if there are multiple requests
            NSSound.beep()
            return
        }
        guard !request.isQuestion else {
            // Cannot auto-approve a question via shortcut, user must select an option in the UI
            NSSound.beep()
            return
        }
        submit(request, state: state, approve: approve)
    }

    static func submit(_ request: CodexPendingRequest, state: AppState, answers: [String: String] = [:], approve: Bool = false) {
        guard !state.codexActionInFlight else { return }
        guard request.desktopMethod != nil else {
            state.codexActionFeedback = "尚未连接该 Codex 任务，请先在 Codex 中打开它"
            return
        }
        state.codexActionInFlight = true
        state.codexActionFeedback = "正在后台回传…"
        Task { [weak state] in
            let result = await CodexDesktopBridge.shared.respond(request, answers: answers, approve: approve)
            state?.codexActionFeedback = result
            state?.codexActionInFlight = false
        }
    }

}

/// Pure matching rules shared with regression tests.
enum CodexActionMatch {
    static func normalized(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }

    static func isDecisionButton(role: String, label: String, enabled: Bool, approve: Bool, isQuestion: Bool = false) -> Bool {
        guard enabled else { return false }
        // Accept both traditional buttons and text/group roles that act as option items in ChatGPT's UI
        guard role == kAXButtonRole else { return false }
        let title = normalized(label).replacingOccurrences(of: "[\\s⌘⌥⇧⌃↩↵⏎]+$", with: "", options: .regularExpression)
        
        if isQuestion {
            if approve {
                return title.hasPrefix("1 ") || title == "1" || title.contains("批准") || title.contains("发送") || title.contains("确认") || title.contains("approve") || title.contains("send") || title.contains("confirm")
            } else {
                return title.hasPrefix("2 ") || title == "2" || title.contains("拒绝") || title.contains("取消") || title.contains("reject") || title.contains("cancel")
            }
        }
        
        let allowed: Set<String> = approve
            ? ["allow once", "approve once", "allow", "approve", "run", "run once", "允许一次", "仅允许本次", "仅允许本次执行", "批准", "允许", "运行", "批准一次", "允许本次", "允許一次", "核准"]
            : ["deny", "decline", "reject", "拒绝", "不允许", "拒絕"]
        return allowed.contains(title)
    }

    static func matchesRequest(_ request: CodexPendingRequest, texts: [String]) -> Bool {
        if let digest = request.commandDigest {
            let matchedDigest = texts.contains {
                SHA256.hash(data: Data($0.trimmingCharacters(in: .whitespacesAndNewlines).utf8)).map { String(format: "%02x", $0) }.joined() == digest
            }
            if matchedDigest { return true }
        }
        return request.context.map { containsContext($0, texts: texts) } ?? false
    }

    static func containsContext(_ context: String, texts: [String]) -> Bool {
        let target = context.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return false }
        
        let firstLine = target.components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? target
        let values = texts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        
        // Exact match of full context
        if values.contains(target) { return true }
        // Match just the first line (e.g., question title, ignoring added options)
        if !firstLine.isEmpty && values.contains(firstLine) { return true }
        
        // Partial match fallback
        return values.contains { uiText in
            if uiText.contains(firstLine) { return true }
            if target.contains(uiText) && uiText.count > 15 { return true }
            // Handle UI text truncated with ellipsis
            let cleanUI = uiText.replacingOccurrences(of: "...", with: "").replacingOccurrences(of: "…", with: "")
            return target.contains(cleanUI) && cleanUI.count > 15
        }
    }
}

