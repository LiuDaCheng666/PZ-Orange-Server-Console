# PZ B42.20 SpriteConfig 动态贴图映射补丁

类型：仅服务端 Java Agent。

目标版本：当前服务器 Project Zomboid `42.20.x` 文件。

## 修复内容

部分对象保留原实体定义，但交互后会切换到实体 `SpriteConfig` 没有登记的合法状态贴图。区块加载时，原版因此反复输出：

```text
Invalid SpriteConfig object!
```

本补丁只处理已经从源码和资源定义确认的映射：

- Open All Containers 金属柜台、大储物柜、小储物柜和木制抽屉的 `ct_oac_*` 开启贴图。
- 原版 `Wooden_Windows` 的开启、破损和拆除玻璃贴图。
- Lifestyle 发明工作台 `LS_Inventions_10/11` 状态贴图。

## 原理

补丁在 `SpriteConfigManager` 的查表入口和 `TileInfo.verifyObject()` 中，将上述状态贴图临时规范化为对应原贴图后执行原版逻辑。世界对象仍保留真实显示贴图；实体组件、朝向、多格关系和原版失败清理流程均不被跳过。

它不会修改实体脚本、不会写入或迁移存档、不会删除建筑、不会扫描地图、不会注册 Tick，也不会抑制未知的 `Invalid SpriteConfig`。不在精确白名单中的对象完全按原版处理。

## 与旧补丁区别

不要同时启用旧的 `PZSpriteConfigGuard-agent.jar`。旧补丁会缓存失败组合并跳过后续初始化；本补丁不跳过初始化，只修正已确认的合法状态贴图查表。

## 参数

```text
-javaagent:server-patches/PZSpriteConfigAliasPatch-agent.jar=enabled=true
```

完整重启后应出现三个 `ACTIVE` 类和：

```text
[PZSpriteAlias] agent installed aliases=24
```

停用时移除该启动参数并重启。启用和停用都不会改变存档格式。
