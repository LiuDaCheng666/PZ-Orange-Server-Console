# PZ 动物 LOS 优化补丁

适用版本：Project Zomboid Build 42.20.4 专用服务器。

## 优化内容

原版 `IsoAnimal.updateLOS()` 会让每只动物遍历当前 Cell 的全部移动对象，之后才忽略动物、物理对象、车辆和其他无关对象。本补丁只把该方法的候选集合改为：

- 当前动物自身
- 当前 Cell 的僵尸列表
- 服务端在线玩家列表

后续距离、楼层、隐身、管理员幽灵模式和 `BaseAnimalBehavior.spotted()` 仍执行原版逻辑。补丁不跳帧，不修改动物 AI、位置、存档或网络数据。

## 安全与回退

- 同时绑定 `projectzomboid.jar` 和 `IsoAnimal.class` 的 B42.20.4 SHA-256。
- 目标方法必须恰好找到一个 `IsoCell.getObjectList()` 调用点，否则拒绝注入。
- 运行时取专用列表发生任何异常时，当次调用自动回退到原版完整对象列表。
- 游戏更新后哈希不匹配时使用原版类，并在控制台输出 `REFUSED`。
- 停服后删除启动参数即可完全停用，不需要修档。

## 启动参数

```text
-javaagent:server-patches/PZAnimalLOSOptimization-agent.jar=enabled=true,reportSeconds=60
```

日志每 60 秒汇总一次动物 LOS 调用、原候选数、优化后候选数、过滤数和故障回退数。`failOpen` 应保持为 0。
