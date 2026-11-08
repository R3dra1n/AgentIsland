import XCTest
@testable import AgentIsland

/// Reads the real local state of each assistant through the real scanners and
/// prints what the HUD is built from. It exists because a hand-written mirror of
/// the reducers drifts: a Python copy once reported nothing pending while the
/// app showed nine questions.
///
/// Skipped unless `AGENTISLAND_PROBE=1`, so it never runs in CI or touches real
/// data by accident:
///
///     AGENTISLAND_PROBE=1 swift test --filter RealStateProbe
///
/// Read-only, and it prints structure only: counts, states and shortened ids.
/// No question, command, prompt or token text is ever printed.
@MainActor
final class RealStateProbe: XCTestCase {
    func testPrintRealState() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["AGENTISLAND_PROBE"] == "1",
                          "set AGENTISLAND_PROBE=1 to read the real local state")
        let home = FileManager.default.homeDirectoryForCurrentUser
        let now = Date()
        func age(_ date: Date?) -> String { date.map { "\(Int(now.timeIntervalSince($0)))s" } ?? "-" }

        let codex = await LogScanner(source: "codex", root: home.appendingPathComponent(".codex/sessions"),
                                     hookURL: CodexObserver.hookJournalURL(home: home)).scan(now: now)
        var perSession: [String: Int] = [:]
        for request in codex.codexRequests { perSession[request.sessionID, default: 0] += 1 }
        print("PROBE codex state=\(codex.state.rawValue) pendingRequests=\(codex.codexRequests.count) lastActive=\(age(codex.lastActiveDate))")
        for (id, count) in perSession.sorted(by: { $0.key < $1.key }) { print("PROBE   codex session=\(id.prefix(8)) requests=\(count)") }

        let antigravity = await LogScanner(source: "antigravity",
                                           root: home.appendingPathComponent(".gemini/antigravity/brain")).scan(now: now)
        print("PROBE antigravity state=\(antigravity.state.rawValue) sessions=\(antigravity.antigravitySessions.count)")
        for session in antigravity.antigravitySessions {
            print("PROBE   antigravity row=\(session.id.prefix(11)) state=\(session.state.rawValue) lastActive=\(age(session.lastActiveDate))")
        }

        let claude = await ClaudeSessionScanner(projects: home.appendingPathComponent(".claude/projects"),
                                                journal: ClaudeHookJournal()).scan(now: now)
        print("PROBE claude sessions=\(claude.count)")
        for session in claude {
            print("PROBE   claude session=\(session.id.prefix(8)) state=\(session.state.rawValue) lastActive=\(age(session.lastActiveDate))")
        }
    }
}
