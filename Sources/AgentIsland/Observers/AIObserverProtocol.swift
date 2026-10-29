import Foundation
import SwiftUI

public enum AIState: String, CaseIterable, Sendable, Comparable {
    case unknown = "unknown"
    case failed = "failed"
    case interrupted = "interrupted"
    case idle = "idle"
    case completed = "completed"
    case running = "running"
    case awaitingInput = "awaitingInput"

    public var priority: Int {
        switch self {
        case .awaitingInput: return 7 // Highest: user intervention needed
        case .running: return 6       // Executing
        case .completed: return 5     // Completed (higher than idle/unknown/interrupted)
        case .failed: return 4
        case .interrupted: return 3
        case .idle: return 1          // Idle
        case .unknown: return 0       // Lowest: uninitialized/fallback
        }
    }

    public static func < (lhs: AIState, rhs: AIState) -> Bool {
        return lhs.priority < rhs.priority
    }

    public var title: String {
        switch self {
        case .awaitingInput: return "需操作"
        case .running: return "执行中"
        case .completed: return "已完成"
        case .failed: return "执行失败"
        case .interrupted: return "已中断"
        case .idle, .unknown: return "待命中"
        }
    }

    public var color: Color {
        switch self {
        case .awaitingInput: return .red
        case .running: return .yellow
        case .completed: return .green
        case .failed: return .orange
        case .interrupted: return .secondary
        case .idle, .unknown: return .secondary.opacity(0.5)
        }
    }

    public var systemIcon: String {
        switch self {
        case .awaitingInput: return "exclamationmark.circle.fill"
        case .running: return "arrow.triangle.2.circlepath.circle.fill"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle"
        case .interrupted: return "pause.circle"
        case .idle, .unknown: return "circle"
        }
    }
}

@MainActor
public protocol AIObserverDelegate: AnyObject {
    func observer(_ observer: any AIObserverProtocol, didUpdateState state: AIState, description: String, actionDetail: String?)
}

@MainActor
public protocol AIObserverProtocol: AnyObject {
    var id: String { get }
    var displayName: String { get }
    var iconName: String { get }
    var isEnabled: Bool { get set }
    var state: AIState { get }
    var statusDescription: String { get }
    var actionDetail: String? { get }
    var lastActiveDate: Date? { get }
    var delegate: AIObserverDelegate? { get set }

    func startObserving()
    func stopObserving()
}
