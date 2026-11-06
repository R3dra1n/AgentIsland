import Foundation

/// One Claude Code conversation as the HUD shows it. Idle conversations are not
/// represented: a snapshot exists only while there is something to show.
struct ClaudeSessionSnapshot: Identifiable, Equatable, Sendable {
    /// The transcript's file name, which is also the session id the hook events carry.
    let id: String
    let state: AIState
    let description: String
    let actionDetail: String?
    let lastActiveDate: Date?
    var completedAt: Date? = nil
    /// Where the conversation runs, from the transcript; decides what "open" means.
    var entrypoint: String? = nil
}

/// Decides what one conversation is doing from the facts read out of its
/// transcript and from the hook events recorded for it. Pure, so every rule is
/// testable without a running assistant.
enum ClaudeSessionEvaluator {
    /// Without the hook, activity older than this is not shown at all.
    static let recentWindow: TimeInterval = 120
    /// A turn the host says is running, with nothing outstanding and a
    /// transcript that has not moved this long, is a session that died without
    /// reporting it.
    static let runningStale: TimeInterval = 600
    /// A failure is news for a short while, then it is just history.
    static let failedVisible: TimeInterval = 60
    /// Tolerance between a session-end event and the transcript's last write.
    private static let endSkew: TimeInterval = 2

    static func evaluate(id: String, modified: Date, pending: [ClaudeTranscript.PendingTool],
                         endsWithAssistantText: Bool, hook: ClaudeHookJournal.Reading,
                         now: Date) -> ClaudeSessionSnapshot? {
        let age = now.timeIntervalSince(modified)
        func snapshot(_ state: AIState, _ description: String, detail: String? = nil,
                      completedAt: Date? = nil) -> ClaudeSessionSnapshot {
            ClaudeSessionSnapshot(id: id, state: state, description: description, actionDetail: detail,
                                  lastActiveDate: modified, completedAt: completedAt)
        }

        // A session the host reported as ended, and which has not been written
        // to since, is over. Its unanswered questions are not waiting on anyone.
        if let ended = hook.endedAt, ended.addingTimeInterval(endSkew) >= modified { return nil }

        // A structured question with no result is the one unambiguous
        // "waiting for the user" state in the transcript itself. It has no age
        // limit: someone answering it may well be away from the keyboard.
        if let question = pending.last(where: { $0.name == ClaudeTranscript.questionToolName }),
           let detail = ClaudeTranscript.questionDetail(question.input) {
            return snapshot(.awaitingInput, "等待回答提问", detail: detail)
        }
        // The transcript records no pending permission, so the hook supplies it.
        if !hook.awaitingApproval.isEmpty {
            var lines = ["🔒 等待授权：" + hook.awaitingApproval.joined(separator: "、")]
            if let active = pending.last, let detail = ClaudeTranscript.activityDetail(active) { lines.append(detail) }
            return snapshot(.awaitingInput, "等待指令授权", detail: lines.joined(separator: "\n"))
        }
        // The host's own turn lifecycle outranks anything inferred from the
        // transcript, where a turn that is about to call a tool is
        // indistinguishable from a finished one.
        if let reported = hook.turnState {
            let at = hook.turnStateAt ?? modified
            switch reported {
            case .completed:
                return snapshot(.completed, "本轮对话已完成", completedAt: at)
            case .failed:
                guard now.timeIntervalSince(at) < failedVisible else { return nil }
                return snapshot(.failed, "本轮对话异常结束")
            default:
                if pending.isEmpty && age > runningStale { return nil }
                return snapshot(.running, "正在执行任务与代码生成...",
                                detail: pending.last.flatMap { ClaudeTranscript.activityDetail($0) })
            }
        }
        // No hook for this session: fall back to the transcript alone, which can
        // only be trusted while it is fresh.
        guard age < recentWindow else { return nil }
        if let active = pending.last {
            return snapshot(.running, "正在执行任务与代码生成...", detail: ClaudeTranscript.activityDetail(active))
        }
        // Only call a turn finished once the transcript has also stopped
        // changing, so the gap between the assistant's text record and its
        // tool-call record is not mistaken for the end of the turn.
        if age >= ClaudeTranscript.quietTurnEnd, endsWithAssistantText {
            return snapshot(.completed, "本轮对话已完成", completedAt: modified)
        }
        if age < 8 { return snapshot(.running, "正在与 Claude 交互中...") }
        return nil
    }

    /// The conversation that decides the provider-level state: the one that
    /// needs the user most, and among equals the one touched most recently.
    static func leading(_ sessions: [ClaudeSessionSnapshot]) -> ClaudeSessionSnapshot? {
        sessions.max { lhs, rhs in
            if lhs.state != rhs.state { return lhs.state < rhs.state }
            return (lhs.lastActiveDate ?? .distantPast) < (rhs.lastActiveDate ?? .distantPast)
        }
    }
}

/// Watches every recent conversation, not only the newest. Transcript parsing is
/// cached per file and redone only when the file changes, because the observer
/// polls several times a second and a conversation's transcript can be large.
actor ClaudeSessionScanner {
    /// Older transcripts are history and are never inspected.
    static let window: TimeInterval = 86_400
    /// Bounds the work however many transcripts have piled up.
    static let maximumSessions = 12
    private static let discoveryInterval: TimeInterval = 2

    private struct Entry {
        var modified: Date
        var size: UInt64
        var pending: [ClaudeTranscript.PendingTool]
        var endsWithAssistantText: Bool
        var entrypoint: String?
    }

    private let projects: URL
    private let journal: ClaudeHookJournal
    private var entries: [URL: Entry] = [:]
    private var candidates: [URL] = []
    private var lastDiscovery = Date.distantPast

    init(projects: URL, journal: ClaudeHookJournal) {
        self.projects = projects
        self.journal = journal
    }

    func scan(now: Date = Date()) async -> [ClaudeSessionSnapshot] {
        discoverIfDue(now: now)
        let manager = FileManager.default
        var observed: [(id: String, modified: Date, entry: Entry)] = []
        for url in candidates {
            guard let attributes = try? manager.attributesOfItem(atPath: url.path),
                  let modified = attributes[.modificationDate] as? Date else { continue }
            let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            var entry = entries[url]
            if entry == nil || entry?.modified != modified || entry?.size != size {
                let records = ClaudeTranscript.readRecords(of: url)
                entry = Entry(modified: modified, size: size,
                              pending: ClaudeTranscript.pendingTools(records),
                              endsWithAssistantText: ClaudeTranscript.endsWithAssistantText(records),
                              entrypoint: ClaudeTranscript.entrypoint(records))
                entries[url] = entry
            }
            if let entry { observed.append((url.deletingPathExtension().lastPathComponent, modified, entry)) }
        }
        let live = Set(candidates)
        entries = entries.filter { live.contains($0.key) }
        let readings = await journal.readings(sessions: observed.map(\.id), now: now)
        return observed.compactMap { item in
            var snapshot = ClaudeSessionEvaluator.evaluate(id: item.id, modified: item.modified, pending: item.entry.pending,
                                                           endsWithAssistantText: item.entry.endsWithAssistantText,
                                                           hook: readings[item.id] ?? .init(), now: now)
            snapshot?.entrypoint = item.entry.entrypoint
            return snapshot
        }
    }

    /// Only `projects/<project>/<session>.jsonl` is a conversation. Anything
    /// deeper belongs to a subagent and is part of its parent's work, not a
    /// conversation the user is having.
    private func discoverIfDue(now: Date) {
        guard now.timeIntervalSince(lastDiscovery) >= Self.discoveryInterval else { return }
        lastDiscovery = now
        let manager = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let folders = try? manager.contentsOfDirectory(at: projects, includingPropertiesForKeys: [.isDirectoryKey],
                                                             options: [.skipsHiddenFiles]) else {
            candidates = []
            return
        }
        var found: [(Date, URL)] = []
        for folder in folders {
            guard let files = try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                               options: [.skipsHiddenFiles]) else { continue }
            for file in files where file.pathExtension == "jsonl" {
                guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                      let modified = values.contentModificationDate,
                      now.timeIntervalSince(modified) < Self.window else { continue }
                found.append((modified, file))
            }
        }
        candidates = found.sorted { $0.0 > $1.0 }.prefix(Self.maximumSessions).map(\.1)
    }
}
