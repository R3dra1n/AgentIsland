# Hook 配置

Codex、Antigravity 和 Claude Code 都可以在应用设置的「可选 Hook → 配置」里安装。原生安装器会先让你选择目标配置文件（或所在目录）并确认路径，备份原配置，把原生记录器复制到按内容命名的目录，只追加 AgentIsland 自己的命令，保留其他工具的 Hook。「移除」同样只移除能确认是 AgentIsland 的注册。

| 助手 | 目标文件 | 说明 |
| --- | --- | --- |
| Codex | `hooks.json` | Codex Desktop 的后台回复依赖本机 IPC，不只靠 Hook |
| Antigravity | `hooks.json` | Stop 输出的宿主语义仍需在目标版本验证 |
| Claude Code | `~/.claude/settings.json` | 提供会话记录里没有的「等待授权」信号；其他工具常把 Hook 挂在相同事件上，安装只追加自己的命令 |

不要猜测目标助手版本的配置位置，需要时查阅该版本的官方说明。安装后重新加载助手。不要把包含本机绝对路径的生成结果提交到仓库。

Hook 记录器永远输出 `{}` 并以 0 结束，即「成功但不做决定」，不会批准或拒绝任何操作。事件按字段白名单写入 `~/Library/Application Support/AgentIsland/events/`，命令只存摘要，不存原文。

没有安装 Hook 时，Codex 与 Antigravity 仍可通过日志与 IPC 工作；Claude Code 仍能显示提问与执行中的命令，只是无法可靠判断「等待授权」。

## 开发者用的 Python 工具

以下仅供开发与兼容测试，不是应用内配置的必需步骤，也不被打包进应用：

```sh
/usr/bin/python3 scripts/configure_hooks.py --source codex --output "$HOME/.codex/hooks.json"
```

`scripts/install_provider_hooks.py` 与 `scripts/provider_hook.py` 是 Cursor／Windsurf 的实验性 Hook 工具。
