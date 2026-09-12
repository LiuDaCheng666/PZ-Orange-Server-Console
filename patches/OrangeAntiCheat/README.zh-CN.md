# OrangeAntiCheat 2.7.0 Java Agent

本补丁在服务端 Java 层拦截原版 `OnClientCommand` 事件中的 14 个危险命令路径。
它不修改 `media/lua/server/ClientCommands.lua`，不会造成客户端 Lua 校验不一致，
也不要求玩家安装 Mod。

## 防护范围

- 只读审计客户端提交的 `AddExplosiveTrapPacket`，持久记录 SteamID、账号、物品类型和
  坐标。普通燃烧瓶、炸弹等单次投放只是正常线索；普通锤子等没有爆炸、燃烧、烟雾、
  噪声或感应参数的载荷反复进入该通道时，Web 才聚合为高危。
- 该审计不拒绝数据包、不创建或删除物品，也不修改陷阱逻辑。它补足原版日志证据进入
  Agent 持久事件文件的缺口，避免控制台轮转后丢失。

- 校验所有带非空 `extra` 的 `ItemTransaction`，包括同容器变换和背包丢到地面的
  跨容器交易。客户端只能换成原物品
  `ClothingItemExtra` 明确列出的真实物品类型；利用临时载体把物品替换为水晶、武器
  或其他任意类型时，服务端会拒绝交易。
- 对没有 `ClothingItemExtra` 白名单的普通物品，只允许保持原类型；客户端不能借背包
  内变换或丢到地面的 `extra` 字段把锤子、衣物或临时载体变成金锭等任意注册物品。
- 变换载体必须真实存在于来源容器，且来源必须是发包玩家的直接背包或嵌套背包。
- 服务器明确授予 `EditItem` 能力的管理角色可执行物品编辑；只按服务端角色能力判断，不按名称、
  显示标签或客户端声明放行。
- 非法替换会输出 `blocked_item_transform`，包含账号、SteamID、载体、目标物品和坐标，
  并用 `route=same_container|cross_container` 标记路径，供 Web 反作弊作为明确高危证据展示。
- 审计客户端回写的 `PlayerHealthPacket` 与 `PlayerDamagePacket`。单次身体部位或整体生命增加
  超过 1 点、感染被清除、感染时间倒退超过 1、最大负重增加超过 20、NaN/Infinity，或目标
  不属于发包连接时，输出 `observed_health_sync`。
- 健康同步当前仅记录，不拒绝数据包、不恢复旧生命值，也不修改伤口状态。自然恢复和治疗仍可能
  产生记录，因此这些事件只作为人工复核线索，不能单独定性或自动处罚。
- 服务器授权管理员连接（拥有 `UseHealthCheat`）和 Web/原版健康管理操作签发的 15 秒目标授权
  不产生健康异常记录。普通玩家不会因为账号名称类似管理员而获得豁免，判断使用服务端角色能力。

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

2.5.0 起，实际阻断事件和限频后的健康观察同时写入每服独立的
`cachedir/Lua/OrangeAntiCheat-events.jsonl`。单文件上限 8 MiB，滚动保留 5 份；
Web 面板读取该文件后，控制台滚动或服务器重启不会再让高危证据消失。写入失败只输出
限频警告并回退到控制台，不改变拦截结果，也不写入世界或角色存档。

补丁只支持经过 SHA-256 审计的 `LuaEventManager.class`、`TransactionManager.class`、
`PlayerHealthPacket.class`、`PlayerDamagePacket.class` 和 `AddExplosiveTrapPacket.class`。
游戏更新后若类文件变化，Agent 会拒绝修改对应功能并输出 `guard_disabled`；其余服务端
继续使用原版行为，避免盲目注入。

2.7.0 起，同一 SteamID、事件/命令与原因在 30 秒内的重复日志会在内存中聚合；危险请求仍然
逐次阻止，只有磁盘与控制台记录降频。下一次窗口记录包含 `suppressedSincePrevious`，Web 会把
该数值计入事件次数。聚合表最多保留 4096 个键并清理 5 分钟未使用项，不启动后台线程。

## 从源码构建

源码、版本常量和审计钩子已与 2.7.0 构建目标对齐。使用 JDK 25 执行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\patches\OrangeAntiCheat\build.ps1 `
  -ServerRoot "D:\PZ_Sub server"
```

构建脚本会针对服务器当前的 `java/projectzomboid.jar` 运行五类字节码注入测试，并将
产物写到 `patches/OrangeAntiCheat/build/OrangeAntiCheat-agent.jar`。构建不会覆盖 Web
内置 JAR 或服务器正在使用的 `server-patches/OrangeAntiCheat-agent.jar`；部署仍由 Web
补丁管理执行，并且只有下一次完整重启服务器后才会改变运行中的 Agent。
