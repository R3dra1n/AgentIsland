import Foundation

/// Only options explicitly present in one observed question may use the
/// experimental background key path. This does not prove the target received it.
enum AntigravityReplyPolicy {
    static func permitsQueuedReply(_ text: String, prefixKey: String?, pendingSessions: Int,
                                   expectedDetail: String?, currentDetail: String?,
                                   expectedIdentity: AntigravityPendingIdentity?, currentIdentity: AntigravityPendingIdentity?) -> Bool {
        guard let expectedDetail, expectedDetail == currentDetail,
              let expectedIdentity, expectedIdentity == currentIdentity else { return false }
        return permitsNumericReply(text, prefixKey: prefixKey, pendingSessions: pendingSessions, detail: currentDetail)
    }

    static func permitsNumericReply(_ text: String, prefixKey: String?, pendingSessions: Int, detail: String?) -> Bool {
        guard text.count == 1, (1...9).contains(Int(text) ?? -1), prefixKey == nil,
              pendingSessions == 1, let detail else { return false }
        return detail.components(separatedBy: "\n").contains { $0.hasPrefix("   [\(text)] ") }
    }
}
