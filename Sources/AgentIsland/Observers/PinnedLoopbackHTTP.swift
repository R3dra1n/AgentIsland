import Foundation
import Security
import CryptoKit

enum PinnedLoopbackHTTP {
    /// Largest response accepted from the local language server.
    ///
    /// A long conversation's trajectory is one JSON document holding every step
    /// ever taken, so it grows without bound: one real conversation reached
    /// 56 MB at about 7,000 steps. The previous 4 MB cap made every long
    /// conversation fail with "cannot read this session's question". This is
    /// the single source of truth: the transport, the transport wrapper and the
    /// parser all refer to it, so they cannot drift apart again.
    ///
    /// The cap still bounds memory, because the parsed object graph is several
    /// times the size of the JSON text.
    static let maximumResponse = 128 * 1024 * 1024
    /// Total time for one exchange. Sized so that a response of the maximum
    /// size, which the server must serialize before sending, can complete,
    /// while a peer that keeps dripping bytes is still cut off.
    static let resourceTimeout: TimeInterval = 30
    enum Failure: Error { case unsafe, invalidResponse }

    static func post(port: Int, certificate: Data, method: String, body bodyData: Data, credential: String?,
                     maximumResponse limit: Int = PinnedLoopbackHTTP.maximumResponse,
                     resourceTimeout: TimeInterval = PinnedLoopbackHTTP.resourceTimeout) async throws -> (status: Int, body: Data) {
        guard (1...65535).contains(port), ["Heartbeat", "GetCascadeTrajectory", "HandleCascadeUserInteraction"].contains(method),
              bodyData.count <= 64 * 1024, limit > 0,
              let url = URL(string: "https://127.0.0.1:\(port)/exa.language_server_pb.LanguageServerService/\(method)") else { throw Failure.unsafe }
        let configuration = URLSessionConfiguration.ephemeral
        // The request timeout is the longest silence between packets; the
        // resource timeout bounds the whole exchange.
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.urlCache = nil; configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
        configuration.connectionProxyDictionary = ["HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0,
                                                   "ProxyAutoConfigEnable": 0, "ProxyAutoDiscoveryEnable": 0]
        let exchange = Exchange(certificate, port: port, limit: limit)
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: exchange, delegateQueue: queue)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url); request.httpMethod = "POST"; request.httpBody = bodyData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let credential { request.setValue(credential, forHTTPHeaderField: "X-Codeium-Csrf-Token") }
        try Task.checkCancellation()
        let task = session.dataTask(with: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                exchange.start(task, continuation)
            }
        } onCancel: {
            task.cancel()
        }
    }

    /// Receives the response in chunks. Reading one byte at a time through
    /// `URLSession.AsyncBytes` is far too slow once a response reaches tens of
    /// megabytes, so the delegate accumulates whole chunks and enforces the
    /// cap as they arrive, cancelling the moment it would be exceeded.
    private final class Exchange: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let digest: SHA256.Digest
        private let port: Int
        private let limit: Int
        private let lock = NSLock()
        private var body = Data()
        private var status = 0
        private var failure: Error?
        private var continuation: CheckedContinuation<(status: Int, body: Data), Error>?

        init(_ certificate: Data, port: Int, limit: Int) {
            digest = SHA256.hash(data: certificate); self.port = port; self.limit = limit
        }

        func start(_ task: URLSessionDataTask, _ continuation: CheckedContinuation<(status: Int, body: Data), Error>) {
            lock.lock(); self.continuation = continuation; lock.unlock()
            task.resume()
        }

        private func fail(_ error: Error) {
            lock.lock(); if failure == nil { failure = error }; lock.unlock()
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
            guard let http = response as? HTTPURLResponse else {
                fail(Failure.unsafe); completionHandler(.cancel); return
            }
            lock.lock(); status = http.statusCode; lock.unlock()
            // A declared length over the cap is refused before any body arrives.
            // The length is -1 when unknown, as with chunked transfer encoding.
            guard http.expectedContentLength <= Int64(limit) else {
                fail(Failure.unsafe); completionHandler(.cancel); return
            }
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            lock.lock()
            let exceeded = body.count + data.count > limit
            if !exceeded { body.append(data) }
            lock.unlock()
            if exceeded { fail(Failure.invalidResponse); dataTask.cancel() }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            lock.lock()
            let pending = continuation; continuation = nil
            let recorded = failure, received = body, code = status
            lock.unlock()
            guard let pending else { return }
            // The recorded failure is the real cause; cancelling the task to
            // enforce it would otherwise surface as a generic "cancelled".
            if let recorded { pending.resume(throwing: recorded) }
            else if let error { pending.resume(throwing: error) }
            else { pending.resume(returning: (code, received)) }
        }

        func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            evaluate(challenge, completionHandler: completionHandler)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            evaluate(challenge, completionHandler: completionHandler)
        }

        private func evaluate(_ challenge: URLAuthenticationChallenge,
                              completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            guard challenge.protectionSpace.host == "127.0.0.1", challenge.protectionSpace.port == port,
                  challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                  let trust = challenge.protectionSpace.serverTrust,
                  let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let first = chain.first,
                  SHA256.hash(data: SecCertificateCopyData(first) as Data) == digest else {
                completionHandler(.cancelAuthenticationChallenge, nil); return
            }
            completionHandler(.useCredential, URLCredential(trust: trust))
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
