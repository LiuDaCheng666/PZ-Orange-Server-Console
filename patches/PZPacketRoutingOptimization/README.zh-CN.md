# PZ 数据包定向路由优化

适用版本：Project Zomboid Build 42.20.4 专用服务器。

## 修复内容

1. `SyncIsoObject` 按数据包中的世界坐标检查连接相关范围。已经完整进入服务器、但未加载该区域的玩家不再接收该对象更新。畜舍、炉灶、发电机、门和 Mod 世界对象均覆盖。
2. `lgd_antibodies/shareMedicalFile` 保留服务器每游戏分钟的疾病计算，只把同一医疗文件发给同一连接的展示同步限制为默认每 20 秒一次。
3. 每 300 秒仅在有流量时输出聚合统计，不逐包写日志。
4. 对原版 `IsoHutch` 鸡舍同步保存同一连接上一次已发送的完整字节。20 秒内只有逐字节完全相同的重复包会跳过；状态改变立即发送，20 秒心跳也会强制发送。
5. 对农业 `ObjectModData` 按“连接、坐标、层高、对象索引”保存上次已发送的完整字节。原版每十个游戏分钟会对所有耕地调用 `transmitModData()`，即使空耕地没有变化也会广播；补丁只跳过完全相同的副本，浇水、生长、病害、收获和新开垦仍立即发送。
6. 每个已连接玩家最多每秒读取一次 RakNet 统计，聚合发送队列、重发队列、丢包、拥塞控制和带宽限制。只在五分钟窗口达到阈值时输出该玩家、SteamID 和峰值，不修改或丢弃该连接的数据包。

农业去重默认开启，默认每 5 分钟放行一次相同状态作为兜底心跳；缓存最多 32768 项，15 分钟无访问自动清理。缓存达到上限时只会淘汰旧记录并恢复原版发送，不会丢失新状态。

鸡舍去重默认关闭，必须显式配置 `hutchDedup=true` 才启用，便于单服灰度。

各 Mod 模块采用“识别到对应命令或世界对象才工作”的方式：未安装抗体、农业或畜牧相关内容时，相应路径只是快速返回，不要求手工切换，也不会扫描工坊目录。统计中某模块持续为 `0` 表示该窗口没有识别到对应流量，不代表 Agent 未加载。

## 为什么安全

- 不修改存档、地图对象、容器、人物数值或 ModData。
- 不过滤拾取、容器转移、长读条确认、车辆交互等操作包。
- 只取消发送给未加载对象所在区域的 `SyncIsoObject`；玩家进入区块时仍从区块数据获得完整对象状态。
- Antibodies 的服务器计算完全不节流，最坏只是状态界面最多延迟约 20 秒刷新。
- 鸡舍必须按包中坐标和对象索引解析到真实 `IsoHutch` 才参与比较；首次、内容变化、心跳到期或任何解析异常都原样发送。
- 鸡舍采用完整字节比较，不依赖有碰撞概率的短哈希；缓存有数量上限和过期清理，不修改鸡蛋或世界对象。
- 农业包必须在服务端解析到真实方格对象，并同时具有 `state`、`nbOfGrow`、`health`、`waterLvl`、`objectName` 字段才参与去重；首次、内容变化、方格未加载、索引异常或任何内部异常都原样放行。
- 不延迟或合并变化后的农业数据，不修改 `SFarmingSystem`、作物数值、成长时间、产量或地图文件。
- 连接遥测只读 `UdpConnection.getStatistics()`，每连接最多每秒一次；故障时直接放行原始发送流程，记录 `telemetryFailOpen`。
- 对两个被修改的原版类使用 B42.20.4 SHA-256 白名单并校验各一个调用点。游戏更新导致字节码变化时，补丁拒绝注入并回退原版逻辑。

## 启动参数

```text
-javaagent:server-patches/PZPacketRoutingOptimization-agent.jar=syncIsoObject=true,antibodies=true,antibodiesIntervalMs=20000,farmingDedup=true,farmingHeartbeatMs=300000,farmingCacheMax=32768,farmingCacheTtlMs=900000,connectionTelemetry=true,telemetryIntervalMs=1000,telemetryStaleMs=900000,reportSeconds=300
```

运行统计中的 `farmingSent` 是首次或发生变化后正常发送的农业包；`farmingDuplicateSkipped` 和 `farmingSkippedBytes` 是避免的完全重复包；`farmingFailOpen` 非零表示识别异常且已回退原版发送。

`connection` 行只报告有明显拥塞、积压、重发或丢包的连接。它用于判断“只有某个玩家卡交互”是否是该连接的可靠队列问题；它不是限速器，也不会自动踢人。

停服后删除该参数即可停用。补丁不写存档，因此停用不需要修档。
