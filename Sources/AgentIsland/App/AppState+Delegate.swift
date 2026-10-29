import Foundation
import AppKit

extension AppState {
    public func observer(_ observer: any AIObserverProtocol, didUpdateState state: AIState, description: String, actionDetail: String?) {
        if testModeActive { return }
        
        let now = Date()
        let lastAck = lastAcknowledgedDates[observer.id] ?? .distantPast
        let activeDate = observer.lastActiveDate ?? .distantPast
        let isAlreadyAcknowledged = lastAck >= activeDate

        if observer.id == "codex" {
            if let codex = observer as? CodexObserver {
                let requests = codex.pendingRequests
                if requests != codexPendingRequests || state != codexState { codexActionFeedback = nil }
                codexPendingRequests = requests
            }
            updateProviderState(state: state, description: description, actionDetail: actionDetail, isAlreadyAcknowledged: isAlreadyAcknowledged, providerState: &codexState, providerDesc: &codexDescription, providerNeedsAck: &codexNeedsAck, providerActionDetail: &codexActionDetail)
        } else if observer.id == "antigravity" {
            updateProviderState(state: state, description: description, actionDetail: actionDetail, isAlreadyAcknowledged: isAlreadyAcknowledged, providerState: &antigravityState, providerDesc: &antigravityDescription, providerNeedsAck: &antigravityNeedsAck, providerActionDetail: &antigravityActionDetail)
        } else if observer.id == "claude" {
            updateProviderState(state: state, description: description, actionDetail: actionDetail, isAlreadyAcknowledged: isAlreadyAcknowledged, providerState: &claudeState, providerDesc: &claudeDescription, providerNeedsAck: &claudeNeedsAck, providerActionDetail: &claudeActionDetail)
        } else if observer.id == "cursor" {
            updateProviderState(state: state, description: description, actionDetail: actionDetail, isAlreadyAcknowledged: isAlreadyAcknowledged, providerState: &cursorState, providerDesc: &cursorDescription, providerNeedsAck: &cursorNeedsAck, providerActionDetail: nil) // Cursor doesn't have action detail yet
        } else if observer.id == "windsurf" {
            updateProviderState(state: state, description: description, actionDetail: actionDetail, isAlreadyAcknowledged: isAlreadyAcknowledged, providerState: &windsurfState, providerDesc: &windsurfDescription, providerNeedsAck: &windsurfNeedsAck, providerActionDetail: nil)
        } else if observer.id == "trae" {
            updateProviderState(state: state, description: description, actionDetail: actionDetail, isAlreadyAcknowledged: isAlreadyAcknowledged, providerState: &traeState, providerDesc: &traeDescription, providerNeedsAck: &traeNeedsAck, providerActionDetail: nil)
        }
        recalculateAggregatedState()
    }

    private func updateProviderState(state: AIState, description: String, actionDetail: String?, isAlreadyAcknowledged: Bool, providerState: inout AIState, providerDesc: inout String, providerNeedsAck: inout Bool, providerActionDetail: UnsafeMutablePointer<String?>?) {
        if let detailPointer = providerActionDetail {
            detailPointer.pointee = actionDetail
        }
        if state == .completed {
            if isAlreadyAcknowledged {
                providerNeedsAck = false
                providerState = .idle
                providerDesc = "待命中"
            } else {
                providerNeedsAck = true
                providerState = .completed
                providerDesc = description
            }
        } else if state == .running || state == .awaitingInput {
            providerNeedsAck = false
            providerState = state
            providerDesc = description
        } else if providerNeedsAck {
            if state == .failed || state == .interrupted {
                providerNeedsAck = false
                providerState = state
                providerDesc = description
            } else {
                providerState = .completed
            }
        } else {
            providerState = state
            providerDesc = description
        }
        recalculateAggregatedState()
    }

    public func recalculateAggregatedState() {
        var activeStates: [AIState] = []
        if codexEnabled { activeStates.append(codexState) }
        if antigravityEnabled { activeStates.append(antigravityState) }
        if claudeEnabled { activeStates.append(claudeState) }
        
        if cursorEnabled { activeStates.append(cursorState) }
        if windsurfEnabled { activeStates.append(windsurfState) }
        if traeEnabled { activeStates.append(traeState) }

        let winner = activeStates.max(by: { $0 < $1 }) ?? .idle
        let old = self.aggregatedState
        self.aggregatedState = winner

        // Audio Alert on state transitions
        if winner != old {
            handleStateTransition(from: old, to: winner)
        }
    }

    private func handleStateTransition(from old: AIState, to new: AIState) {
        guard soundAlertEnabled else { return }

        if new == .awaitingInput {
            NSSound(named: "Ping")?.play()
        } else if new == .completed && old == .running {
            NSSound(named: "Glass")?.play()
        }
    }
}
