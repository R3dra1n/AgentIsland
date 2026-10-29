# Hook 模板

这里的 JSON 是历史结构示例，`__RECORD_HOOK_PATH__` 是占位符，不能直接复制为有效配置。
不要把包含本机绝对路径的生成结果提交到仓库。

Codex／Antigravity 可在应用设置的「可选 Hook → 配置」选择目标 `hooks.json` 或所在目录。原生安装器会先确认目标并备份原配置，将原生 recorder 复制到版本化目录，保留其他注册。不要猜测目标助手版本的配置位置；需要时查阅该版本官方说明。安装后重新加载助手。Codex Desktop 的 IPC 不依赖 Hook。

以下 Python 命令保留给开发者兼容测试，不是应用内原生配置的必需步骤。

Codex 使用以下命令生成/合并本机配置（先确认目标文件是当前 Codex 版本读取的 Hook 配置）：

```sh
/usr/bin/python3 scripts/configure_hooks.py --source codex --output "$HOME/.codex/hooks.json"
```

安装器将 Codex recorder 复制到当前用户的 Application Support/AgentIsland/hooks，
正确引用带空格的路径，保留其他 Hook，并备份已有配置。Codex 可能要求信任/启用 Hook。
Codex Desktop 的后台回复还依赖本机 IPC，并不只靠 Hook。

安装器也会为 Antigravity 复制 recorder 到 Application Support 固定目录。
在确认对应版本实际读取的 Hook 配置位置后，使用 `--source antigravity`，并先备份配置。
安装器只移除可识别的旧 AgentIsland 处理器；其他处理器保留。Stop 输出的宿主语义仍需在目标版本验证。
