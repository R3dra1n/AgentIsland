# Claude Code Hook：可靠的等待授权信号

## 为什么需要

Claude Code 的会话记录里没有「等待授权」这个状态：`permission_mode` 只是会话的权限模式，不是单次请求的状态，所以「命令正在执行」与「命令正在等授权」在记录里无法区分。官方提供的 `PermissionRequest` 事件是唯一可靠的来源。没有 Hook 时 AgentIsland 仍能显示提问文字和执行中的命令，只是不会把等待授权报成红灯。

## 安装与移除

在应用设置的「可选 Hook → 配置 Claude Code Hook…」里点「安装」即可（1.3.18 起）：对话框写明将修改 `~/.claude/settings.json`，不用再自己找文件；配置在别处时点「选择其他位置…」。「移除 Claude Code Hook…」只移除 AgentIsland 自己的条目。两者都不需要 Python。命令行等价操作：

```sh
AgentIslandHook --install   --source claude --output ~/.claude/settings.json
AgentIslandHook --uninstall --source claude --output ~/.claude/settings.json
```

安装会备份原配置，把记录器复制到 `~/Library/Application Support/AgentIsland/hooks/native/<内容哈希>/AgentIslandHook`，并注册 11 个事件（外加下面的「在灵动岛里回答选项」那一条）：`SessionStart`、`SessionEnd`、`UserPromptSubmit`、`PermissionRequest`、`PermissionDenied`、`PreToolUse`、`PostToolUse`、`PostToolUseFailure`、`SubagentStop`、`Stop`、`StopFailure`。刻意不注册 `Notification`：它因多种互不相关的原因触发，会让状态变得不可判定。Claude Code 通过文件监看自动读取设置，不需要重启会话。

### 不会动到其他工具的 Hook

其他工具常把 Hook 挂在相同事件上。安装只**追加**自己的、独立的一组，不往别人的组里塞，也不改别人的 `matcher`；重复安装会替换而不是累加；移除只移除同时含 `AgentIslandHook` 与 `--source claude` 的命令，保留 `settings.json` 里的其他设置。已用真实设置的副本验证过：其他工具的条目全部保留，卸载后与安装前逐字段一致。

## 安全性

- 记录器的 stdout 永远是 `{}`，退出码 0。依官方定义这是「成功但不做决定」，**记录器不会代你批准或拒绝任何操作**。唯一会做决定的是下面单独注册的回答模式，而且只在你亲手点了某个选项之后。
- 只写白名单字段：事件名、会话与工具标识、回合标识、时间，以及 `PermissionRequest` 的命令 SHA-256 摘要。**不写命令原文、提示词和工具输入。**
- 事件档 `~/Library/Application Support/AgentIsland/events/claude.jsonl` 权限 `0600`，目录 `0700`，写入时加锁并拒绝符号连结。

## 事件如何转译

共用的状态归约器使用一组固定的事件名，语意等价的 Claude Code 事件由记录器转译：

| Claude Code | 记为 | 理由 |
| --- | --- | --- |
| `PermissionDenied` | `PostToolUse` | 被拒绝同样让该授权请求结束，红灯须解除 |
| `PostToolUseFailure` | `PostToolUse` | 工具已结束 |
| `StopFailure` | `Stop`，并标记出错 | 回合结束且失败 |

Claude Code 用 `prompt_id` 标识回合，归约器以 `turn_id` 为键，由记录器映射。

## 应用如何使用

`ClaudeHookState` 与 `ClaudeHookJournal`（`Sources/AgentIsland/Observers/ClaudeHookState.swift`）是独立于 Codex／Antigravity 共用的 `HookStateStore` 的小型归约器：Claude Code 没有 turn id，也不回报空闲与中断，硬套进共用的归约器会改变另外两个主要助手的行为。它提供三样东西：某会话是否有未决的授权请求、宿主自己报告的回合状态（权威的「已完成」信号，会话记录里文字与工具调用是分开的两笔，两笔之间的空档与回合结束无法区分）、会话是否已结束。问题文字与命令详情仍来自会话记录。

每个会话的状态判定顺序（`ClaudeSessionEvaluator`）：

1. 会话已结束且之后没有写入 → 不显示
2. 会话记录里有未回应的 `AskUserQuestion` → 红色，显示真实问题与选项（不设时限）
3. Hook 显示有未决的授权 → 红色，显示等待授权的工具与真实命令
4. Hook 回报的回合状态 → 已完成／失败／执行中
5. 没有 Hook：只信任新鲜的会话记录，且要记录静止数秒才敢判定完成

授权请求以会话为范围比对（会话记录的文件名就是会话 id），一个窗口的授权不会配到另一个窗口的命令上。超过 30 分钟仍未见解除的请求会被忽略，不会把悬浮窗永久钉在红色。

## 在灵动岛里回答选项（1.3.16 起）

Claude 的 `AskUserQuestion` 是它自己的对话框，外部没法替它按键（盲发按键选不了具体选项，也不保证落在对的窗口，1.3.4 起已取消）。官方给程序回答的办法是 PreToolUse Hook：返回 `permissionDecision: allow`，并在 `updatedInput` 里带上 `answers`（问题文字 → 所选选项的标签）。AgentIsland 用的就是这个。

安装 Hook 时除了上面的记录器，还会另外注册一条：`PreToolUse`、`matcher` 为 `AskUserQuestion`、`timeout` 30 秒，命令是 `AgentIslandHook --source claude --answer-questions`。记录器那条仍是 1 秒，互不影响。

流程：

1. Claude 提问时，这条 Hook 先检查：只有**单个问题、单选**、选项 1 到 10 个、灵动岛正在运行、目录安全，才往下走；否则立刻输出 `{}`，Claude 照常弹自己的对话框。
2. 它把问题写到 `~/Library/Application Support/AgentIsland/answers/requests/<工具调用 id>.json`，最多等 **20 秒**。灵动岛的行上这时出现「回答」按钮，点开列出选项。
3. 你点了某个选项，灵动岛写 `responses/<id>.json`；Hook 读到后输出 `allow` 加 `answers`，Claude 把它当作你的回答继续。
4. 20 秒内没点、灵动岛退出、答案不在选项里，一律输出 `{}`，回到 Claude 自己的对话框。

安全与代价：

- 目录 `0700`，请求与答案文件 `0600`，原子写入，拒绝符号连结，响应文件必须是本人写的普通文件；答案必须与提供的某个选项**逐字相同**，不接受自由文字。
- 灵动岛运行时每秒更新 `answers/ready`；它超过 12 秒没更新（没运行或已退出），Hook 不会等，所以**没开灵动岛时 Claude 的提问不会延迟**。
- 灵动岛开着但你没点时，Claude 自己的对话框要**晚 20 秒**才出现。这是这个办法无法避免的：对话框要等 Hook 返回才会弹出。
- 多个问题、可多选、授权的批准／拒绝都不走这条路，仍然是「打开处理」回 Claude 里答。

更新到带这条功能的版本后，需要在设置里重新「配置 Claude Code Hook…」一次（重复安装会替换旧条目，不会累加）。

已用真实的 Claude Code 验证：在桌面应用同款的 stream-json 协议下，Hook 给出答案后工具结果是「已回答」，Claude 回复所选项，且宿主（等同桌面应用的界面）没有被询问；不带这条 Hook 的对照里宿主会被询问；灵动岛没运行时宿主在 0.1 秒内被询问。**没有**在你自己的桌面应用里点过真实的灵动岛。

## 测试

- `Tests/test_answer_questions.py`：直接执行真实二进制，覆盖回答、不该等的情形立刻放行、不在选项里的答案或他人可写的响应被忽略、符号连结、越界的工具调用 id、安装与卸载。
- `Tests/test_native_hook.py`：直接执行真实二进制，覆盖追加不干扰他人、重复安装不累加且卸载完全还原、不移除 `--source` 不同的同名命令、记录器对 `PermissionDenied`／`StopFailure`／`prompt_id` 的转译及只写摘要。
- `Tests/AgentIslandTests/ClaudeHookStateTests.swift`、`ClaudeSessionTests.swift`：授权的产生与解除、回合状态、会话范围隔离、过期、多会话扫描与缓存。

## 尚未验证

实际出现授权提示时的画面与解除、两个会话同时有授权请求时不错配、长命令执行中维持黄色。Claude 适配仍属实验性。
