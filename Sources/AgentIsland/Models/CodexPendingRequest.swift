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
    /// An async question remains pending until an explicit user reply, even
    /// when the desktop IPC no longer lists the short-lived tool invocation.
    public var isAsynchronous: Bool = false
    public var id: String { "\(sessionID)/\(turnID ?? "")/\(requestID)" }
}
