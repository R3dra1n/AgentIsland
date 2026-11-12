# AgentIsland 安装说明

本构建使用 ad-hoc 签名，打包脚本不会自动公证，也未在干净的机器上验证；最低 macOS 14。`arm64` 包仅适用于 Apple Silicon；通用包仍需在两种架构上分别验证。

## 获取与校验

打包后，应用 ZIP、同名 `.sha256` 校验文件和 `INSTALL.md` 是三个并列文件，ZIP 中只有 App。文件名带版本号和架构，例如 `AgentIsland-1.3.3-macOS-arm64.zip`。把三个文件下载到同一目录，以 Apple Silicon 包放在「下载」目录为例：

```sh
cd ~/Downloads
shasum -a 256 -c AgentIsland-1.3.3-macOS-arm64.zip.sha256
```

显示 `OK` 表示 ZIP 与该校验文件一致；校验值本身仍需从可信渠道获取。

## 安装与更新

1. 校验后双击解压，把 `AgentIsland.app` 放到 Applications（或你原来放的位置）。1.3.18 起另有同名的 `.dmg`：打开后把 AgentIsland 拖到旁边的 Applications 即可，内容与 ZIP 相同，同样未公证，有自己的 `.sha256`。
2. **更新时不要直接覆盖旧版**：先把旧的 `AgentIsland.app` 改名为 `AgentIsland.previous.<日期>.app`，确认新版正常再决定是否删除，需要回退时改回名字即可。
3. 如系统提示无法验证开发者，确认文件来源后参考 [Apple 打开安全设置说明](https://support.apple.com/en-us/102445)，不要全局关闭 Gatekeeper。
4. **辅助功能授权在每次更新后很可能失效。** 临时签名的身份是这一份二进制的哈希，换了新版就是另一个身份。请在「系统设置 → 隐私与安全性 → 辅助功能」里先用「−」移除旧的 AgentIsland，再用「+」添加新的并重新打开应用。没有辅助功能权限时，状态监控仍可用，但点击原窗口自动确认完成、部分后台操作会不可用。若有稳定的代码签名身份，构建时设置 `AGENTISLAND_SIGN_IDENTITY` 可以避免这一步。
5. Codex 通信使用原生 IPC。Codex、Antigravity、Claude Code 的可选 Hook 都提供原生配置入口和记录器，不要求用户安装 Python。
6. Antigravity 的后台回复属于实验功能，仅允许 2.27.0、2.28.0、2.28.2、2.29.0。首次后台回复需同意读取本机临时令牌，可在设置中撤销；命令审批、会话归属或回复结果不明确时请回 Antigravity 处理。
7. 「Antigravity 提前验证问题」默认关闭。单独开启后，会在问题出现时查询本机会话以减少面板等待，并能在服务器确认问题已不再等待时清掉已结束的提醒；它不会自动提交回复，可随时关闭。
8. 想让它开机后自己启动，在设置的「通知与集成」里打开「登录时自动启动」（1.3.18 起）。它登记在系统的「系统设置 → 通用 → 登录项」里，可在那里查看或移除；应用换了位置或更新后，如果不再自动启动，把开关关掉再打开一次。
9. 新装的版本使用独立的偏好域，Claude 默认关闭，需要在设置里打开；Antigravity 的后台回复授权需要重新同意。

两个渠道可同时运行：正式版的 bundle id 是 `io.github.r3dra1n.AgentIsland`（1.3.1 及更早是 `com.antigravity.AgentIsland`，首次启动会把普通设置迁移过来，授权类设置不迁移，需要重新同意），隔离预览是 `local.agentisland.isolatedpreview`，窗口上标有「隔离测试版」，偏好与进程锁互相独立。

## 可选 Hook

支持 Codex、Antigravity 和 Claude Code（配置文件为 `~/.claude/settings.json`）。确认对应助手版本的配置位置后，在 AgentIsland 设置中的「可选 Hook → 配置」选择助手和配置文件。安装前会显示目标路径；安装器保留其他 Hook、保存配置备份，并把版本化原生记录器放入当前用户 Application Support。移除时在同一菜单选择对应的「移除 Hook」，选择之前的配置位置。工具只移除可识别的 AgentIsland 注册，保留配置备份和可能被其他配置引用的 recorder。不要直接恢复旧备份覆盖之后的用户修改。

## 已知限制

Codex 使用版本相关的非公开 IPC，断线或协议变化时需回原应用处理。其他助手为实验性。多会话仅在单台 Mac 做过有限验证，尚未完成干净机器验证；临时签名无法保证更新后辅助功能授权延续。

## 卸载与本机数据

1. **务必先做这一步。** 若曾配置可选 Hook，先在应用设置中选择对应的「移除 Hook」并选择之前配置的 `hooks.json`；重复此步骤处理每个曾配置的助手。确认其他 Hook 仍在，保留备份直到核对完成。
2. 退出 AgentIsland，再将安装的 `AgentIsland.app` 移到废纸篓。若曾授予辅助功能权限，可在 macOS「隐私与安全性 → 辅助功能」中移除该应用的授权记录。
3. 若不再需要 AgentIsland 的本机事件记录、锁文件和版本化 Hook 工具，可在 Finder「前往文件夹」打开 `~/Library/Application Support/AgentIsland`，检查后删除该目录。确认其他配置已不再引用其中的工具；配置文件旁的 `*.agentisland-backup-*` 需自行决定是否保留。所选 Hook 配置文件所在目录还可能留下隐藏的 `.agentisland-lock-<哈希>` 文件；只有确认所有 AgentIsland Hook 安装或移除操作均已结束后，才可自行选择删除，进行中的操作不要删除锁文件。
4. 如需清除全部 AgentIsland 界面偏好和后台回复授权，确认应用已退出后可在终端运行 `defaults delete io.github.r3dra1n.AgentIsland`（旧版本用 `com.antigravity.AgentIsland`）；若该偏好域不存在，命令可能提示未找到。此操作会删除该域的全部设置，请先确认需要清除。隔离预览使用另一个偏好域 `local.agentisland.isolatedpreview`，要清除它需单独对该域执行同样的命令。

不要删除 Codex、Antigravity 或其他助手自身的对话、配置和数据目录。以上删除步骤不可自动恢复，请先保留需要的备份。

**如果忘了先移除 Hook**：1.2.4 起安装的 Hook 命令在记录器文件不存在时会直接成功退出，不会拦下助手的消息。更早版本安装的 Hook 在文件被删后，助手可能报「Hook 已阻止此消息」；这时重新安装一次（会替换成新写法）或移除即可。修改 Hook 后请先重启对应的助手，再删除它引用过的文件，因为运行中的助手会一直使用启动时读到的 Hook 清单。
