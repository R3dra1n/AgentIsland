import Foundation
import Security
import CryptoKit
import Darwin

/// Explicit-user-action transport. It only contacts loopback and pins the
/// server's observed certificate; it never logs or persists its CSRF token.
/// Process/port ownership checks reduce, but cannot eliminate, local races.
struct AntigravityLocalTransport {
    private static let executableSuffix = "/Contents/Resources/bin/language_server"
    private static let service = "/exa.language_server_pb.LanguageServerService/"
    private static let maximumResponse = 4 * 1024 * 1024

    // Other releases fail closed until their protocol and signing have been
    // checked. 2.28.0 remains experimental pending real reply verification.
    static func supportsVersion(_ version: String) -> Bool {
        ["2.27.0", "2.28.0"].contains(version)
    }

    struct Endpoint: Sendable { let pid: Int; let port: Int; let certificate: Data }
    enum Failure: Error { case unavailable, unsafe, unsupported, invalidResponse }
    private final class Capture: @unchecked Sendable { var bytes = Data(); var overflow = false }

    private static func command(_ executable: String, _ arguments: [String], timeout: TimeInterval = 3) throws -> Data {
        let process = Process(), output = Pipe(), input = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        try input.fileHandleForWriting.close()
        try output.fileHandleForWriting.close()
        let captured = Capture(), finished = DispatchGroup()
        finished.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { finished.leave() }
            while let chunk = try? output.fileHandleForReading.read(upToCount: 8192), !chunk.isEmpty {
                if captured.bytes.count + chunk.count <= 64 * 1024 { captured.bytes.append(chunk) }
                else { captured.overflow = true }
            }
        }
        let limit = ProcessInfo.processInfo.systemUptime + timeout
        while process.isRunning && ProcessInfo.processInfo.systemUptime < limit { usleep(10_000) }
        if process.isRunning {
            process.terminate()
            let grace = ProcessInfo.processInfo.systemUptime + 0.25
            while process.isRunning && ProcessInfo.processInfo.systemUptime < grace { usleep(10_000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            _ = finished.wait(timeout: .now() + 1)
            throw Failure.unavailable
        }
        process.waitUntilExit()
        guard finished.wait(timeout: .now() + 1) == .success else { throw Failure.unavailable }
        guard process.terminationStatus == 0, !captured.overflow else { throw Failure.unavailable }
        return captured.bytes
    }

    private static func text(_ executable: String, _ arguments: [String]) throws -> String {
        guard let value = String(data: try command(executable, arguments), encoding: .utf8) else { throw Failure.invalidResponse }
        return value
    }

    private static func server() throws -> (pid: Int, bundle: URL) {
        let result = try text("/bin/ps", ["-u", String(getuid()), "-o", "pid=,comm="])
        let matches: [(Int, URL)] = result.split(separator: "\n").compactMap { line in
            let bits = line.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
            guard bits.count == 2, let pid = Int(bits[0]), pid > 1 else { return nil }
            let path = URL(fileURLWithPath: String(bits[1])).standardizedFileURL.resolvingSymlinksInPath()
            guard path.path.hasSuffix(executableSuffix) else { return nil }
            let bundle = path.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            guard let metadata = Bundle(url: bundle), metadata.bundleIdentifier == "com.google.antigravity",
                  let version = metadata.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                  supportsVersion(version) else { return nil }
            return (pid, bundle)
        }
        guard matches.count == 1 else { throw Failure.unavailable }
        return (matches[0].0, matches[0].1)
    }

    private static func serverPID() throws -> Int { try server().pid }

    private static func validateSignature(_ bundle: URL) throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, SecCSFlags(), &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(), nil) == errSecSuccess else { throw Failure.unsafe }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let values = info as? [String: Any], values[kSecCodeInfoTeamIdentifier as String] as? String == "EQHXZ8M8AV" else { throw Failure.unsafe }
    }

    private static func ports(pid: Int) throws -> [Int] {
        let listing = try text("/usr/sbin/lsof", ["-nP", "-a", "-p", String(pid), "-iTCP", "-sTCP:LISTEN", "-F", "n"])
        return listing.split(separator: "\n").compactMap { line in
            guard line.hasPrefix("n127.0.0.1:"), let port = Int(line.dropFirst("n127.0.0.1:".count)), (1...65535).contains(port) else { return nil }
            return port
        }
    }

    private static func certificate(pid: Int, port: Int) throws -> Data {
        guard try serverPID() == pid, try ports(pid: pid).contains(port) else { throw Failure.unsafe }
        let value = try text("/usr/bin/openssl", ["s_client", "-connect", "127.0.0.1:\(port)", "-showcerts"])
        let begin = "-----BEGIN CERTIFICATE-----", end = "-----END CERTIFICATE-----"
        guard let start = value.range(of: begin), let finish = value.range(of: end, range: start.upperBound..<value.endIndex) else { throw Failure.unavailable }
        let body = String(value[start.upperBound..<finish.lowerBound]).filter { !$0.isWhitespace }
        guard let der = Data(base64Encoded: body), SecCertificateCreateWithData(nil, der as CFData) != nil,
              try serverPID() == pid, try ports(pid: pid).contains(port) else { throw Failure.unsafe }
        return der
    }

    private static func token(pid: Int) throws -> String {
        guard try serverPID() == pid else { throw Failure.unsafe }
        let args = try text("/bin/ps", ["-p", String(pid), "-o", "command="])
        let pattern = #"(?:^|\s)--csrf_token(?:=|\s+)([A-Fa-f0-9-]{36})(?:\s|$)"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(args.startIndex..., in: args)
        guard let match = regex.firstMatch(in: args, range: range), let tokenRange = Range(match.range(at: 1), in: args),
              UUID(uuidString: String(args[tokenRange])) != nil else { throw Failure.unavailable }
        return String(args[tokenRange])
    }

    static func discover() async throws -> Endpoint {
        let current = try server()
        try validateSignature(current.bundle)
        let pid = current.pid
        var candidates: [Endpoint] = []
        for port in try ports(pid: pid) {
            try Task.checkCancellation()
            guard let cert = try? certificate(pid: pid, port: port) else { continue }
            let endpoint = Endpoint(pid: pid, port: port, certificate: cert)
            if let result = try? await request(endpoint, method: "Heartbeat", data: Data("{}".utf8), credential: nil), result.status == 401 {
                candidates.append(endpoint)
            }
        }
        guard candidates.count == 1 else { throw Failure.unavailable }
        return candidates[0]
    }

    static func post(_ endpoint: Endpoint, method: String, data: Data) async throws -> Data {
        guard ["GetCascadeTrajectory", "HandleCascadeUserInteraction"].contains(method), data.count <= 64 * 1024 else { throw Failure.unsafe }
        try Task.checkCancellation()
        let credential = try token(pid: endpoint.pid)
        try Task.checkCancellation()
        let response = try await request(endpoint, method: method, data: data, credential: credential)
        guard response.status == 200, response.body.count <= maximumResponse else { throw Failure.invalidResponse }
        return response.body
    }

    private static func request(_ endpoint: Endpoint, method: String, data: Data, credential: String?) async throws -> (status: Int, body: Data) {
        guard try serverPID() == endpoint.pid, try ports(pid: endpoint.pid).contains(endpoint.port) else { throw Failure.unsafe }
        let result = try await PinnedLoopbackHTTP.post(port: endpoint.port, certificate: endpoint.certificate,
                                                        method: method, body: data, credential: credential)
        guard try serverPID() == endpoint.pid, try ports(pid: endpoint.pid).contains(endpoint.port) else { throw Failure.unsafe }
        return result
    }
}
