> 这是调查与修复过程的历史记录，**不是**当前行为说明；Claude Code 的当前行为见 [claude-hook-install.md](../claude-hook-install.md)。

# Claude Code：显示真实问题而非占位文字（2026-11-05）

## 现象与根因

现象：灵动岛上 Claude 会出现选项，但不出现实际问题。

根因很直接 —— `ClaudeObserver.swift` 中 Claude 的 `actionDetail` 只有**一个**来源，整串是硬编码的：

```swift
let detail = "❓ Claude 正在请求执行指令或需要您补充信息：\n   [y] 同意执行 (y)\n   [n] 拒绝执行 (n)\n   [c] 取消操作 (c)"
```

`[y] [n] [c]` 是写死的占位选项，真实问题文字与真实选项从未被解析。该文件自 2026-09-26 起未改动过。

同时发现三个让判定不可靠的问题：

1. **读取量不足且会截断记录**：原实作只读末 4096 bytes。实测 transcript 记录平均 3.2KB、**单笔最大 108KB**，
   4096 bytes 只能完整涵盖约 3 行，且很可能整段落在一笔记录中间，连一个完整 JSON 都解析不到。
2. **`api-request-*` 记录会重放整段对话**。原实作对原始位元组做子串位置比对，无法区分真实对话与重放。
   实测在一个已结束的 session 上，不过滤会产生 **24 笔幽灵「未回应」工具呼叫**，只取 `assistant`/`user`
   记录则为 0 笔。
3. **`publish()` 的变更守卫漏了 `actionDetail`**：状态与描述不变、只有问题换了的时候不会推送更新，
   面板会停在旧问题。`AntigravityObserver` 已修过这点，Claude 没有。

## 改动

新增 `Sources/AgentIsland/Observers/ClaudeTranscript.swift`，把解析与档案存取分离，便于用合成资料测试：

- `conversationRecordTypes` 只认 `assistant` 与 `user`，排除 `api-request-*` 重放。
- `pendingTools()` 以 `tool_use.id` 对 `tool_result.tool_use_id` 配对，得出真正未被回应的工具呼叫。
- `questionDetail()` 输出与其他助手共用的面板格式：首行 `❓ 真实问题`，其后 `   [n] 真实选项`。
- `activityDetail()` 显示真实命令或档名（`🖥 执行命令: …` / `📝 修改 X.swift`），取代占位文字。

`ClaudeObserver` 改为读取末 512KB、丢掉开头的不完整行、逐行解析完整记录，并把 `actionDetail` 纳入
`publish()` 的变更判断。

### 歧义时不提供错误的操作

单一问题且非多选时，选项渲染为 `   [n] `，面板会生成可点击的回覆项。
**多选问题、或一次呼叫包含多个问题时**，单一数字回覆是歧义的，因此选项改以 `   • ` 列出、不产生回覆项，
并附一行提示请在 Claude Code 中回答。这与 Codex 在多个请求或问题时拒绝快捷审批的处理方式一致。

### 红灯语意的变更（需要你确认）

transcript 中**没有**任何「等待授权」的状态记录：`permission-mode` 只是 session 的权限模式（如 `default`），
不是单次请求的状态。因此「Bash 正在执行」与「Bash 正在等待授权」在 transcript 层面无法区分。

- 原行为：未被回应的 `Bash` / `str_replace_editor` 一律判为 `awaitingInput`（红灯）。由于只读 4KB，
  触发并不稳定；改成正确解析后，这个判定会**更频繁地**命中，等于把每个正在执行的命令都报成「需操作」。
- 现行为：只有未被回应的 `AskUserQuestion` 判为红灯（这是唯一无歧义的等待使用者信号）；
  其他未被回应的工具呼叫判为 🟡 执行中，并显示真实命令或档名。

取舍理由：把「不确定」报成确定的「需操作」会产生假警报，并压掉真正的执行中状态 —— 正是 Codex 历史问题
那一类缺陷。若要可靠的授权红灯，正途是安装 Claude Code 的原生 hook，由 `PermissionRequest` 事件提供
真实信号（`HookStateStore` 已支援该事件）。这需要修改你的 Claude Code 设定，**未经你同意不会进行**。

## 测试

`Tests/AgentIslandTests/ClaudeTranscriptTests.swift`，11 项，全部使用合成记录，不含真实会话内容：
单一问题渲染、多选不提供回覆项、一次多问题、选项为纯字串的相容性、无可用文字时不产生详情、
已回答问题不再待处理、重放记录不产生幽灵待处理项、顺序、真实命令与档名、多行命令扁平化与长度上限、
助手纯文字结束回合。

全量：Swift **140** 项、Python 42 项通过（本次改动前为 Swift 129 项）。

另对**真实 transcript** 做了结构干跑（只输出结构，不输出任何问题内容）：

- 512KB 窗口 → 273 笔完整记录；窗口内 1 笔未回应的 `Bash`（即干跑自身），会正确显示为执行中。
- 两笔真实 `AskUserQuestion` 样本：
  - 单一问题、单选 → 5 行 = 1 问题行 + 4 个可点击回覆项
  - 两个问题、含多选 → 10 行 = 2 问题行 + 7 个项目符号 + 提示行，不提供回覆项

两者首行都是真实问题文字。

## 待完成的实机验证

隔离预览：`work/codex-history-fix-preview/AgentIsland.app`（已含本次改动）。

- [ ] Claude Code 提出单一选择问题时，灵动岛显示真实问题文字，选项可读
- [ ] 多选或一次多个问题时，问题与选项可读，且不出现可点击回覆项
- [ ] 执行长命令时显示 🟡 执行中与真实命令，不再误报红灯
- [ ] 问题换成另一个时，面板内容随之更新（验证 `publish()` 守卫修正）
- [ ] 长时间 session（transcript 远大于 512KB）仍能正确判定

Claude 适配仍属实验性，上述任一项未确认前不应宣称完成。
