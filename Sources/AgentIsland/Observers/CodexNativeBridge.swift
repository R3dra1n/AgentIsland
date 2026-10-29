import Foundation
import Darwin

/// One connection is owned by one background worker. Only serialized Data crosses
/// the actor boundary; no socket or untyped JSON is shared between tasks.
final class CodexIPCTransport {
    static let maximumFrame = 32 * 1024 * 1024
    private var fd: Int32
    private let deadline: TimeInterval
    private static var clock: TimeInterval { ProcessInfo.processInfo.systemUptime }

    enum Failure: LocalizedError {
        case invalid(String)
        var errorDescription: String? { if case .invalid(let text) = self { return text }; return nil }
    }

    init(path: String, timeout: TimeInterval = 12) throws {
        var metadata = stat(), parent = stat()
        guard lstat(path, &metadata) == 0,
              stat(URL(fileURLWithPath: path).deletingLastPathComponent().path, &parent) == 0,
              metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK),
              metadata.st_uid == getuid(), parent.st_uid == getuid(), parent.st_mode & 0o022 == 0 else {
            throw Failure.invalid("Codex socket 不存在或所有者/权限不可信")
        }
        var address = sockaddr_un()
        let bytes = Array(path.utf8)
        guard !bytes.contains(0), bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw Failure.invalid("Codex socket 路径过长")
        }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(2 + bytes.count + 1)
        let addressLength = socklen_t(address.sun_len)
        withUnsafeMutableBytes(of: &address.sun_path) { storage in
            storage.copyBytes(from: bytes + [0])
        }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw Failure.invalid("无法创建 Codex socket") }
        fd = descriptor
        deadline = Self.clock + timeout
        do {
            try configure()
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, addressLength)
                }
            }
            if result != 0 {
                guard errno == EINPROGRESS || errno == EWOULDBLOCK else { throw Failure.invalid("无法连接 Codex，请确认桌面端正在运行") }
                try wait(POLLOUT, until: min(deadline, Self.clock + 3))
                var error: Int32 = 0
                var length = socklen_t(MemoryLayout<Int32>.size)
                guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0 else {
                    throw Failure.invalid("Codex socket 连接失败")
                }
            }
        } catch {
            Darwin.close(descriptor)
            fd = -1
            throw error
        }
    }

    /// Owns an already connected descriptor; used by local socket-pair tests.
    init(connectedSocket: Int32, timeout: TimeInterval = 12) throws {
        fd = connectedSocket
        deadline = Self.clock + timeout
        do { try configure() } catch { Darwin.close(fd); fd = -1; throw error }
    }
    deinit { if fd >= 0 { Darwin.close(fd) } }

    private func configure() throws {
        var yes: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout.size(ofValue: yes))) == 0,
              fcntl(fd, F_SETFL, O_NONBLOCK) == 0,
              fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { throw Failure.invalid("无法配置 Codex socket") }
    }

    private func wait(_ events: Int32, until limit: TimeInterval) throws {
        while true {
            let remaining = min(deadline, limit) - Self.clock
            guard remaining > 0 else { throw Failure.invalid("Codex 通信超时，请重试或在原应用处理") }
            var descriptor = pollfd(fd: fd, events: Int16(events), revents: 0)
            let result = poll(&descriptor, 1, Int32(max(1, min(remaining * 1000, 3000))))
            if result < 0 && errno == EINTR { continue }
            guard result >= 0 else { throw Failure.invalid("Codex socket 读取失败") }
            if result == 0 { continue }
            guard Int32(descriptor.revents) & POLLNVAL == 0 else { throw Failure.invalid("Codex socket 已关闭") }
            // POLLHUP may accompany readable final bytes: recv decides whether EOF occurred.
            return
        }
    }

    private func readExactly(_ count: Int, until limit: TimeInterval) throws -> Data {
        var data = Data(count: count)
        var offset = 0
        while offset < count {
            try wait(POLLIN, until: limit)
            let received = data.withUnsafeMutableBytes {
                Darwin.recv(fd, $0.baseAddress!.advanced(by: offset), count - offset, 0)
            }
            if received < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) { continue }
            guard received > 0 else { throw Failure.invalid("Codex 连接已关闭") }
            offset += received
        }
        return data
    }

    func send(_ object: [String: Any], until limit: TimeInterval = .greatestFiniteMagnitude) throws {
        let body = try CodexNativeBridge.encode(object)
        guard body.count <= Self.maximumFrame else { throw Failure.invalid("Codex 消息过大") }
        var length = UInt32(body.count).littleEndian
        var frame = withUnsafeBytes(of: &length) { Data($0) }
        frame.append(body)
        var offset = 0
        while offset < frame.count {
            try wait(POLLOUT, until: limit)
            let written = frame.withUnsafeBytes {
                Darwin.send(fd, $0.baseAddress!.advanced(by: offset), frame.count - offset, 0)
            }
            if written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) { continue }
            guard written > 0 else { throw Failure.invalid("Codex 消息发送失败；请核对原应用状态") }
            offset += written
        }
    }

    func receive(until limit: TimeInterval = .greatestFiniteMagnitude) throws -> [String: Any] {
        let header = try readExactly(4, until: limit)
        let length = header.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) }
        guard length > 0, length <= Self.maximumFrame else { throw Failure.invalid("Codex 消息长度无效或过大") }
        let body = try readExactly(Int(length), until: limit)
        guard let object = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw Failure.invalid("Codex 消息格式无效")
        }
        return object
    }
}

private final class CodexIPCSession {
    let thread: String
    let transport: CodexIPCTransport
    var client = "initializing-client"
    var owner: String?
    var state: [String: Any]?

    init(thread: String, transport: CodexIPCTransport) throws {
        self.thread = thread
        self.transport = transport
        let result = try request("initialize", params: ["clientType": "agent-island"], version: 0)
        guard let client = result["clientId"] as? String else { throw CodexIPCTransport.Failure.invalid("Codex 握手缺少客户端标识") }
        self.client = client
        try transport.send(["type": "broadcast", "sourceClientId": client, "version": 1,
                            "method": "thread-stream-following-changed",
                            "params": ["conversationId": thread, "hostId": "local", "following": true]])
        let limit = ProcessInfo.processInfo.systemUptime + 4
        while state == nil { _ = try receive(until: limit) }
    }

    private func receive(until limit: TimeInterval) throws -> [String: Any] {
        let object = try transport.receive(until: limit)
        if object["type"] as? String == "client-discovery-request", let id = object["requestId"] {
            try transport.send(["type": "client-discovery-response", "requestId": id,
                                "response": ["canHandle": false]], until: limit)
        }
        if object["method"] as? String == "thread-stream-state-changed",
           let params = object["params"] as? [String: Any], params["conversationId"] as? String == thread,
           (params["hostId"] as? String ?? "local") == "local",
           let change = params["change"] as? [String: Any], change["type"] as? String == "snapshot",
           let value = change["conversationState"] as? [String: Any],
           let owner = object["sourceClientId"] as? String {
            state = value
            self.owner = owner
        }
        return object
    }

    func request(_ method: String, params: [String: Any], version: Int = 1) throws -> [String: Any] {
        let id = UUID().uuidString
        var message: [String: Any] = ["type": "request", "requestId": id, "sourceClientId": client,
                                      "method": method, "params": params, "version": version, "timeoutMs": 4000]
        if let owner { message["targetClientId"] = owner }
        let limit = ProcessInfo.processInfo.systemUptime + 5
        try transport.send(message, until: limit)
        while true {
            let object = try receive(until: limit)
            guard object["type"] as? String == "response", object["requestId"] as? String == id else { continue }
            guard object["resultType"] as? String == "success" else {
                throw CodexIPCTransport.Failure.invalid("Codex 未接受操作：\(object["error"] ?? "未知错误")")
            }
            return object["result"] as? [String: Any] ?? [:]
        }
    }
}

/// Native equivalent of the frozen Python adapter. Parsing stays independent of
/// transport so real protocol edge cases can be tested without approving actions.
enum CodexNativeBridge {
    static func encode(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
    }
    static func turns(_ state: [String: Any]) -> [[String: Any]] {
        if let history = state["turnHistory"] as? [String: Any], history["kind"] as? String == "canonical" {
            let store = history["history"] as? [String: Any] ?? [:]
            return Array((store["entitiesByKey"] as? [String: [String: Any]] ?? [:]).values)
        }
        return state["turns"] as? [[String: Any]] ?? []
    }
    static func items(_ state: [String: Any], activeOnly: Bool = false) -> [[String: Any]] {
        turns(state).filter { !activeOnly || $0["status"] as? String == "inProgress" }
            .flatMap { $0["items"] as? [[String: Any]] ?? [] }
    }
    static func latestTurn(_ state: [String: Any]) -> [String: Any] {
        turns(state).filter { $0["turnId"] as? String != nil }
            .max { ($0["turnStartedAtMs"] as? NSNumber)?.doubleValue ?? 0 < ($1["turnStartedAtMs"] as? NSNumber)?.doubleValue ?? 0 } ?? [:]
    }
    static func executionState(_ state: [String: Any]) -> String {
        let runtime = (state["threadRuntimeStatus"] as? [String: Any])?["type"] as? String
        if runtime == "active" { return "running" }
        guard runtime == "idle" else { return "unknown" }
        let status = latestTurn(state)["status"] as? String ?? "idle"
        return ["completed", "failed", "interrupted"].contains(status) ? status : "idle"
    }

    static func pending(_ state: [String: Any]) throws -> [[String: Any]] {
        var output: [[String: Any]] = []
        for request in state["requests"] as? [[String: Any]] ?? [] {
            guard let method = request["method"] as? String,
                  ["item/tool/requestUserInput", "item/commandExecution/requestApproval", "item/fileChange/requestApproval"].contains(method),
                  let rawID = request["id"], rawID is String || rawID is NSNumber,
                  let params = request["params"] as? [String: Any] else { continue }
            if method == "item/commandExecution/requestApproval", let available = params["availableDecisions"], !(available is NSNull) {
                guard let decisions = available as? [String], decisions.contains("accept"), decisions.contains("decline") else { continue }
            }
            let questions = method == "item/tool/requestUserInput" ? params["questions"] as? [[String: Any]] ?? [] : []
            let normalized: [[String: Any]] = questions.compactMap { q in
                guard let id = q["id"] as? String, let title = q["question"] as? String else { return nil }
                return ["id": id, "title": title, "options": (q["options"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String }]
            }
            // Malformed question requests must not become approval buttons.
            if method == "item/tool/requestUserInput" && (normalized.isEmpty || normalized.count != questions.count) { continue }
            output.append(["requestID": String(describing: rawID), "rawID": rawID, "method": method,
                           "context": params["reason"] as? String ?? params["command"] as? String ?? "Codex 请求确认",
                           "questions": normalized])
        }
        var answered = Set<String>()
        let prefix = "<send_user_message_question_reply>", suffix = "</send_user_message_question_reply>"
        for item in items(state) {
            guard let kind = item["type"] as? String, ["userMessage", "steeringUserMessage"].contains(kind),
                  kind != "steeringUserMessage" || item["status"] as? String == "accepted" else { continue }
            let content = item["content"] as? [[String: Any]] ?? item["input"] as? [[String: Any]] ?? []
            guard content.count == 1, content[0]["type"] as? String == "text", let raw = content[0]["text"] as? String else { continue }
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.hasPrefix(prefix), text.hasSuffix(suffix), text.count >= prefix.count + suffix.count else { continue }
            let body = String(text.dropFirst(prefix.count).dropLast(suffix.count))
            guard let value = try? JSONSerialization.jsonObject(with: Data(body.utf8)) else { continue }
            let replies = value as? [[String: Any]] ?? (value as? [String: Any]).map { [$0] } ?? []
            answered.formUnion(replies.compactMap { $0["questionItemId"] as? String })
        }
        for item in items(state, activeOnly: true) {
            guard item["type"] as? String == "agentMessage", item["delivery"] as? String == "async",
                  let id = item["id"] as? String, let questions = item["questions"] as? [[String: Any]] else { continue }
            for (index, question) in questions.enumerated() {
                guard let title = question["title"] as? String else { continue }
                let qid = String(decoding: try encode(["request_user_input_async", id, index]), as: UTF8.self)
                guard !answered.contains(qid) else { continue }
                output.append(["requestID": qid, "rawID": qid, "method": "async-question", "context": title,
                               "questions": [["id": qid, "title": title, "options": question["options"] as? [String] ?? []]]])
            }
        }
        return output
    }

    static func replyRequest(_ command: [String: Any], state: [String: Any], thread: String) throws -> (String, [String: Any]) {
        let matches = try pending(state).filter { $0["requestID"] as? String == command["requestID"] as? String }
        guard matches.count == 1, let request = matches.first, let rawID = request["rawID"], let method = request["method"] as? String else {
            throw CodexIPCTransport.Failure.invalid("请求已过期或无法唯一识别")
        }
        var params: [String: Any] = ["conversationId": thread, "requestId": rawID]
        let questions = request["questions"] as? [[String: Any]] ?? []
        if !questions.isEmpty {
            let answers = command["answers"] as? [String: String] ?? [:]
            guard Set(answers.keys) == Set(questions.compactMap { $0["id"] as? String }),
                  answers.values.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                throw CodexIPCTransport.Failure.invalid("请回答全部问题")
            }
            if method == "async-question" {
                let replies = questions.map { q in ["questionItemId": q["id"]!, "question": q["title"]!, "answer": answers[q["id"] as! String]!] }
                let text = "<send_user_message_question_reply>\n" + String(decoding: try encode(replies), as: UTF8.self) + "\n</send_user_message_question_reply>"
                let clientID = UUID().uuidString
                let restore: [String: Any] = ["id": clientID, "cwd": state["cwd"] ?? NSNull(), "context": [
                    "prompt": text, "turnTrigger": "send_user_message_async_question", "addedFiles": [], "fileAttachments": [],
                    "imageAttachments": [], "commentAttachments": [], "ideContext": NSNull()] as [String: Any]]
                return ("thread-follower-steer-turn", ["conversationId": thread,
                    "input": [["type": "text", "text": text, "text_elements": []] as [String: Any]],
                    "clientUserMessageId": clientID, "restoreMessage": restore])
            }
            params["response"] = ["answers": answers.mapValues { ["answers": [$0]] }]
            return ("thread-follower-submit-user-input", params)
        }
        guard let decision = command["decision"] as? String, ["accept", "decline"].contains(decision) else {
            throw CodexIPCTransport.Failure.invalid("无效的审批选项")
        }
        params["decision"] = decision
        return (method == "item/commandExecution/requestApproval" ? "thread-follower-command-approval-decision" : "thread-follower-file-approval-decision", params)
    }

    static func run(_ input: Data, transport: CodexIPCTransport? = nil) throws -> Data {
        guard let command = try JSONSerialization.jsonObject(with: input) as? [String: Any],
              let thread = command["sessionID"] as? String, !thread.isEmpty else { throw CodexIPCTransport.Failure.invalid("缺少 Codex 会话标识") }
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path
        let connection = try transport ?? CodexIPCTransport(path: URL(fileURLWithPath: home).appendingPathComponent("ipc/ipc.sock").path)
        let session = try CodexIPCSession(thread: thread, transport: connection)
        guard let state = session.state else { throw CodexIPCTransport.Failure.invalid("Codex 未提供任务快照") }
        if command["action"] as? String == "reply" {
            let (method, params) = try replyRequest(command, state: state, thread: thread)
            _ = try session.request(method, params: params)
            return try encode(["ok": true, "message": "Codex 已接收操作；等待状态更新"])
        }
        let latest = latestTurn(state)
        return try encode(["ok": true, "requests": pending(state),
                           "runtime": (state["threadRuntimeStatus"] as? [String: Any])?["type"] ?? "unknown",
                           "activity": executionState(state), "turnID": latest["turnId"] ?? NSNull(),
                           "turnStartedAtMs": latest["turnStartedAtMs"] ?? NSNull()])
    }
}
