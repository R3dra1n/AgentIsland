import XCTest
@testable import AgentIsland

/// A restart reads the day's transcripts from the start, and they reach hundreds
/// of megabytes. The reader was rewritten to search for newlines once and to
/// hand records to the parser without copying; these tests hold it to reading
/// exactly what the straightforward way reads, wherever a chunk happens to end.
final class JSONLReaderChunkingTests: XCTestCase {
    private var url: URL!
    override func setUpWithError() throws { url = FileManager.default.temporaryDirectory.appendingPathComponent("jsonl-" + UUID().uuidString) }
    override func tearDown() { try? FileManager.default.removeItem(at: url) }

    private func records(_ url: URL, chunk: Int) throws -> [String] {
        var reader = JSONLReader(); reader.chunkSize = chunk
        var seen: [String] = []
        _ = try reader.read(url) { seen.append($0["id"] as? String ?? "?") }
        return seen
    }

    /// Records from a few bytes to far larger than the chunk, with blank lines,
    /// a line that is not JSON, and multi-byte characters, the way real
    /// transcripts mix them.
    private func sample() -> (data: Data, expected: [String]) {
        var text = ""; var expected: [String] = []
        for i in 0..<300 {
            switch i % 7 {
            case 0: text += "\n"                                                     // blank
            case 1: text += "not json at all \(i)\n"                                 // skipped
            case 2: let id = "big\(i)"; text += "{\"id\":\"\(id)\",\"blob\":\"\(String(repeating: "x", count: 5_000 + i * 13))\"}\n"; expected.append(id)
            default: let id = "r\(i)你好"; text += "{\"id\":\"\(id)\"}\n"; expected.append(id)
            }
        }
        return (Data(text.utf8), expected)
    }

    func testEveryChunkSizeReadsTheSameRecordsInTheSameOrder() throws {
        let (data, expected) = sample()
        try data.write(to: url)
        for chunk in [1, 2, 3, 7, 64, 1000, 4096, 100_000, 4 * 1024 * 1024] {
            XCTAssertEqual(try records(url, chunk: chunk), expected, "chunk size \(chunk)")
        }
    }

    func testARecordStillWaitingForItsNewlineIsKeptUntilItArrives() throws {
        try Data("{\"id\":\"a\"}\n{\"id\":\"b\"".utf8).write(to: url)
        var reader = JSONLReader(); reader.chunkSize = 5
        var seen: [String] = []
        _ = try reader.read(url) { seen.append($0["id"] as? String ?? "?") }
        XCTAssertEqual(seen, ["a"])
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd(); try handle.write(contentsOf: Data("}\n{\"id\":\"c\"}\n".utf8)); try handle.close()
        _ = try reader.read(url) { seen.append($0["id"] as? String ?? "?") }
        XCTAssertEqual(seen, ["a", "b", "c"])
    }

    func testARecordTooLargeToHoldStillFailsAsBefore() throws {
        try Data(String(repeating: "x", count: 17 * 1024 * 1024).utf8).write(to: url)
        var reader = JSONLReader()
        XCTAssertThrowsError(try reader.read(url) { _ in })
    }

    // Not a benchmark: a bound with several times the room the reader needs here
    // (about half a second), and well under what the rescanning it replaced took.
    func testALargeFileOfLongRecordsIsReadQuickly() throws {
        let line = "{\"id\":\"x\",\"blob\":\"\(String(repeating: "y", count: 300_000))\"}\n"
        let handle = try { FileManager.default.createFile(atPath: url.path, contents: nil); return try FileHandle(forWritingTo: url) }()
        for _ in 0..<200 { try handle.write(contentsOf: Data(line.utf8)) }   // about 60 MB
        try handle.close()
        var reader = JSONLReader(); var count = 0
        let start = Date()
        _ = try reader.read(url) { _ in count += 1 }
        XCTAssertEqual(count, 200)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2.5, "reading 60 MB of long records took far longer than it should")
    }
}

/// The first time round the transcripts already say what is going on, so they
/// are reported before the desktop has been asked. (Whether that saves time
/// depends on a real desktop that does not answer for a conversation it does not
/// have open, which a test cannot stand in for; it was measured on real data.)
@MainActor
final class CodexFirstPublishTests: XCTestCase {
    func testResolvedFromTranscriptsAloneNamesTheNewestFinish() {
        let finished = [CodexLiveActivity(sessionID: "a", turnID: nil, state: .completed, startedAt: Date(timeIntervalSince1970: 100)),
                        CodexLiveActivity(sessionID: "b", turnID: nil, state: .completed, startedAt: Date(timeIntervalSince1970: 200))]
        let scanned = ObserverSnapshot(state: .idle, description: "待命中", lastActiveDate: nil)
        let early = CodexObserver.resolved(scanned, liveStates: [], fallback: [:], finished: finished, now: Date(timeIntervalSince1970: 300))
        XCTAssertEqual(early.state, .completed)
        XCTAssertEqual(early.lastActiveDate, Date(timeIntervalSince1970: 200))
        XCTAssertEqual(Set(early.codexSessions.map(\.id)), ["a", "b"])
    }

    func testAnObserverOverTranscriptsReportsTheFinishedConversation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-first-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID().uuidString.lowercased()
        // Stamped relative to now: sessions older than `sessionWindow` are not shown,
        // so a fixed date would make this test fail once it was a day old.
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let base = Date().addingTimeInterval(-60)
        func stamp(_ offset: TimeInterval) -> String { formatter.string(from: base.addingTimeInterval(offset)) }
        let lines = [#"{"timestamp":"\#(stamp(0))","type":"session_meta","payload":{"id":"\#(id)"}}"#,
                     #"{"timestamp":"\#(stamp(1))","type":"event_msg","payload":{"type":"task_started","turn_id":"t1"}}"#,
                     #"{"timestamp":"\#(stamp(2))","type":"event_msg","payload":{"type":"task_complete","turn_id":"t1"}}"#]
        try (lines.joined(separator: "\n") + "\n").write(to: root.appendingPathComponent("rollout-test.jsonl"), atomically: true, encoding: .utf8)

        let observer = CodexObserver(root: root)
        let start = Date()
        observer.startObserving()
        defer { observer.stopObserving() }
        while observer.state == .unknown, Date().timeIntervalSince(start) < 20 { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertEqual(observer.state, .completed)
        XCTAssertEqual(observer.sessions.map(\.id), [id])
    }
}
