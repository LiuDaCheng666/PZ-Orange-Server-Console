# PZ ItemPickInfo 尸体容器 ID 注册修复

## 修复内容

Project Zomboid 42.20 的 `ItemConfigurator.Preprocess()` 会收集房间、区域、车辆、容器物品和
地图贴图中的容器名称，并为 ItemConfig 选择器建立整数 ID。原版尸体容器
`inventorymale`、`inventoryfemale` 只存在于掉落分布表，没有被上述来源注册。

服务器为尸体生成或配置物品时，`ItemPickInfo.GetPickInfo()` 因此反复输出：

```text
ItemPickInfo -> cannot get ID for container: inventorymale
ItemPickInfo -> cannot get ID for container: inventoryfemale
```

本补丁在原版 `Preprocess()` 已完成其他字符串收集、但尚未调用 `ItemConfig.BuildBuckets()` 时，
仅补充注册这两个名称。它不隐藏日志，也不跳过物品配置流程；补完后尸体容器选择器可以按
原版整数 ID 路径正常匹配。

## 安全设计

- 只支持已审核的 42.20 `ItemConfigurator.class` SHA-256；版本变化时拒绝修改并保持原版。
- 同时校验 `Preprocess()V` 和唯一 `getAllItemConfigs()` 调用点，方法形状异常时保持原版。
- 注册前先查询 ID；原版或其他补丁已经修复时不重复注册。
- 运行注册异常会被捕获，原版预处理继续执行。
- 每次 `Preprocess()` 只做两个哈希表查询和最多两次插入，没有 Tick、玩家或区块循环。

## 启用与验证

将 JAR 放入服务器 `server-patches`，在 Java 主类之前加入：

```text
-javaagent:server-patches/PZItemPickInfoContainerFix-agent.jar
```

完整重启后应出现：

```text
[PZItemPickInfoContainerFix] ACTIVE ItemConfigurator.Preprocess hook
[PZItemPickInfoContainerFix] registered inventorymale=... inventoryfemale=... before ItemConfig bucket build
```

随后新日志中不应再出现两个 `ItemPickInfo -> cannot get ID`。出现 `REFUSED` 表示游戏版本或
字节码结构变化，补丁没有生效，但服务器继续使用原版行为。

## 影响与回退

这是服务端 Java Agent，不是工坊 Mod，客户端无需订阅。补丁不改存档、地图、尸体、掉落表、
物品概率、交易 Mod 数据或网络协议。启用前已经生成的物品保持不变；它只让后续 ItemConfig
获得正确的尸体容器 ID。

停用时完整停止服务器，删除启动参数后重启。启用和停用都不需要清档，也不会导致区块丢失。
