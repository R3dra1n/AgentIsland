import Foundation
import SwiftUI
import AppKit

extension AppState {
    // Direct Actions without stealing window focus
    public func approve(for observerId: String) {
        if observerId == "antigravity", !testModeActive {
            antigravityDescription = "请在 Antigravity 中确认操作"
            focusApp(for: observerId)
            return
        }
        if ["cursor", "windsurf", "trae"].contains(observerId) { focusApp(for: observerId); return }
        DirectActionEngine.shared.approveInBackground(observerId: observerId, appState: self)
    }

    public func reject(for observerId: String) {
        if observerId == "antigravity", !testModeActive {
            antigravityDescription = "请在 Antigravity 中处理请求"
            focusApp(for: observerId)
            return
        }
        if ["cursor", "windsurf", "trae"].contains(observerId) { focusApp(for: observerId); return }
        DirectActionEngine.shared.rejectInBackground(observerId: observerId, appState: self)
    }

    public func sendTextInput(for id: String, text: String, prefixKey: String? = nil) {
        if id == "codex" {
            guard let request = codexPendingRequests.first, codexPendingRequests.count == 1,
                  request.questions.count == 1, let question = request.questions.first else {
                codexActionFeedback = "请在灵动岛选项面板回答对应问题"
                return
            }
            CodexActionController.submit(request, state: self, answers: [question.id: text])
            return
        }
        if id == "antigravity", !testModeActive {
            AntigravityActionController.submit(.text(text), state: self)
            return
        }
        if ["cursor", "windsurf", "trae"].contains(id) { focusApp(for: id); return }
        if id == "antigravity", !DirectActionEngine.shared.canSendAntigravityAction(appState: self) { return }
        if id == "codex" {
            codexState = .running
            codexDescription = "已发送输入，正在执行..."
        } else if id == "antigravity" {
            antigravityDescription = "正在发送输入，等待 Antigravity 状态更新..."
        } else if id == "claude" {
            claudeState = .running
            claudeDescription = "已发送输入，正在执行..."
        }
        recalculateAggregatedState()
        
        let engine = DirectActionEngine.shared
        DispatchQueue.global(qos: .userInitiated).async {
            engine.sendTextInBackground(observerId: id, text: text, prefixKey: prefixKey, appState: self)
        }
    }

    func sendAntigravityOption(_ index: Int) {
        AntigravityActionController.submit(.option(index), state: self)
    }

    func prepareAntigravityQuestion(forSession sessionID: String, expectedIdentity: AntigravityPendingIdentity, expectedDetail: String) {
        AntigravityActionController.prepare(state: self, sessionID: sessionID, expectedIdentity: expectedIdentity, expectedDetail: expectedDetail)
    }

    func discardAntigravityQuestion(forSession sessionID: String) {
        AntigravityActionController.discard(state: self, sessionID: sessionID)
    }

    func sendAntigravityText(_ text: String, forSession sessionID: String, expectedIdentity: AntigravityPendingIdentity,
                             expectedDetail: String, expectedQuestion: AntigravityQuestion) {
        AntigravityActionController.submit(.text(text), state: self, sessionID: sessionID, expectedIdentity: expectedIdentity,
                                           expectedDetail: expectedDetail, expectedQuestion: expectedQuestion)
    }

    func sendAntigravityOption(_ index: Int, forSession sessionID: String, expectedIdentity: AntigravityPendingIdentity,
                               expectedDetail: String, expectedQuestion: AntigravityQuestion) {
        AntigravityActionController.submit(.option(index), state: self, sessionID: sessionID, expectedIdentity: expectedIdentity,
                                           expectedDetail: expectedDetail, expectedQuestion: expectedQuestion)
    }

    /// Where "open" should take the user for one Claude conversation.
    enum ClaudeOpenTarget: Equatable { case desktopApp, desktopNeedsInput, terminal }

    nonisolated static func claudeOpenTarget(entrypoint: String?, state: AIState) -> ClaudeOpenTarget {
        guard let entrypoint, entrypoint.lowercased().contains("desktop") else { return .terminal }
        return state == .awaitingInput ? .desktopNeedsInput : .desktopApp
    }

    /// Opens the window behind one HUD row, as precisely as the host allows:
    /// Codex jumps to the thread, Antigravity presses the conversation's own
    /// sidebar link (falling back to the app), and Claude goes to the app the
    /// conversation actually runs in. No assistant offers a per-session link
    /// for Claude, so that one can only bring the right app forward.
    public func focusSession(_ row: AIObserverItem) {
        if row.id.hasPrefix(Self.antigravitySessionPrefix) {
            let id = String(row.id.dropFirst(Self.antigravitySessionPrefix.count))
            let app = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == "com.google.antigravity" }
            focusApp(for: "antigravity")
            // Going to look at a finished conversation is what "viewed" means.
            // Waiting for a sidebar click instead needs the Accessibility
            // permission, which an update resets, and never fires for the
            // programmatic press below.
            if row.state == .completed { acknowledgeAntigravitySession(id) }
            if let pid = app?.processIdentifier {
                Task.detached {
                    // Give the window a moment to come forward before pressing.
                    try? await Task.sleep(for: .milliseconds(300))
                    _ = AntigravityViewedMonitor.pressConversationLink(sessionID: id, pid: pid)
                }
            }
        } else if row.id.hasPrefix(Self.claudeSessionPrefix) {
            openClaude(session: claudeSessions.first { $0.id == String(row.id.dropFirst(Self.claudeSessionPrefix.count)) })
        } else if row.id == "claude" || row.icon == "claude" {
            // The provider-level row (one conversation, or the folded icon)
            // has no session id; use the one that most needs attention.
            openClaude(session: Self.mostRelevantClaudeSession(claudeSessions))
        } else {
            let antigravity = row.icon == "antigravity" || row.id == "antigravity"
            focusApp(for: antigravity ? "antigravity" : row.id)
            if antigravity, row.state == .completed { acknowledgeAntigravity() }
        }
    }

    nonisolated static func mostRelevantClaudeSession(_ sessions: [ClaudeSessionSnapshot]) -> ClaudeSessionSnapshot? {
        sessions.sorted { a, b in
            let rank: (AIState) -> Int = { $0 == .awaitingInput ? 0 : ($0 == .running ? 1 : 2) }
            if rank(a.state) != rank(b.state) { return rank(a.state) < rank(b.state) }
            return (a.lastActiveDate ?? .distantPast) > (b.lastActiveDate ?? .distantPast)
        }.first
    }

    public func openClaudeConversation() { openClaude(session: Self.mostRelevantClaudeSession(claudeSessions)) }

    private func openClaude(session: ClaudeSessionSnapshot?) {
        switch Self.claudeOpenTarget(entrypoint: session?.entrypoint, state: session?.state ?? .idle) {
        case .desktopNeedsInput:
            if let url = URL(string: "claude://code/needs-input?source=desktop_action") { NSWorkspace.shared.open(url) }
        case .desktopApp:
            openClaudeDesktopApp()
        case .terminal:
            // A conversation we cannot place (no recorded host) used to do
            // nothing when no terminal was running. The desktop app is the
            // better guess than silence.
            if Self.terminalAppRunning() { focusApp(for: "claude") } else { openClaudeDesktopApp() }
        }
    }

    private func openClaudeDesktopApp() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop") {
            let config = NSWorkspace.OpenConfiguration(); config.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: config, completionHandler: nil)
        } else { focusApp(for: "claude") }
    }

    nonisolated static let terminalNames = ["iTerm2", "Terminal", "Ghostty", "Warp", "Alacritty", "Kitty"]

    static func terminalAppRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { app in
            terminalNames.contains { (app.localizedName ?? "").localizedCaseInsensitiveContains($0) }
        }
    }

    public func focusApp(for observerId: String) {
        let runningApps = NSWorkspace.shared.runningApplications
        if observerId == "codex" {
            CodexActionController.focus(codexPendingRequests.count == 1 ? codexPendingRequests.first?.sessionID : nil)
        } else if observerId == "antigravity" {
            if let app = runningApps.first(where: { $0.bundleIdentifier == "com.google.antigravity" }) {
                if #available(macOS 14.0, *), let url = app.bundleURL { let config = NSWorkspace.OpenConfiguration(); config.activates = true; NSWorkspace.shared.openApplication(at: url, configuration: config, completionHandler: nil) } else { app.activate(options: .activateIgnoringOtherApps) }
            }
        } else {
            let terminalNames = ["iTerm2", "Terminal", "Ghostty", "Warp", "Alacritty", "Kitty"]
            if let app = runningApps.first(where: { app in
                terminalNames.contains(where: { (app.localizedName ?? "").localizedCaseInsensitiveContains($0) })
            }) {
                if #available(macOS 14.0, *), let url = app.bundleURL { let config = NSWorkspace.OpenConfiguration(); config.activates = true; NSWorkspace.shared.openApplication(at: url, configuration: config, completionHandler: nil) } else { app.activate(options: .activateIgnoringOtherApps) }
            }
        }
    }

    public func acknowledgeCodex() {
        if testModeActive { stopTest(); return }
        lastAcknowledgedDates["codex"] = Date()
        codexNeedsAck = false
        codexState = .idle
        codexDescription = "待命中"
        recalculateAggregatedState()
    }

    public func acknowledgeAntigravity() {
        if testModeActive { stopTest(); return }
        lastAcknowledgedDates["antigravity"] = Date()
        antigravityNeedsAck = false
        antigravityState = .idle
        antigravityDescription = "待命中"
        recalculateAggregatedState()
    }

    func acknowledgeAntigravitySession(_ id: String) {
        guard let session = antigravityObserver.sessions.first(where: { $0.id == id }), session.state == .completed,
              let completion = session.completedAt ?? session.lastActiveDate else { return }
        antigravityAcknowledgedSessions[id] = max(Date(), completion)
        UserDefaults.standard.set(antigravityAcknowledgedSessions, forKey: "antigravityAcknowledgedSessions")
        let stillActive = antigravityObserver.sessions.contains { session in
            if session.state == .running || session.state == .awaitingInput { return true }
            guard session.state == .completed else { return false }
            return !Self.viewMarkCovers(acknowledgedAt: antigravityAcknowledgedSessions[session.id], finishedAt: session.completedAt ?? session.lastActiveDate)
        }
        if !stillActive { acknowledgeAntigravity() }
    }

    /// Marks the finished conversation behind a row as viewed, whichever
    /// assistant it belongs to.
    func acknowledgeSessionRow(_ row: AIObserverItem) {
        if row.id.hasPrefix(Self.antigravitySessionPrefix) {
            acknowledgeAntigravitySession(String(row.id.dropFirst(Self.antigravitySessionPrefix.count)))
        } else if row.id.hasPrefix(Self.claudeSessionPrefix) {
            acknowledgeClaudeSession(String(row.id.dropFirst(Self.claudeSessionPrefix.count)))
        }
    }

    /// Acknowledges one finished conversation. The provider-level completion is
    /// only cleared once no conversation is left that still needs attention.
    func acknowledgeClaudeSession(_ id: String) {
        guard let session = claudeSessions.first(where: { $0.id == id }), session.state == .completed,
              let completion = session.completedAt ?? session.lastActiveDate else { return }
        claudeAcknowledgedSessions[id] = max(Date(), completion)
        let stillActive = claudeSessions.contains { session in
            if session.state == .running || session.state == .awaitingInput { return true }
            guard session.state == .completed else { return false }
            return (claudeAcknowledgedSessions[session.id] ?? .distantPast) < (session.completedAt ?? session.lastActiveDate ?? .distantFuture)
        }
        if !stillActive { acknowledgeClaude() }
    }

    public func acknowledgeClaude() {
        if testModeActive { stopTest(); return }
        lastAcknowledgedDates["claude"] = Date()
        // Acknowledging the provider acknowledges everything it has finished.
        for session in claudeSessions where session.state == .completed {
            claudeAcknowledgedSessions[session.id] = max(Date(), session.completedAt ?? session.lastActiveDate ?? Date())
        }
        claudeNeedsAck = false


        claudeState = .idle
        claudeDescription = "待命中"
        recalculateAggregatedState()
    }

    
    public func acknowledgeCursor() {
        if testModeActive { stopTest(); return }
        lastAcknowledgedDates["cursor"] = Date()
        cursorNeedsAck = false
        cursorState = .idle
        cursorDescription = "待命中"
        recalculateAggregatedState()
    }

    public func acknowledgeWindsurf() {
        if testModeActive { stopTest(); return }
        lastAcknowledgedDates["windsurf"] = Date()
        windsurfNeedsAck = false
        windsurfState = .idle
        windsurfDescription = "待命中"
        recalculateAggregatedState()
    }

    public func acknowledgeTrae() {
        if testModeActive { stopTest(); return }
        lastAcknowledgedDates["trae"] = Date()
        traeNeedsAck = false
        traeState = .idle
        traeDescription = "待命中"
        recalculateAggregatedState()
    }

}
