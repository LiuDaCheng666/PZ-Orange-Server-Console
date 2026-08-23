# OrangeAntiCheat 2.1.0

这是 Web 面板内置的服务端命令鉴权 Java Agent，不属于创意工坊 Mod，也不要求
客户端订阅。它在原版 `OnClientCommand` 进入 Lua 事件处理器之前检查 14 个危险
命令，不修改 `media/lua/server/ClientCommands.lua`，因此不会造成客户端文件校验
不一致。

面板的“挂载到全部服务器”开关负责给每个托管配置增删以下 JVM 参数：

```text
-javaagent:server-patches/OrangeAntiCheat-agent.jar
```

启用时，面板会先把内置并经过校验的 JAR 自动部署到各服务器运行目录；创建新的
托管服务器配置时也会自动补齐该文件，不需要再手工复制补丁。

使用同一运行目录的多个服务器可以共享一个 Agent JAR，但是否已经装入当前 Java
进程仍会按服务器分别显示。切换开关后，运行中的服务器必须完整重启才改变行为。

普通玩家调用容器强制刷新、点火、烟雾、爆炸、调试液体、健康作弊、体重修改、
侵蚀关闭或雷暴命令时会被拒绝；车内睡眠和丢下重物只能以本人 OnlineID 为目标。
具有 `UseDebugContextMenu` 或 `UseHealthCheat` 能力的管理员仍可使用对应命令。

管理员修改其他玩家健康时，Agent 会签发一个有效期 15 秒、只能使用一次，并严格
匹配目标 OnlineID、身体部位和动作的一次性授权。目标客户端的原版健康回传因此可
正常通过；无授权、过期、目标不符或重放的回传仍会被拒绝并记录。Web 审计会把已
配对回传标为“管理员授权操作”，保留记录但不对目标玩家增加风险分。

Agent 只支持经过 SHA-256 审计的 B42.20.2 `LuaEventManager.class`。游戏更新改变该类
时会输出 `guard_disabled` 并保持原版行为，不会盲目注入。补丁不写世界存档、角色
数据库或 ModData，移除启动参数并重启即可回退。

被拒绝的调用继续输出 `[OrangeAntiCheat] event=blocked_client_command` 结构化日志，
Web 反作弊、玩家审计、SteamID 封禁和 PZAI 手动诊断页面可以继续使用这些证据。
