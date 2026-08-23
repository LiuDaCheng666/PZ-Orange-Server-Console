# PZ B42 选择性区块刷新工具

用于 B42.20 存档的离线审计和选择性地图区块刷新。

## Web 控制台

登录 `http://127.0.0.1:8790/` 后打开“地图刷新”。Web 页面按服务器分别保存保护配置，
默认安全屋外扩 2 区块、存活人物外扩 8 区块，并可编辑任意数量的手动保护矩形。

1. 保存保护配置。
2. 点击“运行只读审计”，检查拟刷新区块和容量。
3. 正常保存并停止目标游戏服务器。
4. 输入页面显示的 `serverName`，再次确认后正式执行。
5. 检查报告和隔离目录，再从面板手动启动服务器。

只有 Web 保留管理员 `admin` 可以保存、审计和执行。正式执行要求最近一次成功审计
与当前配置完全一致，不会自动停止或启动服务器，也不会永久删除区块。

## 为什么不用原版软重置

B42.20.2 仍保留 `-Dsoftreset`，但当前实现只匹配旧文件名
`map_X_Y.bin`。B42.20 实际区块位于 `map\X\Y.bin`，因此软重置会跳过
这些地图区块，无法可靠完成物资刷新。

## 默认保护

- `map_meta.bin` 内的全部原版安全屋（橙子安全屋也使用原版 SafeHouse）
- `players.db` 内全部存活人物的当前位置
- `players.db`、`vehicles.db`、`map_meta.bin`、`global_mod_data.bin`
- `WorldDictionary.bin`、`entity_data.bin` 和所有派生数据目录

安全屋默认多保护 1 个区块（8 格），人物位置默认多保护 2 个区块（16 格）。

## 审计

服务器运行时可以审计，但不能执行：

```powershell
& "<Python安装目录>\python.exe" `
  ".\pz_selective_world_reset.py" `
  --save-root "D:\PZServerData\Saves\Multiplayer\servertest" `
  --server-name "servertest" `
  --report-dir "<面板目录>\reports\selective-world-reset"
```

报告包含安全屋、人物、车辆、保护区块及拟刷新区块清单。默认不会修改存档。

公共商店、公共基地或未申领区域应写入额外保护文件，可参考
`protect-areas.example.json`，并加参数：

```text
--manual-areas .\protect-areas.json
```

## 执行

必须先正常关闭目标服务器，再显式确认：

```text
--apply --confirmation servertest
```

工具不会永久删除区块，而是移动到同级隔离目录，并备份关键数据库和元数据。
回滚时应保持服务器关闭，将隔离目录中的 `map` 区块移回原存档。

## 影响范围

未保护区块会按当前地图和模组重新生成，包括容器物资、门窗、植被及世界对象。
未保护区域内的玩家建筑、落地物品、尸体和人工摆设也会消失。人物背包和装备保存在
`players.db`，不会随地图区块刷新。车辆保存在 `vehicles.db`，工具不删除车辆数据库，
但报告会列出落在拟刷新区块内的车辆供复核。
