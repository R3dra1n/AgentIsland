import Foundation

public struct CodexPendingRequest: Equatable, Sendable, Identifiable {
    public let sessionID: String
    public let turnID: String?
    public let requestID: String
    public let isQuestion: Bool
    public let context: String?
    public var commandDigest: String? = nil
    public var questions: [CodexQuestion] = []
    public var desktopMethod: String? = nil
    public var id: String { "\(sessionID)/\(turnID ?? "")/\(requestID)" }
}
