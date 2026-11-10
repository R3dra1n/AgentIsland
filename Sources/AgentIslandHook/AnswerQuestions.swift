import Foundation
import CryptoKit
import Darwin

/// Lets the island answer Claude Code's multiple-choice question.
///
/// Claude Code asks `AskUserQuestion` through its own dialog, and nothing from
/// outside can press a button in it. Its documented way for a program to answer
/// is a PreToolUse hook that returns `permissionDecision: allow` together with
/// `updatedInput` carrying an `answers` map (question text to the chosen option
/// label). This runs as that hook:
///
///   1. It declines at once, printing `{}` (so Claude shows its own dialog), unless
///      the question is one the island can answer, the island is running, and
///      its files are safe to trust.
///   2. Otherwise it writes the question to `requests/<id>.json`, and waits a
///      short while for the island to write `responses/<id>.json`.
///   3. A response is only used if its label is one of the options that were
///      offered; anything else, or no response in time, prints `{}`.
///
/// Printing `{}` is "no decision": Claude carries on as if there were no hook.
/// Nothing here ever answers for the user: an answer exists only because they
/// clicked it in the island.
enum QuestionAnswering {
    static let toolName = "AskUserQuestion"
    /// How long to wait for a click. Claude's own dialog is held back this long,
    /// so it is kept short.
    static let defaultWait: TimeInterval = 20
    /// The island touches `ready` every second or so while it runs; a file older
    /// than this means it is not running, and there is nobody to wait for.
    static let heartbeatFreshness: TimeInterval = 12
    static let defaultDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/AgentIsland/answers", isDirectory: true)

    private static let maxOptions = 10
    private static let maxLabel = 200
    private static let maxText = 4000

    /// The text to print for this hook input.
    static func respond(to input: [String: Any], directory: URL, wait: TimeInterval) -> String {
        let decline = "{}\n"
        guard input["tool_name"] as? String == toolName,
              let session = input["session_id"] as? String, !session.isEmpty, session.count <= 256,
              let toolInput = input["tool_input"] as? [String: Any],
              let questions = toolInput["questions"] as? [[String: Any]], questions.count == 1,
              let question = questions.first, question["multiSelect"] as? Bool != true,
              let text = question["question"] as? String, !text.isEmpty, text.count <= maxText,
              let rawOptions = question["options"] as? [[String: Any]], !rawOptions.isEmpty, rawOptions.count <= maxOptions
        else { return decline }

        var options: [[String: String]] = []
        for raw in rawOptions {
            guard let label = raw["label"] as? String, !label.isEmpty, label.count <= maxLabel else { return decline }
            var option = ["label": label]
            if let description = raw["description"] as? String, description.count <= maxText { option["description"] = description }
            options.append(option)
        }
        let labels = options.compactMap { $0["label"] }
        guard Set(labels).count == labels.count else { return decline }   // an answer must name one option

        let id = requestID(input: input, session: session, question: text)
        guard let directory = safeDirectory(directory), isIslandRunning(directory: directory),
              let requests = safeDirectory(directory.appendingPathComponent("requests", isDirectory: true)),
              let responses = safeDirectory(directory.appendingPathComponent("responses", isDirectory: true))
        else { return decline }

        let requestFile = requests.appendingPathComponent(id + ".json")
        let responseFile = responses.appendingPathComponent(id + ".json")
        defer { unlink(requestFile.path); unlink(responseFile.path) }

        var request: [String: Any] = ["session_id": session, "question": text, "options": options,
                                      "created_at": Date().timeIntervalSince1970]
        if let header = question["header"] as? String, header.count <= maxLabel { request["header"] = header }
        guard let body = try? JSONSerialization.data(withJSONObject: request, options: [.sortedKeys, .withoutEscapingSlashes]),
              writeAtomically(body, to: requestFile, directory: requests) else { return decline }

        let deadline = ProcessInfo.processInfo.systemUptime + wait
        while ProcessInfo.processInfo.systemUptime < deadline {
            if let chosen = readResponse(responseFile, allowed: labels) {
                var updated = toolInput
                updated["answers"] = [text: chosen]
                let output: [String: Any] = ["hookSpecificOutput": [
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "allow",
                    "permissionDecisionReason": "Answered from AgentIsland",
                    "updatedInput": updated]]
                guard let data = try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys, .withoutEscapingSlashes]),
                      let string = String(data: data, encoding: .utf8) else { return decline }
                return string + "\n"
            }
            // The island went away while we waited: stop holding Claude back.
            if !isIslandRunning(directory: directory) { break }
            usleep(100_000)
        }
        return decline
    }

    /// The tool call's own id when it has a usable one, otherwise a digest, so a
    /// request always has a name that cannot escape the directory.
    private static func requestID(input: [String: Any], session: String, question: String) -> String {
        if let id = input["tool_use_id"] as? String, !id.isEmpty, id.count <= 128,
           id.unicodeScalars.allSatisfy({ ($0.value < 128) && (CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-") }) {
            return id
        }
        let digest = SHA256.hash(data: Data((session + "\n" + question).utf8)).map { String(format: "%02x", $0) }.joined()
        return String(digest.prefix(40))
    }

    /// A directory only this user can use, created if need be. Never follows a link.
    private static func safeDirectory(_ url: URL) -> URL? {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { return nil }
        return url
    }

    private static func isIslandRunning(directory: URL) -> Bool {
        var info = stat()
        guard lstat(directory.appendingPathComponent("ready").path, &info) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_uid == getuid() else { return false }
        let age = Date().timeIntervalSince1970 - Double(info.st_mtimespec.tv_sec)
        return age >= -2 && age <= heartbeatFreshness
    }

    private static func writeAtomically(_ data: Data, to destination: URL, directory: URL) -> Bool {
        let temporary = directory.appendingPathComponent("." + UUID().uuidString + ".tmp")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { return false }
        var offset = 0
        var ok = true
        while offset < data.count {
            let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: offset), data.count - offset) }
            if written < 0 && errno == EINTR { continue }
            if written <= 0 { ok = false; break }
            offset += written
        }
        close(fd)
        guard ok, rename(temporary.path, destination.path) == 0 else { unlink(temporary.path); return false }
        return true
    }

    /// The chosen label, if the response is a file only this user wrote and the
    /// label is exactly one of the options offered.
    private static func readResponse(_ file: URL, allowed: [String]) -> String? {
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_uid == getuid(), info.st_mode & 0o077 == 0, info.st_size > 0, info.st_size <= 8192 else { return nil }
        guard let data = try? FileHandle(fileDescriptor: fd, closeOnDealloc: false).readToEnd(),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let label = object["label"] as? String, allowed.contains(label) else { return nil }
        return label
    }

    static func readStandardInput() -> [String: Any]? {
        var data = Data()
        while let chunk = try? FileHandle.standardInput.read(upToCount: 65536), !chunk.isEmpty {
            data.append(chunk)
            if data.count > 1024 * 1024 { return nil }
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
