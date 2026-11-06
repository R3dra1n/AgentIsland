# 贡献指南

目前代码以 MIT 发布。请仅提交你有权按该许可贡献的代码，注明第三方来源及许可，保留必要版权声明。当前尚未启用 CLA；新增协议不会自动约束过去的贡献。不要把 CLA 签名、地址等资料提交到公开仓库。

提交前运行：

```sh
python3 scripts/check_public_source.py
bash scripts/test.sh
```

PR 请描述触发问题的场景、改变后的行为、验证结果与支持的助手版本。
不要提交真实聊天、审批内容、API key、个人路径或生成的本机 Hook 配置。测试用合成数据。
不同助手的适配应保持隔离，Codex 修复不应改变 Antigravity 行为。完成提示持续至用户确认；Antigravity GENERIC 后台事件不能独立开始一个用户任务。

提升版本号只改根目录的 `VERSION`（构建号取提交数，自动递增），并在 `CHANGELOG.md` 记录。日常测试请用隔离预览渠道（`bash scripts/build_isolated_preview.sh`），不要覆盖正在使用的正式版。

诊断「界面上显示的东西从哪来」时，用真正的扫描器而不是自己写的模拟：`AGENTISLAND_PROBE=1 swift test --filter RealStateProbe`。它只读、只印结构（数量、状态、截短的标识），不印任何问题、命令或提示词文字，默认被跳过。手写的 reducer 副本会漂移，曾经因此得出过错误结论。
