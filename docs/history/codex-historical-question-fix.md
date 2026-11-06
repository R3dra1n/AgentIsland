> 这是调查与修复过程的历史记录，**不是**当前行为说明；当前行为见 README 与 PROJECT-HANDOFF。文中的诊断脚本已被删除。

# Codex 历史问题：根因与验证清单（2026-11-05）

本文记录本次修改的根因、改动范围和**尚未完成**的实机验证。自动测试通过不等于修复已验收。

## 版本核对结果

修改前先核对了实际运行的二进位，而不是只读文档：

| build | 日期 | Antigravity 原生回传 | 历史隐藏逻辑 |
| --- | --- | --- | --- |
| 日常 app `~/AgentIsland/AgentIsland.app` | 09-26 | 无 | 无 |
| `work/project/build-output` | 10-28 | 无 | 无 |
| `work/state-fix-preview` | 10-30 09:29 | 有 | 无 |
| `work/click-diagnostic-preview` | 10-30 15:51 | 有 | 部分 |
| `work/historical-preview` | 10-30 16:10 | 有 | 有（当时唯一） |

日常使用的 app 是 9 月 26 日构建，不含任何历史隐藏逻辑。源码中 `d8810dd` 提交的内容即 `historical-preview`
当时的未提交工作，因此源码层面没有比该预览更新的未验证尝试。

## 根因

三段串联，缺一不可：

1. **来源**：`pending()` 从 status 为 `inProgress` 或 `completed` 的**所有**轮次收集异步问题（为让异步问题在轮次
   结束后仍可回答而刻意放宽）。`turns()` 返回整个 `turnHistory.history.entitiesByKey`，于是整部历史中每个未被
   标记已答的异步问题都成为待处理请求。
2. **「已回答」判定覆盖不到常态**：`answered` 只认 `<send_user_message_question_reply>` 标记。使用者不回答、
   直接继续下一轮是最常见的情况，这种问题永远不会产生该标记，于是永久显示。
3. **两道隐藏闸门实际上不会执行**：
   - `historicalAsyncCalls()` 和 `resolvedAsyncCalls()` 都以 `history["isComplete"] == true` 为前提。
   - 触发完整历史载入的条件是 `snapshot.codexRequests.filter { $0.isAsynchronous && $0.desktopMethod == nil }`。
     `snapshot.codexRequests` 来自 LogScanner（`desktopMethod` 恒为 `nil`），而真正显示出来的历史问题来自
     IPC（`desktopMethod == "async-question"`），且它们是在该行**之后**才被合并进来；下一轮轮询又从 scanner
     重建。带有 IPC 来源请求的 `previousRequests` 没有被纳入这个判断。
   - 结果：对只存在于 IPC 快照中的历史问题，`loadFullHistory` 永不被请求，`isComplete` 永为 false，
     隐藏逻辑永远返回空集。

附带缺口：`historicalAsyncCalls()` 只看 `status == "completed"`，与 `resolvedAsyncCalls()` 的
`["completed", "failed", "interrupted"]` 不一致；且要求最新 `turnStartedAtMs` 唯一，并列时整批放弃。

「旧问题遮盖执行中状态」是同一根因的后果：`if !snapshot.codexRequests.isEmpty { snapshot.state = .awaitingInput }`
会被任何一个陈旧请求无条件触发，压掉黄色执行中。

## 修改方向

原实现把 `isComplete` 当作「可以隐藏」的前提，方向用反了：

- **「存在严格更新的轮次」是正向、单调的证据。** 部分快照可以漏掉轮次，但不会凭空造出轮次；已经能看到的
  更新轮次不会因为别的轮次没载入而变成假。据此隐藏不需要完整历史。
- 需要完整快照的是**相反方向** —— 证明「没有任何记录回答过这个问题」。`resolvedAsyncCalls()` 保留
  `isComplete` 前提是正确的，`historicalAsyncCalls()` 套用它才是错的。

实际改动（`Sources/AgentIsland/Observers/`）：

1. `CodexNativeBridge.historicalAsyncCalls()`：去掉 `isComplete` 前提；以「存在严格更新的轮次」为判据，
   并列的最新轮次因严格比较自然被排除，不再整批放弃；无可比较时间戳时不隐藏任何问题。
2. 新增共用的 `endedTurnStatuses` 与 `startedAt()`，`historicalAsyncCalls()` 与 `resolvedAsyncCalls()`
   共用同一份「已结束」定义，避免再次漂移。
3. `CodexObserver.sessionsNeedingHistory(scanned:previous:)`：从轮询回圈抽出并修正，同时检查本轮扫描结果与
   上一轮请求，涵盖 `isAsynchronous` 与 `desktopMethod == "async-question"` 两种来源。

边界：**仅影响 AgentIsland 的显示**。不替使用者回答、取消或删除任何 Codex 问题；被隐藏的问题在 Codex 中
依然存在，可在原应用回答。轮次身份或时间戳无法确认时一律保守保留。

## 自动测试

`Tests/AgentIslandTests/CodexHistoricalQuestionTests.swift`，全部使用合成 `conversationState`，不含真实会话内容。
修改前 9 项中 4 项失败（部分快照不隐藏、已结束状态不涵盖、时间戳并列放弃、IPC 来源不触发完整历史），
修改后全部通过。全量：Swift 129 项、Python 42 项通过（基线为 Swift 120 项）。

`CodexNativeBridgeTests.testOnlyOlderCompletedAsyncQuestionsBecomeHistorical` 原本断言
`isComplete: false` 时返回空集 —— 该断言把缺陷固化为预期行为，已随本次修改更新并注明原因。

## 2026-11-05 晚间：对真实资料实测后的更正

用隔离预览与只读诊断对本机真实状态实测后，必须更正上文「根因」一节中过于肯定的部分：

- **`isComplete` 闸门在实务上常是通的。** 三个可经 IPC 连上的 session 全部 `isComplete = True`
  （turns 分别为 73、72、9）。因此「隐藏逻辑永远不会执行」这个说法不成立；只有在 Codex 桌面端未载入完整
  历史时才成立。那条死掉的触发条件（`sessionsNeedingHistory` 无法命中 IPC 来源）确实是真实的代码缺陷，
  但它不等于使用者症状的成因。
- **症状当下无法复现。** 三个来源同时为零：IPC 路径 0 个异步问题；旧名 hook 目录没有 `codex.jsonl`；
  24 小时内 15 个 transcript 推不出任何未决请求（全部 `completed`）。
- **9/26 日常版的 `pending()` 使用 `items(state, activeOnly: true)`**，只从执行中轮次收异步问题，
  因此使用者在该版本看到的「一堆历史问题」不可能来自 IPC 的历史轮次。实际来源仍未确认。

结论：本次三处修改（死掉的触发条件、时间戳并列整批放弃、只认 `completed`）都是真实缺陷，
但**没有任何一处被证明是使用者症状的成因**。不得宣称该症状已修复。

剩下最可能的来源是 transcript 路径：`SessionState.visibleState` 对 `.awaitingInput` **刻意不做超时重置**
（注释理由是使用者可能离开键盘），而 `mergeRequests` 只在该 session 的 IPC 快照可用时才用实时资料取代
扫描结果；IPC 取不到快照的 session（实测 8 个中有 5 个取不到）会保留扫描推出的未决请求，
且不受 `historicalAsyncCallIDs` 过滤。这是下一步要查的假设，目前没有证据。

### 症状出现时请执行

```sh
AGENTISLAND_PROBE=1 swift test --filter RealStateProbe
```

只读，只印数量与状态（不印任何问题或命令文字）。直接使用真正的扫描器，不再有手写模拟漂移的问题；原先的 Python 诊断脚本因 transcript 模拟不忠实已被删除。
非零的那一个就是餵给 HUD 的来源，据此才能定位，而不是继续猜。

## 2026-11-05 深夜：真正的根因（已用真实资料复现并验证）

此前三轮的判断都没有抓到它，原因要先交代清楚。

**我的诊断工具是错的。** 前面报告「transcript 来源为 0」时用的是自己写的 Python 脚本，它在 `task_complete`
时清空待处理清单。真正的 `SessionState` 会**跨回合保留异步问题**，所以脚本系统性低估，而我据此得出
「资料里没有、一定是记忆体问题」的错误结论（并因此加了 120 秒携带期，那个修改本身无害，但不是病因）。
改成让真正的 Swift 程式码（`LogScanner` + `SessionState`）直接读真实资料后，症状立刻复现。

**复现**：`requests=9`，两个会话分别为 2 个与 7 个，**与使用者截图中的 2 + 7 完全一致**；全部是异步问题、
全部没有 IPC 详情（即「尚未获得实时请求详情」），所以来源是 transcript 路径。

**根因**：`retainOutstandingAsyncQuestions` 在新回合开始时把未答的异步问题全部保留。一个跑了 70 多个回合的会话，
每个没答的异步问题都会永远挂着。IPC 的「历史问题」隐藏只作用于 IPC 来源的请求，对 transcript 来源无效；
而可连上 IPC 的会话，其 IPC 快照里根本没有这些问题，所以也没有任何东西会清掉它们。

**修法**（`SessionState`）：问题可以活过**自己所在回合**的结束（保留此前已验证过的「回合结束后仍可回覆」），
但不再活过**更新的回合**。只有当新旧回合 id 都存在且不同时才取代；缺 turn id 或同一回合重复开始时保守保留。
被取代的 id 另外记在 `supersededAsyncRequests`，之后若出现对它的明确回答，仍会记录给 hook 事件流对账。

**真实资料验证**：修复前 `requests=9`，修复后 `requests=0`、状态 `completed`。

**未处理**：hook 路径（`HookStateStore`）仍然跨回合保留问题，没有改动 —— 使用者没有安装 Codex hook，无法验证；
装了 hook 的人可能还会看到同类的旧问题。

此前文中「isComplete 闸门不是病因」「症状无法复现」的结论仍然成立，但「剩下最可能的是 transcript 路径」
这个假设现在已得到证实。

## 待完成的实机验证（隔离预览）

隔离预览：`work/codex-history-fix-preview/AgentIsland.app`
（bundle id `local.agentisland.isolatedpreview`，独立偏好与锁档，可与日常 app 并存；临时签名、未公证）。

日常 app 保持 09-26 构建未改动，SHA-256 `05e501bf…`，与 `backup-20261105/binaries.sha256` 一致。

以下六项全部需要实机确认，目前**均未完成**：

- [ ] 执行中显示黄色，且不被任何旧问题压成红色
- [ ] 最新轮次真正未答的问题仍显示红色，可正常打开面板
- [ ] 旧轮次的历史问题不再出现（重点：曾出现「一堆」的那个会话）
- [ ] 多个 Codex 会话之间互不干扰，隐藏只作用于各自会话
- [ ] 重启隔离预览后状态正确，历史问题不复现
- [ ] 无害问题的选项与文字回复仍能送达（**禁止用命令审批做测试**）

验证时请记录版本、复现步骤和不含敏感内容的截图。确认通过后再决定是否更新日常 app。
