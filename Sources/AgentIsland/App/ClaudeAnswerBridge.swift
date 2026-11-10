import Foundation
import Darwin

/// One multiple-choice question Claude Code is waiting on, as the hook helper
/// handed it to the island (see `QuestionAnswering` in the AgentIslandHook target).
struct ClaudeAnswerRequest: Identifiable, Equatable, Sendable {
    struct Option: Equatable, Sendable {
        let label: String
        let description: String?
    }
    /// The tool call's id; also the name of the request and response files.
    let id: String
    let sessionID: String
    let question: String
    let header: String?
    let options: [Option]
    let createdAt: Date
}

/// The files the island and the hook helper exchange, in one directory only this
/// user can use:
///
///   ready                 touched every second while the island runs, so the helper
///                         knows there is somebody to wait for
///   requests/<id>.json    written by the helper when Claude asks
///   responses/<id>.json   written here when the user clicks an option
///
/// Nothing here answers for the user: a response exists only because they clicked.
enum ClaudeAnswerStore {
    /// The helper gives up after 20 s; a request older than this is a dead one.
    static let requestFreshness: TimeInterval = 25
    private static let maxFile = 64 * 1024

    static var defaultDirectory: URL {
        #if AGENTISLAND_ISOLATED_PREVIEW
        FileManager.default.temporaryDirectory.appendingPathComponent("AgentIslandIsolatedPreview/answers", isDirectory: true)
        #else
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AgentIsland/answers", isDirectory: true)
        #endif
    }

    /// A directory only this user can use, created if need be. Never a link.
    static func safeDirectory(_ url: URL) -> URL? {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { return nil }
        return url
    }

    /// Says the island is running. Without this the helper never waits.
    @discardableResult
    static func touchHeartbeat(directory: URL = defaultDirectory) -> Bool {
        guard let directory = safeDirectory(directory) else { return false }
        let path = directory.appendingPathComponent("ready").path
        var info = stat()
        if lstat(path, &info) == 0 {
            guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_uid == getuid() else { return false }
            return utimes(path, nil) == 0
        }
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { return false }
        close(fd)
        return true
    }

    /// Says the island is not running (or not answering), so the helper stops waiting.
    static func removeHeartbeat(directory: URL = defaultDirectory) {
        unlink(directory.appendingPathComponent("ready").path)
    }

    /// Questions waiting for a click, oldest first.
    static func pending(directory: URL = defaultDirectory, now: Date = Date()) -> [ClaudeAnswerRequest] {
        let requests = directory.appendingPathComponent("requests", isDirectory: true)
        var dir = stat()
        guard lstat(directory.path, &dir) == 0, dir.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), dir.st_uid == getuid(), dir.st_mode & 0o077 == 0,
              lstat(requests.path, &dir) == 0, dir.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), dir.st_uid == getuid(), dir.st_mode & 0o077 == 0,
              let names = try? FileManager.default.contentsOfDirectory(atPath: requests.path) else { return [] }
        return names.compactMap { name -> ClaudeAnswerRequest? in
            guard name.hasSuffix(".json"), !name.hasPrefix(".") else { return nil }
            let id = String(name.dropLast(5))
            guard isSafeID(id) else { return nil }
            return read(requests.appendingPathComponent(name), id: id, now: now)
        }.sorted { $0.createdAt < $1.createdAt }
    }

    private static func read(_ file: URL, id: String, now: Date) -> ClaudeAnswerRequest? {
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_uid == getuid(),
              info.st_mode & 0o077 == 0, info.st_size > 0, info.st_size <= maxFile else { return nil }
        guard let data = try? FileHandle(fileDescriptor: fd, closeOnDealloc: false).readToEnd(),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let session = object["session_id"] as? String, !session.isEmpty,
              let question = object["question"] as? String, !question.isEmpty,
              let created = object["created_at"] as? Double,
              let raw = object["options"] as? [[String: Any]], !raw.isEmpty else { return nil }
        let age = now.timeIntervalSince1970 - created
        guard age >= -5, age <= requestFreshness else { return nil }
        let options = raw.compactMap { entry -> ClaudeAnswerRequest.Option? in
            guard let label = entry["label"] as? String, !label.isEmpty else { return nil }
            return ClaudeAnswerRequest.Option(label: label, description: entry["description"] as? String)
        }
        guard options.count == raw.count else { return nil }
        return ClaudeAnswerRequest(id: id, sessionID: session, question: question, header: object["header"] as? String,
                                   options: options, createdAt: Date(timeIntervalSince1970: created))
    }

    private static func isSafeID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 128 && id.unicodeScalars.allSatisfy {
            $0.value < 128 && (CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-")
        }
    }

    enum AnswerError: Error { case notAnOption, unsafe, writeFailed }

    /// Records the user's choice. Only one of the options that were offered can be
    /// chosen; the helper checks again on its side.
    static func answer(_ request: ClaudeAnswerRequest, optionIndex: Int, directory: URL = defaultDirectory) throws {
        guard request.options.indices.contains(optionIndex) else { throw AnswerError.notAnOption }
        guard isSafeID(request.id), let root = safeDirectory(directory),
              let responses = safeDirectory(root.appendingPathComponent("responses", isDirectory: true)) else { throw AnswerError.unsafe }
        let body = try JSONSerialization.data(withJSONObject: ["label": request.options[optionIndex].label,
                                                               "answered_at": Date().timeIntervalSince1970],
                                              options: [.sortedKeys, .withoutEscapingSlashes])
        let temporary = responses.appendingPathComponent("." + UUID().uuidString + ".tmp")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { throw AnswerError.writeFailed }
        var offset = 0
        var ok = true
        while offset < body.count {
            let written = body.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: offset), body.count - offset) }
            if written < 0 && errno == EINTR { continue }
            if written <= 0 { ok = false; break }
            offset += written
        }
        close(fd)
        // The final name appears only once the file is complete.
        guard ok, rename(temporary.path, responses.appendingPathComponent(request.id + ".json").path) == 0 else {
            unlink(temporary.path)
            throw AnswerError.writeFailed
        }
    }
}
