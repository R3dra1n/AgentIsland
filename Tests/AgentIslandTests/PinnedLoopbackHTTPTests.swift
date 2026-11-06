import Foundation
import XCTest
@testable import AgentIsland

/// TLS integration tests use short-lived local-only Python servers, generated
/// certificates and synthetic credentials. They never access real assistants.
final class PinnedLoopbackHTTPTests: XCTestCase {
    private static let syntheticToken = "synthetic-test-token"
    private static let script = #"""
import json, os, ssl, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
cert, key, portfile, hitfile, mode, target = sys.argv[1:]
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_POST(self):
        size = int(self.headers.get('Content-Length', '0'))
        self.rfile.read(size)
        with open(hitfile, 'a', encoding='utf-8') as f:
            f.write(json.dumps({'token': self.headers.get('X-Codeium-Csrf-Token'), 'path': self.path}) + '\n')
        if mode == 'redirect':
            self.send_response(307)
            self.send_header('Location', 'https://127.0.0.1:' + target + '/redirect-target')
            self.send_header('Content-Length', '0')
            self.end_headers()
        elif mode == 'oversized-declared':
            self.send_response(200)
            self.send_header('Content-Length', str(4 * 1024 * 1024 + 1))
            self.end_headers()
        elif mode == 'large':
            total = 6 * 1024 * 1024
            self.send_response(200)
            self.send_header('Content-Length', str(total))
            self.end_headers()
            sent = 0
            try:
                while sent < total:
                    n = min(65536, total - sent)
                    self.wfile.write(b'x' * n)
                    sent += n
            except (BrokenPipeError, ConnectionResetError, ssl.SSLError): pass
        elif mode == 'oversized-stream':
            self.send_response(200)
            self.send_header('Connection', 'close')
            self.end_headers()
            try:
                for _ in range(65): self.wfile.write(b'x' * 65536)
            except (BrokenPipeError, ConnectionResetError, ssl.SSLError): pass
        elif mode == 'slow-drip':
            self.send_response(200)
            self.send_header('Connection', 'close')
            self.end_headers()
            try:
                for _ in range(120):
                    self.wfile.write(b'x')
                    self.wfile.flush()
                    time.sleep(0.25)
            except (BrokenPipeError, ConnectionResetError, ssl.SSLError): pass
        else:
            body = b'{"ok":true}'
            self.send_response(200)
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(cert, key)
server.socket = context.wrap_socket(server.socket, server_side=True)
with open(portfile, 'w', encoding='utf-8') as f: f.write(str(server.server_port))
server.serve_forever()
"""#

    private struct Certificate {
        let certificateURL: URL
        let keyURL: URL
        let der: Data
    }

    private final class Fixture {
        let directory: URL
        private var servers: [Process] = []

        init() throws {
            guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3"),
                  FileManager.default.isExecutableFile(atPath: "/usr/bin/openssl") else {
                throw XCTSkip("Local TLS test requires developer Python 3 and OpenSSL")
            }
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("agentisland-tls-test-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }

        deinit {
            for server in servers {
                if server.isRunning { server.terminate() }
                server.waitUntilExit()
            }
            try? FileManager.default.removeItem(at: directory)
        }

        func certificate(_ label: String) throws -> Certificate {
            let certificateURL = directory.appendingPathComponent(label + ".pem")
            let keyURL = directory.appendingPathComponent(label + ".key")
            let command = Process()
            command.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
            command.arguments = ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                                 "-subj", "/CN=agentisland-local-test", "-keyout", keyURL.path,
                                 "-out", certificateURL.path]
            command.standardInput = FileHandle.nullDevice
            command.standardOutput = FileHandle.nullDevice
            command.standardError = FileHandle.nullDevice
            try command.run()
            command.waitUntilExit()
            guard command.terminationStatus == 0 else { throw XCTSkip("Could not create an ephemeral test certificate") }
            let pem = try String(contentsOf: certificateURL, encoding: .utf8)
            let body = pem.replacingOccurrences(of: "-----BEGIN CERTIFICATE-----", with: "")
                .replacingOccurrences(of: "-----END CERTIFICATE-----", with: "")
                .filter { !$0.isWhitespace }
            guard let der = Data(base64Encoded: body) else { throw NSError(domain: "AgentIslandTLSTest", code: 1) }
            return Certificate(certificateURL: certificateURL, keyURL: keyURL, der: der)
        }

        func server(_ certificate: Certificate, mode: String, target: Int = 0) throws -> (port: Int, hits: URL) {
            let name = UUID().uuidString
            let portfile = directory.appendingPathComponent(name + ".port")
            let hitfile = directory.appendingPathComponent(name + ".hits")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = ["-u", "-c", PinnedLoopbackHTTPTests.script, certificate.certificateURL.path,
                                 certificate.keyURL.path, portfile.path, hitfile.path, mode, String(target)]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            servers.append(process)
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline && process.isRunning {
                if let value = try? String(contentsOf: portfile, encoding: .utf8), let port = Int(value) {
                    return (port, hitfile)
                }
                Thread.sleep(forTimeInterval: 0.02)
            }
            throw NSError(domain: "AgentIslandTLSTest", code: 2)
        }

        func hits(_ url: URL) throws -> [[String: Any]] {
            guard FileManager.default.fileExists(atPath: url.path) else { return [] }
            let contents = try String(contentsOf: url, encoding: .utf8)
            return try contents.split(separator: "\n").map {
                guard let entry = try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] else {
                    throw NSError(domain: "AgentIslandTLSTest", code: 3)
                }
                return entry
            }
        }
    }

    func testPinnedCertificateAcceptsOnlyLocalServer() async throws {
        let fixture = try Fixture()
        let certificate = try fixture.certificate("valid")
        let server = try fixture.server(certificate, mode: "normal")
        let result = try await PinnedLoopbackHTTP.post(port: server.port, certificate: certificate.der,
            method: "Heartbeat", body: Data("{}".utf8), credential: Self.syntheticToken)
        XCTAssertEqual(result.status, 200)
        XCTAssertEqual(result.body, Data("{\"ok\":true}".utf8))
        let hits = try fixture.hits(server.hits)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?["token"] as? String, Self.syntheticToken)
    }

    func testWrongCertificateRejectsWithoutSendingCredential() async throws {
        let fixture = try Fixture()
        let serverCertificate = try fixture.certificate("server")
        let otherCertificate = try fixture.certificate("other")
        let server = try fixture.server(serverCertificate, mode: "normal")
        do {
            _ = try await PinnedLoopbackHTTP.post(port: server.port, certificate: otherCertificate.der,
                method: "Heartbeat", body: Data("{}".utf8), credential: Self.syntheticToken)
            XCTFail("A different certificate must not be trusted")
        } catch {}
        XCTAssertTrue(try fixture.hits(server.hits).isEmpty)
    }

    func testDeclaredAndStreamingOversizedResponsesAreRejected() async throws {
        let fixture = try Fixture()
        let certificate = try fixture.certificate("valid")
        for mode in ["oversized-declared", "oversized-stream"] {
            let server = try fixture.server(certificate, mode: mode)
            do {
                _ = try await PinnedLoopbackHTTP.post(port: server.port, certificate: certificate.der,
                    method: "GetCascadeTrajectory", body: Data("{}".utf8), credential: nil,
                    maximumResponse: 4 * 1024 * 1024)
                XCTFail("A response larger than the configured cap must be rejected (\(mode))")
            } catch {}
        }
    }

    // A conversation's trajectory grows with every step; a real one reached
    // 56 MB. The default cap must let a response far above the old 4 MiB limit
    // through, both with a declared length and when streamed without one.
    func testDefaultCapAcceptsResponsesAboveTheOldFourMebibyteLimit() async throws {
        let fixture = try Fixture()
        let certificate = try fixture.certificate("valid")
        XCTAssertGreaterThanOrEqual(PinnedLoopbackHTTP.maximumResponse, 56 * 1024 * 1024,
                                    "上限必须高于已观察到的最大 trajectory（56 MB）")
        let declared = try fixture.server(certificate, mode: "large")
        let large = try await PinnedLoopbackHTTP.post(port: declared.port, certificate: certificate.der,
            method: "GetCascadeTrajectory", body: Data("{}".utf8), credential: nil)
        XCTAssertEqual(large.status, 200)
        XCTAssertEqual(large.body.count, 6 * 1024 * 1024)

        let streamed = try fixture.server(certificate, mode: "oversized-stream")
        let result = try await PinnedLoopbackHTTP.post(port: streamed.port, certificate: certificate.der,
            method: "GetCascadeTrajectory", body: Data("{}".utf8), credential: nil)
        XCTAssertEqual(result.body.count, 65 * 65536)
    }

    // The cap is inclusive: exactly the cap is accepted and one byte more is
    // refused, so raising it never silently turns into "no limit".
    func testCapBoundaryIsExactForStreamedResponses() async throws {
        let fixture = try Fixture()
        let certificate = try fixture.certificate("valid")
        let exact = 65 * 65536
        let atLimit = try fixture.server(certificate, mode: "oversized-stream")
        let accepted = try await PinnedLoopbackHTTP.post(port: atLimit.port, certificate: certificate.der,
            method: "GetCascadeTrajectory", body: Data("{}".utf8), credential: nil, maximumResponse: exact)
        XCTAssertEqual(accepted.body.count, exact)

        let overLimit = try fixture.server(certificate, mode: "oversized-stream")
        do {
            _ = try await PinnedLoopbackHTTP.post(port: overLimit.port, certificate: certificate.der,
                method: "GetCascadeTrajectory", body: Data("{}".utf8), credential: nil, maximumResponse: exact - 1)
            XCTFail("One byte over the cap must be rejected")
        } catch PinnedLoopbackHTTP.Failure.invalidResponse {
        } catch { XCTFail("Expected the cap failure, got \(error)") }
    }

    func testCapRejectsADeclaredLengthWithoutReadingTheBody() async throws {
        let fixture = try Fixture()
        let certificate = try fixture.certificate("valid")
        let server = try fixture.server(certificate, mode: "large")
        do {
            _ = try await PinnedLoopbackHTTP.post(port: server.port, certificate: certificate.der,
                method: "GetCascadeTrajectory", body: Data("{}".utf8), credential: nil,
                maximumResponse: 1024 * 1024)
            XCTFail("A declared length above the cap must be rejected")
        } catch PinnedLoopbackHTTP.Failure.unsafe {
        } catch { XCTFail("Expected the declared-length failure, got \(error)") }
    }

    func testRedirectIsNotFollowedAndCredentialDoesNotReachSecondServer() async throws {
        let fixture = try Fixture()
        // Both servers intentionally use the same certificate, so rejecting the
        // redirect is the boundary being tested rather than certificate mismatch.
        let certificate = try fixture.certificate("shared")
        let target = try fixture.server(certificate, mode: "normal")
        let source = try fixture.server(certificate, mode: "redirect", target: target.port)
        do {
            let response = try await PinnedLoopbackHTTP.post(port: source.port, certificate: certificate.der,
                method: "Heartbeat", body: Data("{}".utf8), credential: Self.syntheticToken)
            XCTAssertEqual(response.status, 307)
        } catch {
            // Rejecting a redirect by throwing is also safe.
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        let sourceHits = try fixture.hits(source.hits)
        let targetHits = try fixture.hits(target.hits)
        XCTAssertEqual(sourceHits.count, 1)
        XCTAssertEqual(sourceHits.first?["token"] as? String, Self.syntheticToken)
        XCTAssertTrue(targetHits.isEmpty)
    }

    func testUnlistedRPCIsRejectedBeforeAnyRequest() async throws {
        let fixture = try Fixture()
        let certificate = try fixture.certificate("valid")
        let server = try fixture.server(certificate, mode: "normal")
        do {
            _ = try await PinnedLoopbackHTTP.post(port: server.port, certificate: certificate.der,
                method: "UnlistedMethod", body: Data("{}".utf8), credential: Self.syntheticToken)
            XCTFail("Unlisted RPC method must be rejected")
        } catch {}
        XCTAssertTrue(try fixture.hits(server.hits).isEmpty)
    }

    func testResourceTimeoutRejectsContinuouslyDrippingResponse() async throws {
        let fixture = try Fixture()
        let certificate = try fixture.certificate("slow")
        let server = try fixture.server(certificate, mode: "slow-drip")
        let port = server.port, der = certificate.der, token = Self.syntheticToken
        let start = ProcessInfo.processInfo.systemUptime
        let request = Task { () -> Int? in
            do {
                _ = try await PinnedLoopbackHTTP.post(port: port, certificate: der,
                    method: "GetCascadeTrajectory", body: Data("{}".utf8), credential: token,
                    resourceTimeout: 10)
                return nil
            } catch {
                return (error as? URLError)?.code.rawValue
            }
        }
        // A failed resource timeout must not hang the test runner indefinitely.
        let watchdog = Task {
            do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { return }
            request.cancel()
        }
        let errorCode = await request.value
        watchdog.cancel()
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        XCTAssertEqual(errorCode, URLError.timedOut.rawValue, "The total timeout must fire even as bytes keep arriving")
        XCTAssertGreaterThan(elapsed, 7, "An earlier failure does not establish the resource timeout")
        XCTAssertLessThan(elapsed, 14, "The 15-second watchdog should not be needed")
        XCTAssertEqual(try fixture.hits(server.hits).count, 1)
    }
}
