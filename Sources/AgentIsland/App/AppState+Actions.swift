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
            return (antigravityAcknowledgedSessions[session.id] ?? .distantPast) < (session.completedAt ?? session.lastActiveDate ?? .distantFuture)
        }
        if !stillActive { acknowledgeAntigravity() }
    }

    public func acknowledgeClaude() {
        if testModeActive { stopTest(); return }
        lastAcknowledgedDates["claude"] = Date()
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

    public func acknowledgeAll() {
        if testModeActive { stopTest(); return }
        if codexNeedsAck || codexState == .completed { acknowledgeCodex() }
        if antigravityNeedsAck || antigravityState == .completed { acknowledgeAntigravity() }
        if claudeNeedsAck || claudeState == .completed { acknowledgeClaude() }
    }
}
