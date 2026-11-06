# Antigravity 2.29.0 协定验证（2026-11-05）

本机安装的 Antigravity 已升级到 **2.29.0**。此前不在白名单内，后台回传 fail-closed，HUD 显示
「此 Antigravity 版本尚未验证，请在原应用回复」。本文记录验证过程与结论。

## 结论

**2.29.0 已加入白名单**（`AntigravityLocalTransport.supportsVersion`），依据是对一个**实际等待中的问题**
逐项比对 `AntigravityInteractionParser` 的约束，20 项全部通过，另有 98 笔历史回覆记录的结构佐证。

**尚未验证的部分**（因此回传功能仍是实验性、需要使用者实机验收）：

- 实际**送出**一次回覆。验证全程只读，没有送出任何回覆。
- **文字回覆**（`writeInResponse`）：历史记录里没有文字回覆的样本，只有选项回覆（`selectedOptionIds`）。
- 历史回覆记录的 `responses[]` 内带有 `options` 与 `isMultiSelect`（服务端存档时回填的栏位），
  而程式码送出的只有 `question` 与 `selectedOptionIds`。是否因此被接受，要靠实机验证。

近似版本仍然拒绝（`2.29.1`、`2.30.0` 等）：白名单里的是**实际检查过**的版本，不是「与检查过的版本接近」的版本。

## 传输层（只读验证）

| 项目 | 程式码要求 | 2.29.0 实测 |
| --- | --- | --- |
| `language_server` 行程 | 恰好 1 个、bundle id `com.google.antigravity` | 符合 |
| 签章 | Team ID `EQHXZ8M8AV`，签章验证通过 | 符合 |
| 本机监听埠 | 由 `lsof` 取得 | 5 个，其中 1 个提供 TLS |
| CSRF token | 命令列 `--csrf_token`，UUID 格式 | 符合 |
| 未授权探测 | `Heartbeat` 无凭证应回 **401**（`discover()` 的辨识条件） | 401 `unauthenticated: missing CSRF token` |
| 已授权呼叫 | `Heartbeat` 带 token 应成功 | 200 |
| 回应信封 | `trajectory.trajectoryId` 为 UUID、`steps` 为阵列 | 符合 |
| 目录结构 | `brain/<uuid>/.system_generated/logs/transcript.jsonl` | 未变 |

## 提问结构（对一个实际等待中的问题逐项比对）

一个 cascade，回应 2.8MB、124 个 step，恰有 1 个 WAITING 互动步骤。全部通过：

| 约束 | 结果 |
| --- | --- |
| `trajectoryId` 为 UUID；`steps` 为阵列且 ≤100000 | 通过 |
| WAITING 且带 `requestedInteraction` 的步骤恰好 1 个 | 通过 |
| `requestedInteraction` 的键恰好是 `["askQuestion"]` | 通过 |
| `questions` 恰好 1 笔；`question` 非空字串且 ≤16384 bytes | 通过 |
| `isMultiSelect` / `skipped` / `writeInResponse` / `selectedOptionIds` 缺省或为空 | 通过 |
| `options` 为物件阵列、≤9 个、`id`/`text` 皆非空字串、`id` 互不重複 | 通过（6 个） |
| `completedInteractions` 缺省或空；`timedOut` 缺省或 false | 通过 |
| step 内 `{trajectoryId, stepIndex}` 参照恰好 1 组 | 通过 |
| 该参照指向自身 trajectory，且 `stepIndex` 等于自身索引（防误配） | 通过（ref=123 self=123） |

结构键名：step 为 `askQuestion` / `metadata` / `requestedInteraction` / `status` / `type`；
`askQuestion` 只有 `questions`；question 为 `options` / `question`；option 为 `id` / `text`。

### 回覆格式的历史佐证

98 个步骤带有 `completedInteractions`，每笔的 `response` 为
`{trajectoryId, stepIndex, askQuestion: {responses: [{question, options, selectedOptionIds}]}}`，
与程式码组出的 `interaction` 结构一致。

## 回应大小上限：4MB 提高到 128MB

trajectory 是一份包含整段对话每一步的 JSON，随对话无界成长。实测 10 个最近的 cascade 中，
最小 0.8MB，**最大 56.4MB（约 7263 个 step）**，5 个超过旧的 4MB 上限。旧上限会让每一个长对话都以
「无法读取此会话的问题」失败，与版本无关。

- 上限集中到 `PinnedLoopbackHTTP.maximumResponse`（128MB，约为已观察最大值的 2.3 倍）。
  原本传输层、传输层包装、解析器各自写死一个 4MB，现在三处引用同一个常数，不会再漂移。
- 总时限从 10 秒提高到 30 秒，上限与时限都可注入，测试仍能验证「超限必拒、滴灌必断」。
- 读取方式从逐位元组累加改为分块接收，并在每个区块到达时检查上限、超限立即取消。

对同一个 56.4MB 的真实 trajectory 实测（只读查询）：

| | 传输 | 记忆体峰值 | 解析 |
| --- | --- | --- | --- |
| 旧（逐位元组，放宽上限与时限后） | 2.74s | 145MB | 0.28s / 峰值 221MB |
| 新（分块） | 1.09s | 86MB | 0.23s / 峰值 159MB |

坦白说：旧实作在 56MB 下约 2.7 秒，并没有超过原本的 10 秒时限，所以重写不是提高上限的必要条件。
新实作快约 2.5 倍、峰值记忆体低约 40%，且在 128MB 上限下旧实作约需 6 秒、逼近时限，因此保留。
解析本身很便宜，128MB 上限的最坏情况估计约 360MB 峰值（按 56MB → 159MB 线性推估，未实测）。

安全性质保持不变，并有测试覆盖：凭证钉选、不跟随重导向、未列出的 RPC 在发送前即拒绝、
宣告长度超限与串流超限都拒绝、上限为闭区间（恰好等于上限放行、多一个位元组即拒绝）。

## 需要使用者做的验收

用一个**无害的选择题**（例如「变数要叫 A 还是 B」）：

1. 选项回覆：点选一个选项，确认送到正确的会话、问题随之解除。
2. 文字回覆：另开一个无害问题，用自由文字回答（此项尚无任何样本佐证，最需要确认）。
3. 两个会话同时等待时，各自的回覆分别送到正确的会话。

**禁止用命令审批做这项测试。** 若任何一项失败，请回 Antigravity 原应用处理，并告知失败的那一项。

## 过程中的三次误判（记录以免重蹈）

验证过程中我连续三次得出「协定已变更」的错误结论，全部是诊断脚本自身的 bug：

1. 手工组 HTTP 标头时在 `Connection` 前多一个空格 → 伺服器回 400，被误判为「2.29 改用 400」。
2. Python `glob` 预设不匹配隐藏目录 → 找不到 `transcript.jsonl`，被误判为「目录结构改变」。
   （Swift 端对 antigravity 刻意不加 `.skipsHiddenFiles`，本来就是对的。）
3. 裸 socket 未解码分块传输编码 → 回应被当成非 JSON，被误判为「回应格式改变」。

教训：判定「上游协定变了」之前，先确认诊断工具本身是对的；三次都是工具错、协定没错。
