# PZ 玻璃附件死循环防护

适配 Project Zomboid `v42.20.2` 与 `v42.20.3`，服务端专用。

## 修复内容

原版 `IsoGridSquare.removeGlassAttachments()` 在砸窗时逐个删除窗帘、百叶窗和墙面灯等附件。原实现无条件回退列表索引；如果对象移除失败或事件回调改变了同一列表，会永久重复处理同一个对象，导致世界主线程单核满载，`save` 和 `quit` 均无法执行。

本补丁在启动时通过 Java Agent 将该方法替换为有界快照清理：

- 每个原始附件最多处理一次；
- 正常对象仍调用原版 `RemoveTileObject()`；
- 移除失败时跳过对象并记录坐标、对象类型和 Sprite；
- 单个格子默认最多检查 512 个对象，硬上限 4096；
- 不修改存档格式，不要求客户端安装；
- 只接受已验证的 `IsoGridSquare.class` SHA-256。游戏更新后哈希不符会拒绝注入。

## 启动验证

正常启动日志必须出现：

```text
[PZGlassRemovalGuard] ACTIVE: IsoGridSquare.removeGlassAttachments is guarded.
```

若出现 `REFUSED`，不要让玩家砸窗，应先重新验证新版本字节码。

## 卸载

从启动命令删除：

```text
-javaagent:server-patches/PZGlassRemovalGuard-agent.jar
```

无需转换存档，也不会坏档。

也可以在服务器停止后执行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1
```

该脚本恢复部署前备份的两份启动脚本，并保留代理 JAR 供审计。
