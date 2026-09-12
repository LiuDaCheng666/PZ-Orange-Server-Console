# PZ GlobalModData 首次保存预分配修复

适用版本：Project Zomboid Build 42.20.4 专用服务器。

## 修复内容

原版 `GlobalModData.save()` 在每次重启后首次保存时只分配 1 MiB，之后每溢出一次仅增长
512 KiB，并从当前表起点重新序列化。32-43 MiB 的存档会因此产生近 1 GiB 临时分配。

本补丁仅替换 `save()` 中唯一的初始 `ByteBuffer.allocate(int)`，按现有
`global_mod_data.bin` 长度加预留空间一次分配。表内容、序列化顺序、块长度和文件格式全部仍由原版代码处理。

## 安全与回退

- 同时绑定 `projectzomboid.jar` 和 `GlobalModData.class` 的 42.20.4 SHA-256。
- `save()` 必须恰好包含一个初始分配点，否则拒绝注入并使用原版。
- 默认预留 4 MiB，预分配上限 256 MiB；文件超限时使用原版容量。
- 预分配如果触发 `OutOfMemoryError`，当次自动退回原版 1 MiB 分配和原版增长路径。
- 不修改存档；停服后移除启动参数即可弃用，不需要修档。

## 启动参数

```text
-javaagent:server-patches/PZGlobalModDataPreallocationFix-agent.jar=enabled=true,headroomBytes=4194304,maxPreallocateBytes=268435456
```

正常启动后应出现：

```text
[PZGlobalModDataPreallocation] ACTIVE zombie/world/moddata/GlobalModData
```

保存时的 `allocation` 汇总行会显示现有文件大小、实际容量和避免的 512 KiB 扩容次数。
