import Foundation

/// Outstanding Claude Code permission requests, recorded by the native hook.
///
/// The transcript has no pending-permission state, so an approval prompt is
/// indistinguishable there from a command that is simply still running. This
/// reducer supplies that missing signal and nothing else: the question text and
/// the activity detail still come from the transcript.
///
/// It is deliberately separate from `HookStateStore`, which Codex and
/// Antigravity share. Claude Code identifies turns with `prompt_id` rather than
/// a turn id and reports neither idleness nor interruption, so folding it into
/// that reducer would change behaviour for the two providers that matter most.
struct ClaudeHookState: Sendable {
    /// A request stays outstanding until the tool runs, the permission is
    /// denied, the turn stops, or the user types again.
    private struct Outstanding: Sendable {
        var toolName: String?
        var at: Date
    }

    private var outstanding: [String: [String: Outstanding]] = [:]
    private var lastEventAt: [String: Date] = [:]
    /// The turn's lifecycle as the host itself reports it. The transcript
    /// cannot supply this: the assistant's text and its tool call are separate
    /// records, so a finished turn and a turn about to call a tool look alike.
    private var turn: [String: (state: AIState, at: Date)] = [:]
    /// When the host reported a session ending. Cleared by any later event, so
    /// a resumed session is live again. Without it, a question left unanswered
    /// in an abandoned session would be shown for as long as its transcript is
    /// kept.
    private var ended: [String: Date] = [:]

    /// Requests older than this are dropped: a recorded request whose
    /// resolution was never recorded must not pin the HUD red forever.
    static let staleAfter: TimeInterval = 1800

    mutating func consume(_ event: [String: Any]) {
        guard let session = event["session_id"] as? String, !session.isEmpty,
              let name = event["hook_event_name"] as? String,
              let timestamp = event["received_at"] as? Double, timestamp.isFinite else { return }
        let date = Date(timeIntervalSince1970: timestamp)
        // Records are appended in order; ignore anything that moves backwards.
        guard date >= lastEventAt[session] ?? .distantPast else { return }
        lastEventAt[session] = date
        if name == "SessionEnd" { ended[session] = date } else { ended.removeValue(forKey: session) }
        let key = (event["tool_use_id"] as? String) ?? (event["tool_name"] as? String)
        switch name {
        case "PermissionRequest":
            guard let key else { return }
            outstanding[session, default: [:]][key] = Outstanding(toolName: event["tool_name"] as? String, at: date)
            turn[session] = (.awaitingInput, date)
        case "PostToolUse":
            guard let key else { return }
            outstanding[session]?.removeValue(forKey: key)
            turn[session] = (outstanding[session]?.isEmpty == false ? .awaitingInput : .running, date)
        case "PreToolUse":
            turn[session] = (outstanding[session]?.isEmpty == false ? .awaitingInput : .running, date)
        case "UserPromptSubmit", "SessionStart":
            outstanding.removeValue(forKey: session)
            turn[session] = (.running, date)
        case "Stop":
            outstanding.removeValue(forKey: session)
            // The recorder flags a failed turn when translating `StopFailure`.
            let failed = event["has_error"] as? Bool == true
            turn[session] = (failed ? .failed : .completed, date)
        case "SessionEnd":
            outstanding.removeValue(forKey: session)
            turn.removeValue(forKey: session)
        default:
            return
        }
        if outstanding[session]?.isEmpty == true { outstanding.removeValue(forKey: session) }
    }

    /// The host-reported turn state for one session, or nil when the hook has
    /// recorded nothing recent enough to be trusted.
    func turnState(session: String, now: Date = Date()) -> AIState? {
        guard let value = turn[session], now.timeIntervalSince(value.at) <= Self.staleAfter else { return nil }
        return value.state
    }

    /// When the host last changed this session's turn state, under the same
    /// staleness rule as `turnState`.
    func turnStateTime(session: String, now: Date = Date()) -> Date? {
        guard let value = turn[session], now.timeIntervalSince(value.at) <= Self.staleAfter else { return nil }
        return value.at
    }

    func endedAt(session: String) -> Date? { ended[session] }

    /// Tool names still awaiting approval in one session, newest first.
    /// Scoped to a session so an approval in another window cannot be shown
    /// next to the detail read from this session's transcript.
    func awaitingApproval(session: String, now: Date = Date()) -> [String] {
        (outstanding[session]?.values ?? [:].values)
            .filter { now.timeIntervalSince($0.at) <= Self.staleAfter }
            .sorted { $0.at > $1.at }
            .map { $0.toolName ?? "工具" }
    }
}

/// Owns the hook journal's read offset and reducer state, keeping file access
/// off the main actor exactly as `LogScanner` does for the other providers.
actor ClaudeHookJournal {
    private let url: URL
    private var reader = JSONLReader()
    private var state = ClaudeHookState()

    init(url: URL? = nil) {
        self.url = url ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AgentIsland/events/claude.jsonl")
    }

    /// What the hook knows about one session: the tools awaiting approval and
    /// the host-reported turn state. A missing journal means the hook is not
    /// installed, which yields nothing rather than an error so the
    /// transcript-only path keeps working.
    struct Reading: Sendable {
        var awaitingApproval: [String] = []
        var turnState: AIState?
        var turnStateAt: Date?
        var endedAt: Date?
    }

    func reading(session: String, now: Date = Date()) -> Reading {
        refresh()
        return snapshot(session: session, now: now)
    }

    /// One journal refresh for any number of sessions, so watching several of
    /// them does not read the file once per session on every poll.
    func readings(sessions: [String], now: Date = Date()) -> [String: Reading] {
        refresh()
        return Dictionary(uniqueKeysWithValues: sessions.map { ($0, snapshot(session: $0, now: now)) })
    }

    private func snapshot(session: String, now: Date) -> Reading {
        Reading(awaitingApproval: state.awaitingApproval(session: session, now: now),
                turnState: state.turnState(session: session, now: now),
                turnStateAt: state.turnStateTime(session: session, now: now),
                endedAt: state.endedAt(session: session))
    }

    func awaitingApproval(session: String, now: Date = Date()) -> [String] {
        refresh()
        return state.awaitingApproval(session: session, now: now)
    }

    private func refresh() {
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path),
              let attributes = try? manager.attributesOfItem(atPath: url.path) else { return }
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let identifier = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        let modified = attributes[.modificationDate] as? Date
        // `JSONLReader` rewinds to the start of a rotated or truncated journal
        // and then replays it, so the reducer has to be rebuilt before the read
        // rather than after it.
        if reader.fileID != identifier || size < reader.offset
            || (size == reader.offset && reader.lastModification != modified) {
            state = ClaudeHookState()
        }
        var store = state
        guard (try? reader.read(url) { store.consume($0) }) != nil else { return }
        state = store
    }
}
