import AppKit

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
