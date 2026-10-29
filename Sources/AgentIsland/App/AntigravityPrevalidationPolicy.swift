import Foundation

struct AntigravityPrevalidationTarget: Equatable, Sendable {
    let identity: AntigravityPendingIdentity
    let detail: String
}

enum AntigravityPrevalidationPolicy {
    static func target(for session: AntigravitySessionSnapshot) -> AntigravityPrevalidationTarget? {
        guard session.state == .awaitingInput, let identity = session.pendingIdentity,
              let detail = session.actionDetail else { return nil }
        return .init(identity: identity, detail: detail)
    }

    static func candidates(enabled: Bool, consent: Bool, sessions: [AntigravitySessionSnapshot],
                           inFlight: Set<String>, attempted: [String: AntigravityPrevalidationTarget],
                           prepared: [String: AntigravityPreparedQuestion], limit: Int) -> [(String, AntigravityPrevalidationTarget)] {
        guard enabled, consent, limit > 0 else { return [] }
        return sessions.compactMap { session -> (String, AntigravityPrevalidationTarget)? in
            guard let target = target(for: session), !inFlight.contains(session.id), attempted[session.id] != target else { return nil }
            if let value = prepared[session.id], value.identity == target.identity && value.detail == target.detail { return nil }
            return (session.id, target)
        }.prefix(limit).map { $0 }
    }
}
