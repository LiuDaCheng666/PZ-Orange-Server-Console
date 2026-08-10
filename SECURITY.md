# 安全说明

## 不要公开提交凭据

请勿在 Issue、Discussion、Pull Request、日志或截图中提交：

- AI API Key、Token 或 `ai-credential.dat`
- Web 管理员密码、`users.json` 或 `access-token.txt`
- Project Zomboid 游戏内 `admin` 密码或 RCON 密码
- Steam 登录凭据
- 玩家 SteamID、IP、私聊、处罚证据等隐私数据
- 私服目录中的 `服务器信息库` 实际内容

仓库 `.gitignore` 已排除常见运行态文件，但提交前仍应人工检查。

## 报告安全问题

仓库启用后，请优先使用 GitHub 的私有安全报告功能，不要直接创建包含复现密钥、
真实玩家数据或公网服务器地址的公开 Issue。

报告中可提供：

- 受影响版本
- 不含隐私的最小复现步骤
- 预期行为与实际行为
- 已脱敏的日志片段
- 建议修复方向

发现 API Key 或密码已经公开时，应先在对应服务商处撤销或轮换，再处理 Git 历史。
