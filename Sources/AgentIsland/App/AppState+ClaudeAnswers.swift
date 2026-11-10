import Foundation
import AppKit
import os.log

private let answerLogger = Logger(subsystem: "io.github.r3dra1n.AgentIsland", category: "Actions")

/// Answering Claude Code's multiple-choice question from the island. The hook
/// helper holds the question back for a few seconds and waits for a file; see
/// `ClaudeAnswerStore` for the exchange and `docs/claude-hook-install.md` for why.
extension AppState {
    /// Starts telling the helper the island is here, and watching for questions.
    func startClaudeAnswering() {
        guard claudeAnswerTimer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickClaudeAnswering() }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        claudeAnswerTimer = timer
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.stopClaudeAnswering() }
        }
        tickClaudeAnswering()
    }

    func stopClaudeAnswering() {
        claudeAnswerTimer?.invalidate(); claudeAnswerTimer = nil
        ClaudeAnswerStore.removeHeartbeat(directory: claudeAnswerDirectory)
        if !claudeAnswerRequests.isEmpty { claudeAnswerRequests = [] }
    }

    /// One beat: say the island is running (only while Claude is switched on and
    /// the demo is not), then pick up any question waiting for a click.
    func tickClaudeAnswering() {
        guard claudeEnabled, !testModeActive else {
            ClaudeAnswerStore.removeHeartbeat(directory: claudeAnswerDirectory)
            if !claudeAnswerRequests.isEmpty { claudeAnswerRequests = [] }
            return
        }
        ClaudeAnswerStore.touchHeartbeat(directory: claudeAnswerDirectory)
        refreshClaudeAnswerRequests()
    }

    func refreshClaudeAnswerRequests(now: Date = Date()) {
        let found = ClaudeAnswerStore.pending(directory: claudeAnswerDirectory, now: now)
        claudeAnsweredRequestIDs.formIntersection(found.map(\.id))
        let shown = found.filter { !claudeAnsweredRequestIDs.contains($0.id) }
        if shown != claudeAnswerRequests { claudeAnswerRequests = shown }
    }

    /// The question this row is about, when the island can answer it. A
    /// conversation's row takes only its own conversation's question; Claude's
    /// single folded row takes the one its own text is showing.
    func claudeAnswerRequest(forRow item: AIObserverItem) -> ClaudeAnswerRequest? {
        guard item.state == .awaitingInput, let detail = item.actionDetail else { return nil }
        let session = item.id.hasPrefix(Self.claudeSessionPrefix) ? String(item.id.dropFirst(Self.claudeSessionPrefix.count)) : nil
        guard session != nil || item.id == "claude" || item.icon == "claude" else { return nil }
        return claudeAnswerRequests.last { request in
            (session == nil || request.sessionID == session)
                && detail.contains("❓ " + request.question.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// Sends the user's choice to the helper, which hands it to Claude.
    func answerClaude(_ request: ClaudeAnswerRequest, optionIndex: Int) {
        guard claudeAnswerRequests.contains(request), !claudeAnsweredRequestIDs.contains(request.id) else { return }
        do {
            try ClaudeAnswerStore.answer(request, optionIndex: optionIndex, directory: claudeAnswerDirectory)
            claudeAnsweredRequestIDs.insert(request.id)
            claudeAnswerRequests.removeAll { $0.id == request.id }
            answerLogger.notice("claude answer sent: session=\(request.sessionID.prefix(8), privacy: .public) option=\(optionIndex + 1, privacy: .public) of \(request.options.count, privacy: .public)")
        } catch {
            // Nothing was sent; the question stays, and Claude's own dialog is still there.
            answerLogger.notice("claude answer not sent: \(String(describing: error), privacy: .public)")
        }
    }
}
