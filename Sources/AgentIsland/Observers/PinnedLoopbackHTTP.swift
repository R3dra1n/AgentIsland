import Foundation
import Security
import CryptoKit

enum PinnedLoopbackHTTP {
    private static let maximumResponse = 4 * 1024 * 1024
    enum Failure: Error { case unsafe, invalidResponse }

    static func post(port: Int, certificate: Data, method: String, body bodyData: Data, credential: String?) async throws -> (status: Int, body: Data) {
        guard (1...65535).contains(port), ["Heartbeat", "GetCascadeTrajectory", "HandleCascadeUserInteraction"].contains(method),
              bodyData.count <= 64 * 1024,
              let url = URL(string: "https://127.0.0.1:\(port)/exa.language_server_pb.LanguageServerService/\(method)") else { throw Failure.unsafe }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 10
        configuration.urlCache = nil; configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
        configuration.connectionProxyDictionary = ["HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0,
                                                   "ProxyAutoConfigEnable": 0, "ProxyAutoDiscoveryEnable": 0]
        let delegate = CertificatePin(certificate, port: port)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url); request.httpMethod = "POST"; request.httpBody = bodyData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let credential { request.setValue(credential, forHTTPHeaderField: "X-Codeium-Csrf-Token") }
        try Task.checkCancellation()
        let (bytes, response) = try await session.bytes(for: request, delegate: delegate)
        guard let http = response as? HTTPURLResponse,
              http.expectedContentLength <= Int64(maximumResponse) else { throw Failure.unsafe }
        var responseBody = Data()
        for try await byte in bytes {
            guard responseBody.count < maximumResponse else { throw Failure.invalidResponse }
            responseBody.append(byte)
        }
        return (http.statusCode, responseBody)
    }

    private final class CertificatePin: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let digest: SHA256.Digest
        private let port: Int
        init(_ certificate: Data, port: Int) { digest = SHA256.hash(data: certificate); self.port = port }
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
