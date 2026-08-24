# 当前常驻 Java Agent

本目录公开 Web 面板当前管理、且三个生产服务器实际常驻的 Java Agent。每项包含：

- 可审计的 Java 源码与测试源码
- `META-INF/MANIFEST.MF`
- PowerShell 构建脚本
- ASM 9.8 构建依赖
- 与当前服务器部署文件一致的成品 JAR

| Agent | 作用 |
| --- | --- |
| `OrangeAntiCheat` | 在服务端入口鉴权危险客户端命令，并持久记录可疑请求 |
| `PZServerStreamingStability` | 丢弃确定失效的 ObjectModData，并有界排队未加载方格同步 |
| `PZGlassRemovalGuard` | 避免移除玻璃附件时对象列表不收敛造成主线程死循环 |
| `PZItemContainerCycleGuard` | 阻断物品或尸体容器所有者链的自身回指与循环递归 |
| `PZEntityRegistrationGuard` | 忽略同一实体、状态一致的幂等重复注册 |
| `PZItemPickInfoContainerFix` | 在掉落桶构建前注册 `inventorymale` 与 `inventoryfemale` |
| `PZSelectiveWorldResetGuard` | 阻止已重置区块重新生成原版车辆，并按需重建对应 IsoRegion 缓存 |
| `PZTimedActionIsolationFix` | 按玩家动作实例停止联机读条，避免动作编号撞号互相取消 |
| `PZSpriteConfigAliasPatch` | 将已确认的合法动态贴图映射回实体定义后执行原版初始化 |

## 构建

需要 Project Zomboid Build 42 服务端和 JDK 25。以其中一个补丁为例：

```powershell
$env:JAVA_HOME = 'C:\Program Files\Microsoft\jdk-25'
& .\patches\PZTimedActionIsolationFix\build.ps1 -ServerRoot 'D:\PZ Dedicated Server'
```

构建脚本会编译源码、运行该补丁自带测试，并把输出写入补丁目录下的 `build/`。该目录
不会进入 Git。仓库根目录的成品 JAR 是已经部署验证的版本，哈希见
[`checksums.sha256`](checksums.sha256)。

## 加载

JAR 应放入 PZ 服务端运行目录的 `server-patches/`，并在 `zombie.network.GameServer`
之前加入：

```text
-javaagent:server-patches/补丁文件名.jar
```

`PZServerStreamingStability` 与 `PZSpriteConfigAliasPatch` 还带参数，具体值和兼容边界请阅读
各补丁自己的中文说明。Web 面板的“Java 补丁”页使用严格白名单管理这些参数，不热挂载，
修改后必须完整重启对应游戏服务器。

这些 Agent 都采用已审核类哈希或窄范围入口修改。游戏更新后不能把“JAR 已加载”等同于
“字节码已验证”；应同时检查面板的进程挂载证据和 `ACTIVE`/拒绝注入日志。
