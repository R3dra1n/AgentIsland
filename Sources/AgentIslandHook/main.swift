import Foundation
import CryptoKit
import Darwin

// A standalone native equivalent of the existing event recorder. It deliberately
// returns the old host response even when recording fails; installation remains
// opt-in until each host's hook response semantics have been verified.
private let supportedEvents: Set<String> = ["SessionStart", "SessionEnd", "UserPromptSubmit", "PermissionRequest", "PreToolUse", "PostToolUse", "SubagentStart", "SubagentStop", "Stop", "Interrupt", "PreInvocation"]
private let maxInput = 1024 * 1024

private enum HookError: Error { case malformed, unsafePath, fileOperation, timeout }

private func count(_ value: String) -> Int { value.unicodeScalars.count }

private func truthy(_ value: Any?) -> Bool {
    guard let value, !(value is NSNull) else { return false }
    if let value = value as? Bool { return value }
    if let value = value as? String { return !value.isEmpty }
    if let value = value as? NSNumber { return value.doubleValue != 0 }
    if let value = value as? [Any] { return !value.isEmpty }
    if let value = value as? [String: Any] { return !value.isEmpty }
    return true
}

private func normalize(_ input: [String: Any], source: String, event: String?) throws -> [String: Any] {
    guard let name = event ?? input["hook_event_name"] as? String, supportedEvents.contains(name),
          let session = input[source == "codex" ? "session_id" : "conversationId"] as? String,
          !session.isEmpty, count(session) <= 256 else { throw HookError.malformed }
    var record: [String: Any] = ["hook_event_name": name, "session_id": session]
    for key in ["turn_id", "agent_id", "tool_use_id", "tool_name", "request_id"] {
        if let value = input[key] as? String, !value.isEmpty, count(value) <= 256 { record[key] = value }
    }
    if source == "codex", name == "PermissionRequest", let tool = input["tool_input"] as? [String: Any],
       let command = (tool["command"] ?? tool["cmd"]) as? String, !command.isEmpty, count(command) <= 65536 {
        let normalized = command.trimmingCharacters(in: .whitespacesAndNewlines)
        record["command_digest"] = SHA256.hash(data: Data(normalized.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    if source == "antigravity" {
        if let tool = input["toolCall"] as? [String: Any], let name = tool["name"] as? String, count(name) <= 256 {
            record["tool_name"] = name
        }
        if name == "Stop" {
            if let rawReason = input["terminationReason"] as? String {
                let mapping = ["ERROR": "error", "USER_CANCELED": "cancelled", "MAX_INVOCATIONS": "max_steps_exceeded",
                               "MAX_TOKEN_BUDGET_EXCEEDED": "max_steps_exceeded", "NO_TOOL_CALL": "model_stop"]
                let reason = mapping[rawReason] ?? rawReason
                if ["model_stop", "max_steps_exceeded", "error", "cancelled", "interrupted"].contains(reason) {
                    record["termination_reason"] = reason
                }
            }
            if let flag = input["fullyIdle"] as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID() {
                record["fully_idle"] = flag.boolValue
            } else {
                record["fully_idle"] = false
            }
            record["has_error"] = truthy(input["error"])
        }
    }
    return record
}

private func record(_ input: [String: Any], source: String, event: String?, directory: URL) throws {
    var record = try normalize(input, source: source, event: event)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    var info = stat()
    guard lstat(directory.path, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
          info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw HookError.unsafePath }
    let path = directory.appendingPathComponent(source + ".jsonl").path
    let fd = open(path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
    guard fd >= 0 else { throw HookError.fileOperation }
    defer { close(fd) }
    guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
          info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw HookError.unsafePath }
    let deadline = ProcessInfo.processInfo.systemUptime + 0.25
    while flock(fd, LOCK_EX | LOCK_NB) != 0 {
        guard errno == EWOULDBLOCK || errno == EAGAIN || errno == EINTR else { throw HookError.fileOperation }
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw HookError.timeout }
        usleep(5000)
    }
    defer { flock(fd, LOCK_UN) }
    record["received_at"] = Date().timeIntervalSince1970
    var data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .withoutEscapingSlashes])
    data.append(0x0a)
    var offset = 0
    while offset < data.count {
        let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: offset), data.count - offset) }
        if written < 0 && errno == EINTR { continue }
        guard written > 0 else { throw HookError.fileOperation }
        offset += written
    }
}

private func readInput() throws -> [String: Any] {
    var data = Data()
    while let chunk = try FileHandle.standardInput.read(upToCount: 65536), !chunk.isEmpty {
        data.append(chunk)
        guard data.count <= maxInput else { throw HookError.malformed }
    }
    guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw HookError.malformed }
    return result
}

private func argument(_ name: String) -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: name), index + 1 < CommandLine.arguments.count else { return nil }
    return CommandLine.arguments[index + 1]
}

let source = argument("--source") ?? ""
if CommandLine.arguments.contains("--install") || CommandLine.arguments.contains("--uninstall") {
    do {
        guard ["codex", "antigravity"].contains(source), let output = argument("--output") else { throw HookError.malformed }
        let configuration = URL(fileURLWithPath: output)
        if CommandLine.arguments.contains("--uninstall") {
            let changed = try NativeHookInstaller.uninstall(source: source, configuration: configuration)
            print(changed ? "AgentIsland hook removed; existing configuration was backed up." : "No AgentIsland hook registration found.")
        } else {
            let recorder = argument("--recorder-dir").map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AgentIsland/hooks", isDirectory: true)
            try NativeHookInstaller.install(source: source, configuration: configuration, recorderDirectory: recorder,
                                            executable: URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath())
            print("AgentIsland hook installed; reload the assistant if required.")
        }
    } catch {
        FileHandle.standardError.write(Data("AgentIsland hook configuration failed; existing configuration was not intentionally replaced.\n".utf8))
        exit(1)
    }
} else {
    let event = argument("--event")
    let path = argument("--directory").map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AgentIsland/events", isDirectory: true)
    do {
        guard ["codex", "antigravity"].contains(source) else { throw HookError.malformed }
        try record(readInput(), source: source, event: event, directory: path)
    } catch {
        FileHandle.standardError.write(Data("AgentIsland hook was not recorded\n".utf8))
    }
    let response = source == "antigravity" && event == "Stop" ? "{\"decision\":\"stop\"}\n" : "{}\n"
    FileHandle.standardOutput.write(Data(response.utf8))
}
