# AgentIsland 项目交接与路线图

本文面向接手的开发者和 AI，记录截至 2026-11-07（版本 1.3.3）的项目方向、验收结果与待办；1.3.4 之后的变化（Claude 与 Codex 多会话行、点击行为、启动速度等）见 `CHANGELOG.md` 和 `docs/hud-session-rows.md`。它是开发快照，不代表已正式发布；接手时请重新核对实际代码、运行版本与仓库状态，不要把旧文档中的推断当作当前事实。

## 产品目标与原始设想的区别

- 最初计划使用 MacBook 键盘背光显示 AI 的执行、待操作和完成状态。由于背光效果及视线切换问题，用户已取消该功能，**不要重新引入**；旧目录或历史文档里的 AiKeyboardLight／背光是历史名称和设想。代码里保留的 `aikeyboardlight` 字样只是为了认出旧版安装的 Hook，不是残留。
- 现在的产品叫 AgentIsland，是 macOS 菜单栏与灵动岛式悬浮窗。它聚合 AI 助手状态和待处理问题；在能确认目标会话和问题时，支持从面板回复。
- 第一阶段重点是 Codex Desktop 和 Antigravity 的可靠状态与安全回复；Claude Code 已能显示真实问题、多会话，并可选安装 Hook 取得「等待授权」信号，仍是实验性；Cursor、Windsurf、Trae 是实验性适配。不应宣称它们均已完成发布验收。
- 目标是最终让他人方便下载安装与使用，并准备开源；在关键回归、干净环境及发布审查完成前，不把构建称为公开发行版或开箱即用。

## 版本与渠道

版本号只写在根目录的 `VERSION`，构建号取提交数（单调递增）。`scripts/build_app.sh` 按渠道构建，两个渠道**互不共用状态**：

| | 正式（release） | 隔离预览（preview） |
| --- | --- | --- |
| 构建 | `bash scripts/build_app.sh` | `bash scripts/build_isolated_preview.sh` |
| bundle id | `io.github.r3dra1n.AgentIsland` | `local.agentisland.isolatedpreview` |
| 显示版本 | `1.3.18` | `1.3.18-preview` |
| 输出 | `build-output/release/` | `build-output/preview/` |
| 偏好、进程锁 | 正常位置 | 独立的偏好域；锁在临时目录；窗口标有「隔离测试版」 |
| 用途 | 日常使用 | 测试，可与正式版同时运行 |

打包用 `bash scripts/package.sh`（默认正式渠道），生成 `dist/AgentIsland-<版本>-macOS-<架构>.zip`、校验值与 `INSTALL.md`。

**更新正在使用的正式版**：先把现有 `AgentIsland.app` 改名为 `AgentIsland.previous.<时间戳>.app`，再放入新的，不要直接覆盖；回退就是改回名字。

**签名**：本机没有任何代码签名身份，只能 ad-hoc。ad-hoc 的身份是二进制的哈希，所以**每次更新后辅助功能授权很可能失效**，需要在「系统设置 → 隐私与安全性 → 辅助功能」里移除后重新添加。有稳定签名身份时设置 `AGENTISLAND_SIGN_IDENTITY` 可避免。

新装的版本使用独立的偏好域：Claude 默认关闭，Antigravity 后台回复的授权需重新同意。授权类设置不应在未经用户同意时从一个偏好域复制到另一个。

## 已实现与已知验证范围

以下除特别说明外都是单台 Mac 上的结果，不代表所有助手版本、安装方式或干净系统均已验证。

- **Codex**：状态、问题、文字回复与一次性审批。「一堆旧问题」的根因是 `SessionState` 在新回合开始时保留所有未答的异步问题；现在只保留最新回合中未答的问题（缺 turn id 时保守保留），真实资料上 9 个降为 0 个，使用者反馈现在正常。需要日常使用一段时间确认不会再累积。Hook 路径（`HookStateStore`）仍跨回合保留问题，未改动，也无法在没有 Codex Hook 的环境验证。
- **Antigravity**：允许 2.27.0、2.28.0、2.28.2、2.29.0。2.29.0 的提问结构已对照一个实际等待中的问题验证，使用者反馈可用；文字回复没有样本。回应大小上限为 128MB（实测长对话的 trajectory 可达 56MB）。问题被取消或对话被关闭后，提前验证能据服务器的答复把它标为已结束。点击原窗口对应对话自动确认完成属于实验功能，依赖辅助功能权限。
- **Claude Code**：从会话记录读取提问文字与选项、正在执行的命令；多个会话各自判定。可选 Hook 提供「等待授权」与权威的回合状态。详见 `docs/claude-hook-install.md`。
- **悬浮窗行数**：只有需要注意的会话占一行，已查看的折回助手图标，每个助手最多 3 行，其余折成「+N」。详见 `docs/hud-session-rows.md`；外观为黑色变形胶囊，见 `docs/hud-style.md`。Claude 的行（不论几个会话）上，批准与拒绝一律只打开 Claude 原窗口，不盲打按键；菜单栏卡片的批准、拒绝也走同一条路。

## 已知限制与未验证

- 悬浮窗「+N」标记与点开的清单、超过 3 个会话的情形，只有单元测试，没有目视或实机验证。
- 「已查看」跨重启保存：Antigravity 与 Claude 按会话保存，各助手整体的「已查看」时间也保存（1.3.3）；「已查看」标记留 15 秒余量，15 秒内又新完成的会话会被当作已查看。
- Antigravity 提前验证默认关闭，未启用时已结束的问题仍显示为需操作。
- 没有在干净的 macOS 用户、虚拟机或另一台 Mac 上验证过下载、首次启动、授权、Hook 安装卸载和不安装 Python 的路径。
- 未做 Developer ID 签名与公证。
- 实际出现 Claude 授权提示时的画面、两个会话同时授权不错配，尚未实机验证。

## 诊断方法

要知道界面上显示的东西从哪来，用真正的扫描器，不要写模拟：

```sh
AGENTISLAND_PROBE=1 swift test --filter RealStateProbe
```

它只读、只印结构（数量、状态、截短的标识），默认被跳过。两条教训：

1. 手写的 reducer 副本会漂移。曾有一个 Python 诊断脚本在任务完成时清空待处理清单，真正的代码却跨回合保留，于是脚本报告 0 个，界面却显示 9 个，并因此得出了错误结论。
2. 判定「上游协议变了」之前先确认诊断工具本身是对的。验证 Antigravity 2.29.0 时曾连续三次得出这个结论，三次都是自己脚本的错（手工拼的 HTTP 标头有多余空格、`glob` 不进隐藏目录、没解码分块传输编码）。

## 架构入口

- `Sources/AgentIsland/Observers/`：每个助手一个观察器。Codex（`CodexObserver`、`CodexNativeBridge`、`CodexDesktopBridge`、`SessionState`）；Antigravity（`AntigravityObserver`、`AntigravityLocalTransport`、`PinnedLoopbackHTTP`、`AntigravityInteraction`、`AntigravityReplyWorkflow`）；Claude Code（`ClaudeObserver`、`ClaudeSessions`、`ClaudeTranscript`、`ClaudeHookState`）；Cursor／Windsurf／Trae（`GenericProcessObserver` 与探针）。
- `Sources/AgentIsland/App/`：`AppState`（单一状态中枢，另有 `+Actions`、`+Delegate`、`+Test`）、各助手的动作控制器、`DirectActionEngine`。会话行的挑选集中在 `AppState.arrangeSessionRows`。
- `Sources/AgentIsland/Views/`：悬浮窗、设置面板、菜单栏图标。
- `Sources/AgentIslandHook/`：原生 Hook 记录器与安装器（Codex、Antigravity、Claude Code）。
- `Tests/`、`scripts/test.sh`、`scripts/check_public_source.py`：测试与基础隐私扫描。构建与打包见上文「版本与渠道」及 [安装说明](install.md)。
- `docs/history/`：调查与修复过程的记录，不是当前行为说明。

## 工作边界与安全

保护用户正在使用的日常应用、真实助手配置和既有会话。先备份未提交／未跟踪源码、运行应用和将受影响的配置；使用独立目录、隔离构建、模拟 Hook 配置及无害问题验证。未经确认不覆盖日常应用、不更改真实助手配置、不执行真实命令审批；不要读取或打印真实会话、问题、命令、令牌的内容。

私有仓库 `R3dra1n/AgentIsland` 的 `main` 现在就是 1.3.x 的开发主线，GitHub 上的其他分支是旧备份。仓库是私有的，不等于已发布；历史里仍有 21 个署名 `Nolla` 的提交（另有 28 个署名 `R3dra1n`），公开前需要在副本上统一署名并重新扫描，不能直接公开旧历史，也不能假定任一打包文件与最新源码一致。同步前先检查差异和隐私，发布前对同一提交的源码、完整历史、构建产物、文档、截图和元数据重新审查。常规扫描无法证明没有任何个人信息或安全问题。

## 后续顺序

1. 日常使用一段时间，确认 Codex 旧问题不再累积、Antigravity 的已结束问题能被清掉、悬浮窗行数符合预期；记录无敏感内容的截图。
2. 目视确认「+N」标记与点开的清单，补足超过 3 个会话的实测。
3. 决定是否把 Hook 路径也改成不跨回合保留旧问题。
4. 在干净 macOS 用户、虚拟机或另一台 Mac 验证下载、首次启动、授权、三个助手、Hook 安装卸载和不安装 Python 的正常路径。
5. 决定 Apple Developer ID 签名与公证；如先发未公证版本，说明 macOS 提示、身份核验及辅助功能可能需要重新授权，不要求关闭全局安全设置。
6. 固定一个候选提交，重复测试，构建独立包，核对 App、校验值、README 与提交一致；扫描源码、构建物、完整历史和演示素材，人工审查第三方素材与个人信息，再决定是否公开。赞助链接在本人完成收款、提款和身份展示检查后启用。
7. 用户最终审阅代码、发布包和公开内容后，再进行公开或发布。所有对外承诺以实际验收为准。
