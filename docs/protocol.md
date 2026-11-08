# Claude Remote 协议 v1

> 传输：局域网 WSS（自签证书 + 指纹固定）。所有消息是单行 JSON，一个 WS frame 一条消息。
> 版本：`v: 1`。服务端与客户端都必须忽略未知字段、忽略未知 `type` 并计数。

## 1. 信封

```jsonc
{
  "v": 1,
  "id": "5f0c…",            // 消息 UUID，用于日志与去重
  "type": "prompt.send",
  "ts": 1760000000000,      // Unix ms
  "bootId": "9a31…",        // daemon 每次启动生成
  "eventId": 42,            // 仅持久事件；由 SQLite AUTOINCREMENT 分配
  "sessionId": "b1e2…",     // 会话相关消息必填
  "payload": { }
}
```

- 客户端消息带 `clientMsgId`（在 payload 内）做幂等去重。
- 持久事件写 SQLite；瞬时事件（delta、快照、心跳）不写库、无 `eventId`。
- 时间戳只用于展示，排序以 `eventId` 为准。

## 2. 连接生命周期

```
client                                  daemon
  │ ── client.hello {deviceId, token} ──▶ │  5 秒内必须发送
  │ ◀──────── server.hello ───────────── │  bootId/minEventId/maxEventId
  │ ── sync.request {lastEventId} ──────▶ │
  │ ◀── sync.replay / sync.snapshot ───── │  按 lastEventId 选择补发或快照
  │ ◀──────── sync.complete ───────────── │  此后进入实时流
  │ ◀──────── status / events ─────────── │
```

- 连接后 5 秒未认证 → 关闭 4401。
- 同一设备重连：旧连接以 4409 关闭（被新连接取代），新连接继续。
- 心跳：客户端每 15 秒 `ping`，服务端回 `pong`；服务端 45 秒无消息也发 ping。

## 3. 客户端 → 服务端

### `client.hello`

```json
{
  "v": 1, "type": "client.hello", "id": "…", "ts": 0,
  "payload": {
    "protocolVersion": 1,
    "deviceId": "dev_…",
    "token": "…",
    "capabilities": ["attachments", "questions", "interrupt"]
  }
}
```

### `sync.request`

```json
{ "v": 1, "type": "sync.request", "id": "…", "ts": 0,
  "payload": { "lastEventId": 1240 } }
```

### `session.create`

```json
{ "v": 1, "type": "session.create", "id": "…", "ts": 0,
  "payload": { "cwd": "~/code/login-service", "title": "修复登录超时", "permissionMode": "default" } }
```

### `session.resume` / `session.close`

```json
{ "v": 1, "type": "session.resume", "id": "…", "ts": 0,
  "payload": { "sessionId": "b1e2…" } }
```

### `session.setPermissionMode`

```json
{ "v": 1, "type": "session.setPermissionMode", "id": "…", "ts": 0, "sessionId": "b1e2…",
  "payload": { "sessionId": "b1e2…", "mode": "plan" } }
```

`mode` 取值与语义：

| 值 | 行为 |
|---|---|
| `default` | 危险操作逐次询问（手机权限卡） |
| `plan` | 只读调研，不执行有副作用的工具 |
| `acceptEdits` | 自动批准 Edit / Write，其他工具仍询问 |
| `auto` | 模型分类器逐次判定，拿不准时走 `canUseTool` |
| `bypassPermissions` | 跳过所有权限检查；需要 daemon 允许（`allowDangerousModes`） |

- `dontAsk` 不在协议内（它会静默拒绝未预先批准的调用）。
- 冷会话也可以设置，模式在下次 spawn 时生效。
- daemon 会把 CLI 上报的模式变化（如批准 `ExitPlanMode` 后）写回会话并广播 `session.updated`。

### `prompt.send`

```json
{ "v": 1, "type": "prompt.send", "id": "…", "ts": 0, "sessionId": "b1e2…",
  "payload": {
    "clientMsgId": "c_…",
    "text": "登录接口在并发 50 的时候会超时，先跑一下测试看看。",
    "attachments": [{ "id": "att_…", "name": "error.png", "mime": "image/png", "size": 38210 }]
  } }
```

### `run.interrupt`

```json
{ "v": 1, "type": "run.interrupt", "id": "…", "ts": 0,
  "payload": { "sessionId": "b1e2…" } }
```

### `permission.respond`

```json
{ "v": 1, "type": "permission.respond", "id": "…", "ts": 0, "bootId": "9a31…",
  "payload": {
    "permissionId": "perm_…",
    "requestId": "sdk_req_…",
    "decision": "allow_once",
    "message": null
  } }
```

`decision` 取值：`allow_once | allow_session | deny | deny_stop`。

### `question.respond`

```json
{ "v": 1, "type": "question.respond", "id": "…", "ts": 0, "bootId": "9a31…",
  "payload": {
    "permissionId": "perm_…",
    "answers": { "税率默认值放在哪里？": "环境变量 TAX_RATE" }
  } }
```

### `ping`

```json
{ "v": 1, "type": "ping", "id": "…", "ts": 0, "payload": { "nonce": "n_…" } }
```

### 设备管理

```json
{ "v": 1, "type": "devices.list", "id": "…", "ts": 0, "payload": {} }
```

```json
{ "v": 1, "type": "device.revoke", "id": "…", "ts": 0,
  "payload": { "deviceId": "dev_…" } }
```

```json
{ "v": 1, "type": "device.rotateToken", "id": "…", "ts": 0,
  "payload": { "deviceId": "dev_…" } }
```

- `devices.list` 的响应是服务端发出的同类型 `devices.list`（见第 4 节「设备管理响应」）。
- `device.rotateToken`：轮换本机时响应里带新 token；轮换其他设备时 `requiresRepair: true`，该设备连接会以 4401 关闭，需要重新配对。
- 撤销设备后，该设备连接以 4401 关闭。

## 4. 服务端 → 客户端

### `server.hello`

```json
{ "v": 1, "type": "server.hello", "id": "…", "ts": 0, "bootId": "9a31…",
  "payload": {
    "protocolVersion": 1,
    "serverVersion": "0.1.0",
    "serverName": "my-desktop",
    "allowedRoots": ["/home/you/code"],
    "maxTurns": 40,
    "maxBudgetUsd": 5,
    "minEventId": 1,
    "maxEventId": 1240,
    "capabilities": ["attachments", "questions", "interrupt", "snapshot", "devices"]
  } }
```

### `sync.replay` / `sync.snapshot` / `sync.complete`

```json
{ "v": 1, "type": "sync.replay", "id": "…", "ts": 0,
  "payload": { "events": [ … ], "nextEventId": 300, "hasMore": true } }
```

```json
{ "v": 1, "type": "sync.snapshot", "id": "…", "ts": 0,
  "payload": {
    "lastEventId": 1240,
    "sessions": [ … ],
    "messages": [ … ],
    "runs": [ … ],
    "pendingPermissions": [ … ]
  } }
```

### 会话事件

```json
{ "v": 1, "type": "session.created", "id": "…", "ts": 0, "eventId": 1241,
  "payload": { "session": { "id": "b1e2…", "title": "修复登录超时", "cwd": "~/code/login-service",
    "permissionMode": "default", "status": "idle", "createdAt": 0, "lastActiveAt": 0 } } }
```

`session.updated` / `session.closed` 同结构。

### `user.message`

```json
{ "v": 1, "type": "user.message", "id": "…", "ts": 0, "eventId": 1242, "sessionId": "b1e2…",
  "payload": { "runId": "run_…", "clientMsgId": "c_…", "text": "…", "attachments": [] } }
```

### `run.started` / `run.result` / `run.interrupted`

```json
{ "v": 1, "type": "run.started", "id": "…", "ts": 0, "eventId": 1242, "sessionId": "b1e2…",
  "payload": { "runId": "run_…", "clientMsgId": "c_…", "userMessageUuid": "u_…" } }
```

```json
{ "v": 1, "type": "run.result", "id": "…", "ts": 0, "eventId": 1300, "sessionId": "b1e2…",
  "payload": {
    "runId": "run_…",
    "subtype": "success",
    "result": "已把连接池从 5 调到 20…",
    "totalCostUsd": 0.42,
    "usage": { "input_tokens": 18200, "output_tokens": 20000 },
    "modelUsage": { "deepseek-flash[1M]": { "costUSD": 0.42 } },
    "numTurns": 3,
    "durationMs": 48210,
    "isError": false,
    "permissionDenials": [],
    "terminalReason": "completed"
  } }
```

### `message.started` / `message.delta` / `message.completed` / `message.snapshot`

```json
{ "v": 1, "type": "message.delta", "id": "…", "ts": 0, "sessionId": "b1e2…",
  "payload": { "runId": "run_…", "msgId": "m_…", "blockIndex": 0, "text": "我先看一下" } }
```

- `message.delta` 是瞬时事件，无 `eventId`，不落库。
- `message.completed` 是权威内容，带 `eventId`，客户端按 `msgId` 替换流式缓冲。
- `message.snapshot` 是重连时的当前 run 文本快照，无 `eventId`。

```json
{ "v": 1, "type": "message.completed", "id": "…", "ts": 0, "eventId": 1245, "sessionId": "b1e2…",
  "payload": { "runId": "run_…", "msgId": "m_…", "blocks": [ { "type": "text", "text": "…" } ] } }
```

### `tool.use` / `tool.result` / `tool.progress`

```json
{ "v": 1, "type": "tool.use", "id": "…", "ts": 0, "eventId": 1246, "sessionId": "b1e2…",
  "payload": { "runId": "run_…", "toolUseId": "tu_…", "name": "Bash",
    "input": { "command": "npm test -- --runInBand login" }, "parentToolUseId": null } }
```

工具调用没有独立的 SDK 消息，由 daemon 从 assistant 的 `tool_use` 块和 user 的 `tool_result` 块解析后发出。

### `permission.request` / `permission.resolved`

```json
{ "v": 1, "type": "permission.request", "id": "…", "ts": 0, "eventId": 1250, "sessionId": "b1e2…",
  "payload": {
    "permissionId": "perm_…",
    "sessionId": "b1e2…",
    "requestId": "sdk_req_…",
    "toolUseID": "tu_…",
    "toolName": "Edit",
    "input": { "file_path": "src/db/pool.ts", "old_string": "max: 5", "new_string": "max: 20" },
    "title": "修改 src/db/pool.ts",
    "displayName": "Edit",
    "description": "把连接池上限从 5 调到 20",
    "decisionReason": "Claude 需要修改连接池配置",
    "blockedPath": null,
    "defaultToNo": false,
    "suppressAlwaysAllowRule": false,
    "agentID": null,
    "expiresAt": 1760000300000
  } }
```

```json
{ "v": 1, "type": "permission.resolved", "id": "…", "ts": 0, "eventId": 1251, "sessionId": "b1e2…",
  "payload": { "permissionId": "perm_…", "decision": "allow_once",
    "source": "phone", "decidedBy": { "id": "dev_…", "name": "Pixel 8" } } }
```

`source`：`phone | timeout | disconnect | daemon_restart | interrupt`。
`decidedBy` 是作出决定的设备，非手机决策（超时/断线等）时为 `null`；多台设备同时在线时，其余设备据此提示「已由 X 处理」。

### `question.request` / `question.resolved`

```json
{ "v": 1, "type": "question.request", "id": "…", "ts": 0, "eventId": 1260, "sessionId": "b1e2…",
  "payload": {
    "permissionId": "perm_…",
    "sessionId": "b1e2…",
    "questions": [ { "question": "税率默认值放在哪里？", "header": "默认值",
      "multiSelect": false,
      "options": [ { "label": "环境变量 TAX_RATE", "description": "部署时可调" },
                   { "label": "billing.config.ts", "description": "跟代码一起评审" } ] } ]
  } }
```

```json
{ "v": 1, "type": "question.resolved", "id": "…", "ts": 0, "eventId": 1261, "sessionId": "b1e2…",
  "payload": { "permissionId": "perm_…",
    "decidedBy": { "id": "dev_…", "name": "Pixel 8" } } }
```

`decidedBy` 语义与 `permission.resolved` 相同。

### `devices.list`（响应）/ `device.revoked` / `device.tokenRotated`

```json
{ "v": 1, "type": "devices.list", "id": "…", "ts": 0,
  "payload": { "devices": [
    { "id": "dev_…", "name": "Pixel 8", "createdAt": 0, "lastSeenAt": 0, "current": true },
    { "id": "dev_…", "name": "e2e-cli", "createdAt": 0, "lastSeenAt": null, "current": false }
  ] } }
```

```json
{ "v": 1, "type": "device.revoked", "id": "…", "ts": 0,
  "payload": { "deviceId": "dev_…" } }
```

```json
{ "v": 1, "type": "device.tokenRotated", "id": "…", "ts": 0,
  "payload": { "deviceId": "dev_…", "token": "…", "requiresRepair": false } }
```

- `devices.list` 响应不带 `eventId`（即时查询，不落库）；`current` 标记发起请求的这台设备。
- `device.tokenRotated.token` 只在轮换本机时有值，其他设备为 `null` 且 `requiresRepair: true`。

### `status` / `command.ack` / `error` / `pong`

```json
{ "v": 1, "type": "status", "id": "…", "ts": 0, "sessionId": "b1e2…",
  "payload": { "state": "running", "permissionMode": "default", "compacting": false } }
```

```json
{ "v": 1, "type": "command.ack", "id": "…", "ts": 0,
  "payload": { "clientMsgId": "c_…", "accepted": true, "runId": "run_…" } }
```

```json
{ "v": 1, "type": "error", "id": "…", "ts": 0,
  "payload": { "code": "CWD_NOT_ALLOWED", "message": "该目录不在 allowedRoots 内", "recoverable": false } }
```

## 5. 事件与重连

- 持久事件：`session.*`、`run.*`、`message.completed`、`tool.*`、`permission.*`、`question.*`。
- 瞬时事件：`message.delta`、`message.snapshot`、`status`、`pong`。
- 客户端保存 `lastEventId`。重连：
  1. `server.hello` 给出 `minEventId` / `maxEventId`。
  2. `lastEventId < minEventId` → 服务端发 `sync.snapshot`。
  3. 否则 `sync.replay` 分页补发（`hasMore` / `nextEventId`）。
  4. `sync.complete` 后进入实时流。
- 服务端先注册实时订阅并缓冲，再读 DB replay，最后按 `eventId` 去重 flush。
- 快照的保留策略按时间/大小（默认 7 天或 200 MB），裁剪时更新 `minEventId`。

## 6. 会话与 run 状态机

```
session: idle → running → waiting_permission → running → idle | closed
run:     queued → starting → running → waiting_permission → running
                → completed | failed | interrupted
```

- 一个会话同一时刻只有一个 run；新 `prompt.send` 在 run 未结束时排队。
- 一个 turn 可能产生多个 `result`（后台任务完成等）；以 `terminalReason` / `queuedTurnCount` 判断真正结束。
- daemon 重启后 `resume` 只恢复对话历史，不自动重跑被中断的 turn。

## 7. 关闭码与错误码

| 关闭码 | 含义 |
|---|---|
| 4401 | 认证失败 / 超时未认证 |
| 4409 | 被同一设备的新连接取代 |
| 1013 | 服务端繁忙，稍后重试 |
| 4400 | 协议错误 |

| 错误码 | 含义 |
|---|---|
| `AUTH_REQUIRED` | 未认证 |
| `AUTH_FAILED` | token 无效 |
| `RATE_LIMITED` | 尝试过于频繁 |
| `SESSION_NOT_FOUND` | 会话不存在 |
| `DEVICE_NOT_FOUND` | 设备不存在 |
| `MODE_NOT_ALLOWED` | daemon 配置禁用了该权限模式（目前仅 `bypassPermissions`） |
| `CWD_NOT_ALLOWED` | 工作目录不在白名单 |
| `SESSION_BUSY` | 会话正忙且拒绝排队 |
| `LIVE_LIMIT` | 超过活跃子进程上限 |
| `SDK_ERROR` | Agent SDK / CLI 返回错误 |
| `PROTOCOL_ERROR` | JSON 或字段校验失败 |
| `INTERNAL` | 未分类内部错误 |

## 8. HTTP 端点

| 方法 | 路径 | 鉴权 | 说明 |
|---|---|---|---|
| GET | `/health` | 无 | `{ ok, serverVersion, protocolVersion, bootId }` |
| POST | `/pair` | 一次性配对码 | body `{ code, deviceName }` → `{ deviceId, token, serverName, protocolVersion }` |
| POST | `/attachments` | `Authorization: Bearer <deviceToken>` | 原始字节流；`X-File-Name` 文件名，`Content-Type` MIME；返回 `{ id, name, mime, size }` |

- `/pair` 与 `/attachments` 都要求私有网段来源，并走 WSS 同一张自签证书。
- 设备 token 只在配对响应里出现一次；服务端只存 SHA-256 哈希。

## 9. 配对二维码

```json
{
  "v": 1,
  "url": "wss://192.168.1.23:8787/ws",
  "certSha256": "43654030…",
  "code": "7F3K9Q2M",
  "expiresAt": 1760000000000,
  "name": "my-desktop"
}
```

- `code` 一次性、默认 5 分钟过期。
- `certSha256` 是自签证书 DER 的 SHA-256（小写十六进制，无冒号）。
- 手机用这张证书做 TLS pin，再 `POST /pair` 换取设备 token。

## 10. 版本策略

- `v` 为主版本；新增可选字段不升版本。
- 客户端与 daemon 在 `hello` 中交换 `protocolVersion`；不兼容时以 4400 关闭并提示升级。
