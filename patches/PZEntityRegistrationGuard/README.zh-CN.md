# PZ 重复实体注册防护

适用版本：Project Zomboid `42.20.2` 当前服务端文件。状态：服务端 Java Agent。

## 解决的问题

区块载入时，原版可能对同一个 `GameEntity` 对象再次调用
`EngineEntityManager.addEntityInternal`。原版检测到对象已经位于 `entitySet` 后会抛出
`Entity is already registered`。连续异常会中断 `ServerCell.Load2` 并可能冻结主线程。

本补丁只处理以下条件同时成立的重复调用：

1. `entitySet` 已包含同一个 Java 对象；
2. 对象状态为 `addedToEngine=true`；
3. 对象没有处于计划删除或正在删除状态。

此时第二次调用是幂等重复注册，补丁记录一次限频统计后返回。以下情况仍执行原版逻辑并报错：

- 不同对象使用相同实体 ID；
- 对象集合与状态标志不一致；
- 对象正在删除或等待删除；
- 任何非目标异常。

补丁不修改实体 ID、组件、区块、ModData、数据库或存档内容。

## 启用和停用

把 `PZEntityRegistrationGuard-agent.jar` 放入服务端 `server-patches`，在 Java 启动参数中加入：

```text
-javaagent:server-patches/PZEntityRegistrationGuard-agent.jar
```

必须完全停止并重新启动服务器。停用时停止服务器，删除该 `-javaagent` 参数后重启；不需要迁移存档。

启动成功会出现：

```text
[PZEntityRegistrationGuard] ACTIVE EngineEntityManager.addEntityInternal ...
```

发生防护时会出现 `suppressed idempotent duplicate registration`，日志只记录累计次数、对象类名和 JVM 对象标识，不进行每 Tick 扫描。

## 版本门禁

Agent 只接受已测试的 `EngineEntityManager.class` SHA-256。游戏更新后哈希不匹配时会打印
`REFUSED unsupported` 并保持原版类不变。此时必须重新反编译、审查和测试，不能只替换哈希。
