# PZ ItemContainer 循环防护

适用于当前服务器使用的 Project Zomboid Build 42.20.x 专用服务器。

## 修复内容

- 防止异常物品/尸体容器的 `containingItem` 链形成自身回指或循环后，触发
  `ItemContainer.getCharacter()` 无限递归和 `StackOverflowError`。
- 正常容器仍按原版顺序查找所属角色。
- 异常链返回“无所属角色”，只跳过依赖该归属判断的一次网络同步，不删除物品、不修改存档。
- 首次命中及之后每 30 秒最多记录一条 `[PZItemContainerCycleGuard] BLOCKED`，避免刷日志。
- 最多跟随 64 层容器；正常游戏嵌套远低于该值。

## 安全边界

- 只替换 `zombie.inventory.ItemContainer.getCharacter()`。
- 仅接受已验证的原版类 SHA-256；游戏更新导致类变化时自动拒绝注入，并保留原版行为。
- 不依赖 Talis New Music，也不会改写该 Mod。NewMusic 只是本次触发异常容器路径的组件。

## 启用

在 Java 启动参数中加入：

```text
-javaagent:server-patches/PZItemContainerCycleGuard-agent.jar
```

启动日志必须出现：

```text
[PZItemContainerCycleGuard] ACTIVE ItemContainer.getCharacter
```
