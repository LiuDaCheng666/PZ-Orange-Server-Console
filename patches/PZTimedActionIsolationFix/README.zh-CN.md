# PZ 联机长读条跨玩家隔离补丁

## 修复内容

Project Zomboid 42.20 的 `ActionManager.stop(Action)` 在服务端最终调用
`remove(byte actionId, boolean)`。该删除逻辑只比较 1 字节动作 ID，不比较玩家 ID。
不同客户端各自生成动作编号，因此多人服中编号重复是正常现象。一名玩家取消或替换动作时，
原版逻辑可能把其他玩家同编号的制作、锻造、拆解、加油等动作一起从服务端队列删除。
被误删玩家收不到 `Done` 或 `Reject`，表现为读条结束后没有结果、长时间卡住。

本补丁仅在服务端拦截 `ActionManager.stop(Action)`：

- 按传入的动作对象精确删除并执行原版 `stop()`；
- 保留对应 `NetTimedAction` 的动画模拟器清理；
- 不再删除其他玩家碰巧具有相同 byte ID 的动作；
- 客户端路径、正常完成、正常拒绝和 30 分钟超时清理保持原版；
- 发现真实撞号时输出 `prevented cross-player removal` 统计，便于验证。

## 启用

在 Java 启动参数中加入：

```text
-javaagent:server-patches/PZTimedActionIsolationFix-agent.jar
```

启动成功必须出现：

```text
[PZTimedActionIsolationFix] ACTIVE exact per-player timed-action stop
```

该补丁和 `PZTimedActionTrace` 都修改 `ActionManager.class`，不能同时加载。诊断完成后应以本补丁
替换探针参数。出现 `REFUSED` 表示游戏版本哈希变化，补丁保持原版行为，必须重新审核字节码，
不能直接添加新哈希。

## 影响与停用

这是服务端 Java 补丁，不是工坊 Mod，客户端无需订阅。它不写存档、不改物品、不改配方，
不会因为启用或停用而坏档。停用时完整关闭服务器，删除对应 `-javaagent` 参数后重启；
不要只删除 JAR 而保留启动参数。

玩家日志中坐标 `10097,8326,0` 的 `ObjectModDataPacket.parse: object is null` 属于另一条
对象同步问题，不由本补丁处理。
