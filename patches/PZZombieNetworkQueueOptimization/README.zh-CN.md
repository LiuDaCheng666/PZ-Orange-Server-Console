# PZZombieNetworkQueueOptimization

面向 Project Zomboid 42.20.4 专用服务器的独立 Java agent。它只优化
`zombie.popman.NetworkZombiePacker.postupdate()` 中逐连接构造僵尸发送队列时的
`LinkedList.contains(IsoZombie)` 热点，不修改存档、网络协议或僵尸同步上限。

## 兼容性与拒绝策略

- 目标 class：`zombie/popman/NetworkZombiePacker.class`
- 唯一支持的 class SHA-256：
  `5B202038B360877E8A308265E6BF7CE720E34D0C3670ADFB3A7C5DBDDAF5197E`
- 构建时支持的 `projectzomboid.jar` SHA-256：
  `80E405A4BFC42F6072E75B3735F458A6514143DA011D3226007DED305A442F44`
- 转换前还会验证 `postupdate()V` 仅有一处目标 `contains`，且条件未命中后使用
  同一个 `NetworkZombie.zombies` 字段和同一个候选对象执行 `LinkedList.add`。
- class 哈希或字节码契约任一不匹配时，转换器返回 `null`，JVM 继续使用完整原版类。

## 工作机制

每个服务器线程、每个当前连接的僵尸列表使用一个短生命周期状态：

1. 列表长度小于 `threshold` 时始终调用原版线性 `contains`。
2. 每个新列表的前 `linearQueries` 次查询始终调用原版线性 `contains`。
3. 默认从第 4 次大列表查询开始，用 `IdentityHashMap` 构建身份集合。
4. 集合未命中的候选会先在身份集合中预留；原版紧随其后的 `LinkedList.add` 保持不变。
5. 切换连接/列表会释放前一列表；`postupdate` 正常返回和异常传播都会清除列表与僵尸引用，只保留空索引容量供下一帧复用。

`IsoZombie` 在目标版本未覆盖 `equals/hashCode`，所以原版 `LinkedList.contains` 的语义就是
对象身份比较。若未来版本改变该事实，严格 class 哈希会阻止补丁加载。

运行时遇到 `RuntimeException`、`LinkageError` 或 `OutOfMemoryError` 时会清空状态并永久
熔断，后续全部回退原版 `LinkedList.contains`。`ThreadDeath`、`StackOverflowError` 和
`InternalError` 不会被吞掉或转换成普通回退。

## 参数

示例（这里只展示参数，不代表已经部署）：

```text
-javaagent:server-patches/PZZombieNetworkQueueOptimization-agent.jar=enabled=true,threshold=64,linearQueries=3,reportSeconds=300
```

| 参数 | 默认值 | 安全范围 | 说明 |
| --- | ---: | ---: | --- |
| `enabled` | `true` | `true/false` | `false` 时完整使用原版查询 |
| `threshold` | `64` | `64..1000000` | 小于该长度不建身份集合 |
| `linearQueries` | `3` | `3..1024` | 每个新列表先执行的线性查询数 |
| `reportSeconds` | `300` | `30..86400` | 汇总日志周期 |

非法参数会保留该项默认值；越界数值会夹紧到安全范围。

## 构建与验证

在本目录运行：

```powershell
powershell -ExecutionPolicy Bypass -File .\build.ps1
```

脚本会：

- 使用 `D:\PZ_Sub server\java\projectzomboid.jar` 验证目标版本并编译；
- 使用 `D:\PZ_Sub server\jre64\bin\java.exe` 执行全部测试；
- 执行 ASM 转换契约测试、身份语义/故障熔断测试；
- 用 `-Xverify:all` 和实际游戏类执行 Java agent 类加载测试；
- 执行队列长度 `0/16/64/300/1000/5000` 的微基准；
- 在本目录生成 `PZZombieNetworkQueueOptimization-agent.jar`。

微基准用于确认算法随队列长度增长的趋势，不等同于正式服 TPS 或延迟测试。

## 部署与回退

部署必须安排完整停服窗口，将 JAR 放入服务器补丁目录并添加上面的 `-javaagent` 参数，
随后冷启动。不要在玩家在线时热注入。回退时完整停服，删除该启动参数和 JAR 后再启动；
补丁不写存档，因此不需要迁移存档。
