import AppKit
import Foundation

/// Optional, explicit setup. No configuration is read or changed at launch.
@MainActor
enum NativeHookSetup {
    static func begin(source: String, removing: Bool = false) {
        guard ["codex", "antigravity", "claude"].contains(source),
              let executable = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("AgentIslandHook"),
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            show("无法配置 Hook", "当前应用缺少原生 Hook 工具，请使用完整的安装包。")
            return
        }
        let display = ["codex": "Codex", "antigravity": "Antigravity", "claude": "Claude Code"][source] ?? source
        // Claude Code keeps hooks in settings.json; the other two use hooks.json.
        let fileName = source == "claude" ? "settings.json" : "hooks.json"
        let verb = removing ? "移除" : "安装"
        // Claude Code has one user-level settings file, at a fixed place, so
        // there is nothing to go looking for: say what will change and do it.
        // The other assistants' files move between versions and stay a choice.
        if source == "claude" {
            let usual = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
            let quick = NSAlert()
            quick.messageText = "\(verb) \(display) Hook？"
            quick.informativeText = (removing
                ? "将从 \(usual.path) 里移除 AgentIsland 自己的条目，其他工具的 Hook 保留，原文件先备份。"
                : "将修改 \(usual.path)：只追加 AgentIsland 自己的条目，其他工具的 Hook 保留，原文件先备份；重复安装是替换，不会叠加。\n\n装好后可以可靠显示「等待授权」，并能在灵动岛里回答 Claude 的单选问题。已经开着的 Claude 会话要重新开一个才会生效。")
            quick.addButton(withTitle: verb)
            quick.addButton(withTitle: "选择其他位置…")
            quick.addButton(withTitle: "取消")
            switch quick.runModal() {
            case .alertFirstButtonReturn:
                run(source: source, display: display, removing: removing, helperPath: executable.path, targetPath: usual.path)
                return
            case .alertSecondButtonReturn: break   // the chooser below
            default: return
            }
        }
        let intro = NSAlert()
        intro.messageText = "\(verb) \(display) Hook"
        let claudeNote = source == "claude"
            ? "\n\nClaude Code 的用户级配置通常是 ~/.claude/settings.json。其他工具常把 Hook 挂在相同事件上，安装只会追加 AgentIsland 自己的命令，不会动到它们。"
            : ""
        intro.informativeText = (removing
            ? "接下来选择该助手的 \(fileName) 或所在目录。只移除可识别的 AgentIsland 注册，其他 Hook 保留；现有配置会备份。原生工具不会自动删除，以免其他配置仍在使用。"
            : "接下来选择该助手的 \(fileName)，或选择包含它的目录。安装会备份现有配置并保留其他 Hook；如果目录中没有文件，将创建 \(fileName)。请先确认该助手版本读取此位置。") + claudeNote
        intro.addButton(withTitle: "选择位置")
        intro.addButton(withTitle: "取消")
        // Claude's own dialog above has already explained and offered to cancel.
        guard source == "claude" || intro.runModal() == .alertFirstButtonReturn else { return }
        let panel = NSOpenPanel()
        panel.title = "选择 \(display) 的 Hook 配置或目录"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        let home = FileManager.default.homeDirectoryForCurrentUser
        // Start where the file usually lives, without reading or changing it.
        let suggested = home.appendingPathComponent(".claude", isDirectory: true)
        panel.directoryURL = source == "claude" && FileManager.default.fileExists(atPath: suggested.path) ? suggested : home
        guard panel.runModal() == .OK, let selected = panel.url else { return }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: selected.path, isDirectory: &directory) else {
            show("配置失败", "选择的位置不可用。")
            return
        }
        let destination = directory.boolValue ? selected.appendingPathComponent(fileName) : selected
        guard destination.lastPathComponent == fileName else {
            show("配置失败", "请选择 \(fileName) 或它所在的目录。")
            return
        }
        let confirm = NSAlert()
        confirm.messageText = "\(verb) \(display) Hook？"
        confirm.informativeText = "将修改：\(destination.path)\n\n现有文件会先备份。安装完成后可能需要重新加载助手。"
        confirm.addButton(withTitle: verb)
        confirm.addButton(withTitle: "取消")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }
        run(source: source, display: display, removing: removing, helperPath: executable.path, targetPath: destination.path)
    }

    private static func run(source: String, display: String, removing: Bool, helperPath: String, targetPath: String) {
        Task {
            let success = await Task.detached(priority: .userInitiated) {
                let process = Process()
                let output = Pipe()
                process.executableURL = URL(fileURLWithPath: helperPath)
                process.arguments = [removing ? "--uninstall" : "--install", "--source", source, "--output", targetPath]
                process.standardOutput = output
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run(); process.waitUntilExit()
                    let message = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    return (process.terminationStatus == 0, message.contains("No AgentIsland hook registration found."))
                } catch { return (false, false) }
            }.value
            if success.0 && success.1 { show("未找到注册", "所选配置没有可识别的 AgentIsland Hook；未更改配置。") }
            else if success.0 { show("操作完成", "请重新加载 \(display)，再执行无害任务检查状态。如果未生效，请检查所选配置位置和 Hook 是否启用。") }
            else { show("操作未完成", "配置可能不存在、不是有效 JSON、已被其他程序更改，或当前用户没有写入权限。请检查位置后重试。") }
        }
    }

    private static func show(_ title: String, _ message: String) {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = message; alert.runModal()
    }
}
