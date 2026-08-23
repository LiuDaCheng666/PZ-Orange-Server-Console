# OrangeAntiCheat 2.4.1 Java Agent

本补丁在服务端 Java 层拦截原版 `OnClientCommand` 事件中的 14 个危险命令路径。
它不修改 `media/lua/server/ClientCommands.lua`，不会造成客户端 Lua 校验不一致，
也不要求玩家安装 Mod。

## 防护范围

- 校验所有带非空 `extra` 的 `ItemTransaction`，包括同容器变换和背包丢到地面的
  跨容器交易。客户端只能换成原物品
  `ClothingItemExtra` 明确列出的真实物品类型；利用临时载体把物品替换为水晶、武器
  或其他任意类型时，服务端会拒绝交易。
- 对没有 `ClothingItemExtra` 白名单的普通物品，只允许保持原类型；客户端不能借背包
  内变换或丢到地面的 `extra` 字段把锤子、衣物或临时载体变成金锭等任意注册物品。
- 变换载体必须真实存在于来源容器，且来源必须是发包玩家的直接背包或嵌套背包。
- 非法替换会输出 `blocked_item_transform`，包含账号、SteamID、载体、目标物品和坐标，
  并用 `route=same_container|cross_container` 标记路径，供 Web 反作弊作为明确高危证据展示。
- 审计客户端回写的 `PlayerHealthPacket` 与 `PlayerDamagePacket`。单次身体部位生命增加超过
  1 点、NaN/Infinity 或目标不属于发包连接时，输出 `observed_health_sync`。
- 健康同步当前仅记录，不拒绝数据包、不恢复旧生命值，也不修改伤口状态。自然恢复和治疗仍可能
  产生记录，因此这些事件只作为人工复核线索，不能单独定性或自动处罚。
- 管理员连接和服务端已授权的健康面板操作不产生健康异常记录。

- 普通玩家不能调用容器强制刷新、点火、烟雾、爆炸和调试液体命令。
- 普通玩家不能直接修改伤势、体重、侵蚀或触发调试雷暴。
- 车内睡眠和丢下重物只能以玩家自己的 OnlineID 为目标。
- 具有 `UseDebugContextMenu` 或 `UseHealthCheat` 能力的管理员仍可正常使用对应功能。
- 管理员修改其他玩家健康时，服务端签发 15 秒、单次使用且严格匹配目标、身体部位
  和动作的一次性授权；解决合法回传被误拦，同时继续阻断伪造、过期和重放请求。

## 运行方式

```text
-javaagent:server-patches/OrangeAntiCheat-agent.jar
```

Web 面板的 OrangeAntiCheat 挂载开关统一管理三个服务器的启动参数。切换后需要完整
重启相应服务器。补丁不写世界、角色数据库或 ModData，移除启动参数即可回退。

补丁只支持经过 SHA-256 审计的 `LuaEventManager.class`、`TransactionManager.class`、
`PlayerHealthPacket.class` 和 `PlayerDamagePacket.class`。
游戏更新后若类文件变化，Agent 会拒绝修改对应功能并输出 `guard_disabled`；其余服务端
继续使用原版行为，避免盲目注入。
