# PZAI Mod 操作执行器改写 SOP

## 目标与边界

Web 面板当前只读取 `agent.request`、调用模型并定向回复。AI 玩家授权已经可以在 Web 中配置，但执行器尚未接入。Mod 改写后的目标是提供结构化、可审计、默认拒绝的游戏操作通道，不允许模型直接提交控制台命令、Lua、RCON、Shell 或 PowerShell 文本。

Web 保存的授权必须按 `serverId + username + steamId` 三项完全匹配。Mod 端仍需做第二次身份、操作和参数校验，不能把 Web 允许视为最终成功。

## 1. 服务端认证身份

1. `actor.username` 和 `actor.steamId` 必须由 PZ 服务端已认证的连接对象生成。
2. 禁止采用客户端 Lua 请求中自报的用户名、SteamID、访问级别或管理员标记。
3. SteamID 必须是 17 位 SteamID64；拿不到认证 SteamID 时不得请求任何写操作。
4. 每个请求必须绑定当前 `serverId` 和 `sessionId`。旧会话、其他服务器或重放请求必须拒绝。

## 2. 结构化请求协议

Mod 向 Bridge 发出 `operation.requested`，建议结构如下：

```json
{
  "schema": "pzai.operation/1",
  "type": "operation.requested",
  "requestId": "全局唯一且不可重用",
  "serverId": "servertest",
  "sessionId": "当前服务端会话 ID",
  "timestampMs": 1785850875837,
  "actor": {
    "username": "AKI",
    "steamId": "76561198000000001"
  },
  "operation": "give_self_item",
  "parameters": {
    "itemId": "Base.WaterBottleFull",
    "count": 1
  }
}
```

要求：

1. `requestId` 必须唯一，并在服务端保存去重窗口，重复 ID 不得再次执行。
2. `operation` 只能是固定枚举，禁止传入原始命令字符串。
3. `parameters` 必须按操作分别定义类型、范围、长度和允许值；未知字段应拒绝。
4. 不允许模型控制目标服务器、目标身份、执行脚本路径或底层命令文本。

## 3. 第一阶段操作枚举

建议先开放低风险、容易验证的操作：

- `query_status`
- `query_players`
- `query_self`
- `send_private_notice`
- `unstuck_self`
- `give_self_item`
- `add_self_xp`

以下操作即使玩家被设为“完全信任”，首版也应要求 Web 管理员人工审批：

- `broadcast`
- `give_item`
- `teleport_player`
- `kick_player`
- `ban_player`
- `restart_server`
- `change_config`
- 世界生成、全服批量发放、权限和白名单变更

## 4. 双重授权流程

1. Mod 生成服务端认证身份和结构化请求。
2. Web 按 `serverId + username + steamId` 完全匹配已启用策略。
3. Web 判断 `trustedAll` 或 `allowedOperations`，并校验参数上限。
4. 高风险操作进入人工审批，不得自动执行。
5. Web 返回签名/随机令牌关联的批准结果，不返回任意底层命令文本。
6. Mod 再次检查身份、会话、请求 ID、操作枚举、参数范围和本地 allowlist。
7. Mod 使用固定实现执行，并读取游戏状态验证效果。

任何阶段拒绝时必须终止，禁止回退到 RCON、控制台、Lua 字符串执行或 Shell。

## 5. 结果与遥测事件

完整链路至少产生以下事件：

- `operation.requested`
- `operation.approved` 或 `operation.denied`
- `operation.executed`

`operation.denied` 应包含稳定的 `reasonCode`，例如 `identity-mismatch`、`not-allowed`、`approval-required`、`invalid-parameters`、`duplicate-request`、`session-expired`。

`operation.executed` 建议结构：

```json
{
  "schema": "pzai.operation/1",
  "type": "operation.executed",
  "requestId": "与请求一致",
  "serverId": "servertest",
  "sessionId": "当前会话",
  "status": "success",
  "verified": true,
  "resultCode": "item-added",
  "message": "物品已加入玩家背包"
}
```

只有 `status=success` 且 `verified=true` 才能在 Web 和 AI 回复中宣称成功。仅调用函数、写入队列或没有异常不等于验证成功。

## 6. 参数限制示例

- `give_self_item`：只允许管理员配置的物品 allowlist；数量建议 `1..10`；目标强制为 actor 本人。
- `add_self_xp`：技能使用固定枚举；单次经验和每日累计设置上限。
- `unstuck_self`：只能在安全条件下移动本人；限制距离、冷却时间，并避免跨地图/安全屋滥用。
- `send_private_notice`：目标强制为 actor；限制 UTF-8 字节数、频率和显示时长。
- `kick_player` / `ban_player`：目标由服务端在线目录解析；禁止作用于更高权限管理员；必须人工审批并记录原因。
- `restart_server` / `change_config`：Mod 不应直接执行，交由 Web 现有受控生命周期和配置模块完成。

## 7. 能力与心跳

在现有 Mod 心跳中增加：

```json
{
  "operationRequests": true,
  "operationExecutorInterface": true,
  "operationExecutorRegistered": true,
  "operationExecutionEnabled": true,
  "supportedOperations": ["query_self", "give_self_item"],
  "executorVersion": "1.0.0",
  "lastExecutorHeartbeatMs": 1785850875837,
  "executionDisabledReason": ""
}
```

Web 只有在会话、版本、支持操作和心跳都有效时才显示执行器在线。心跳短暂延迟应显示警告并停止接受新写操作，不应把已经执行的请求重放。

## 8. 验收清单

1. 伪造客户端用户名或 SteamID 无法越权。
2. 同名但 SteamID 不同、SteamID 相同但用户名不同、服务器不同均被拒绝。
3. 禁用策略、未勾选操作和未知操作均被拒绝。
4. 参数越界、未知字段、重复 requestId、旧 sessionId 均被拒绝。
5. 高风险操作必须经过 Web 人工审批。
6. Mod 重载、服务器重启和 Web 重启不会重复执行旧请求。
7. 每次请求、批准、拒绝、执行和验证结果都有遥测记录。
8. AI 只能根据 `operation.executed` 的已验证结果回复成功。
9. 执行器关闭或心跳失效时，普通聊天和只读 AI 问答仍可正常使用。
