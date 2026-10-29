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
