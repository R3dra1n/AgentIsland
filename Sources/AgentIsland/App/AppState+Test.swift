import Foundation
import SwiftUI
import AppKit

extension AppState {
    public func triggerMultiTest(state: AIState) {
        testModeActive = true
        
        codexState = codexEnabled ? state : .idle
        antigravityState = antigravityEnabled ? state : .idle
        claudeState = claudeEnabled ? state : .idle
        
        codexNeedsAck = (codexState == .completed)
        antigravityNeedsAck = (antigravityState == .completed)
        claudeNeedsAck = (claudeState == .completed)
        
        codexDescription = codexState == .awaitingInput ? "等待审批: npm test" : (codexState == .running ? "执行 bash 脚本中..." : (codexState == .completed ? "构建已完成" : "待命中"))
        antigravityDescription = antigravityState == .awaitingInput ? "等待确认: ask_question" : (antigravityState == .running ? "代码推理生成中..." : (antigravityState == .completed ? "规划完成" : "待命中"))
        claudeDescription = claudeState == .awaitingInput ? "等待审批: edit_file" : (claudeState == .running ? "分析代码库结构中..." : (claudeState == .completed ? "任务完成" : "待命中"))
        
        
        cursorState = cursorEnabled ? state : .idle
        windsurfState = windsurfEnabled ? state : .idle
        traeState = traeEnabled ? state : .idle
        cursorNeedsAck = (cursorState == .completed)
        windsurfNeedsAck = (windsurfState == .completed)
        traeNeedsAck = (traeState == .completed)
        cursorDescription = cursorState == .awaitingInput ? "等待审批: Command" : (cursorState == .running ? "分析代码中..." : (cursorState == .completed ? "完成" : "待命中"))
        windsurfDescription = windsurfState == .awaitingInput ? "等待确认" : (windsurfState == .running ? "生成代码中..." : (windsurfState == .completed ? "完成" : "待命中"))
        traeDescription = traeState == .awaitingInput ? "等待授权" : (traeState == .running ? "工作流运行中..." : (traeState == .completed ? "结束" : "待命中"))

        aggregatedState = state
        if aggregatedState == .awaitingInput && soundAlertEnabled {
            NSSound(named: "Ping")?.play()
        }
    }

    public func stopTest() {
        testModeActive = false
        lastAcknowledgedDates["codex"] = Date()
        lastAcknowledgedDates["antigravity"] = Date()
        lastAcknowledgedDates["claude"] = Date()
        codexNeedsAck = false
        antigravityNeedsAck = false
        claudeNeedsAck = false

        lastAcknowledgedDates["cursor"] = Date()
        lastAcknowledgedDates["windsurf"] = Date()
        lastAcknowledgedDates["trae"] = Date()
        cursorNeedsAck = false
        windsurfNeedsAck = false
        traeNeedsAck = false


        if codexObserver.state != .running && codexObserver.state != .awaitingInput {
            codexState = .idle
            codexDescription = "待命中"
        } else {
            codexState = codexObserver.state
            codexDescription = codexObserver.statusDescription
        }

        if antigravityObserver.state != .running && antigravityObserver.state != .awaitingInput {
            antigravityState = .idle
            antigravityDescription = "待命中"
        } else {
            antigravityState = antigravityObserver.state
            antigravityDescription = antigravityObserver.statusDescription
        }

        if claudeObserver.state != .running && claudeObserver.state != .awaitingInput {
            claudeState = .idle
            claudeDescription = "待命中"
        } else {
            claudeState = claudeObserver.state
            claudeDescription = claudeObserver.statusDescription
        }

        cursorState = cursorObserver.state
        cursorDescription = cursorObserver.statusDescription
        windsurfState = windsurfObserver.state
        windsurfDescription = windsurfObserver.statusDescription
        traeState = traeObserver.state
        traeDescription = traeObserver.statusDescription


        recalculateAggregatedState()
    }
}
