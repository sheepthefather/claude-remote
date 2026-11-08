# Claude Remote 架构

> 在 Android 手机上远程操控运行在本机的 Claude Code CLI 会话。手机端是瘦客户端，真正的执行者是电脑上的 daemon。
>
> 状态：M1 核心已完成，并在 Android 模拟器上端到端验证。UI 方向已通过 `ui-prototype.html` 确认。

## 1. 目标与非目标

**目标**

- 手机上看 Claude 的流式输出、发指令、中断任务。
- 权限确认（Allow once / Allow session / Deny / Deny + stop）在手机上完成，且 fail-closed。
- 手机断网、切后台不影响电脑上的任务；重连后补齐事件。
- 多会话：逻辑上可以有很多，活跃子进程受内存限制。
- 局域网内自托管，transcript 不出本机。
- 支持图片 / PDF / 任意文件作为输入。

**非目标**

- 不做 SSH 终端模拟器，不解析 TUI 的 ANSI 输出。
- 不重写官方 Remote Control 协议（未公开）。
- 不提供 `bypassPermissions`。
- 第一版不做公网访问、FCM 推送、多用户。

## 2. 总体架构

```
┌────────────────────────── 手机 (Flutter Android) ──────────────────────────┐
│ 主页(工作收件箱) / 左侧会话抽屉 / 全屏聊天 / 权限确认弹层                   │
│ Riverpod 状态机  →  WsClient(鉴权/心跳/重连)  →  sqflite(SQLite 持久事件)   │
│ 前台服务 + 本地通知（等待确认 / 任务完成）                                  │
└───────────────────────────────┬────────────────────────────────────────────┘
              LAN / WSS（自签证书 SHA-256 指纹固定 + 设备 token）
┌───────────────────────────────┴────────────────────────────────────────────┐
│ 桌面端 daemon (Node 24 + TypeScript, ESM)                                  │
│  HTTP: /pair /attachments      WS: /ws（首条消息鉴权 → 协议分发）           │
│  SessionManager：逻辑会话(SQLite) + 活跃会话(≤3 个 CLI 子进程)              │
│  PermissionBridge（canUseTool ↔ 手机，永不返回 null）                       │
│  EventStore(全局 event_id + 快照)   AuditLog   Config                       │
│  systemd user service: claude-remote.service                               │
└───────────────────────────────┬────────────────────────────────────────────┘
                                │ @anthropic-ai/claude-agent-sdk@0.3.319
                Claude Code CLI（沿用本机 ANTHROPIC_* 环境变量）
```

## 3. 组件职责

### 3.1 daemon（`daemon/`）

- **唯一**与 Claude 交互的进程；手机不直接接触 CLI。
- 每个活跃会话 = 一个常驻 `query()` + 一个 CLI 子进程。
- 输入用 `AsyncIterable<SDKUserMessage>` 持续喂入；`interrupt()` 只在流式输入模式可用。
- 输出事件写入 SQLite（全局单调 `event_id`），供手机重连补齐。
- `canUseTool` 回调挂起等待手机决策；所有异常路径都 resolve 为 deny。
- 进程由 systemd 托管，`KillMode=control-group` 防止 CLI 孤儿进程。

### 3.2 手机端（`app/`）

- Flutter + Riverpod；聊天页是主界面，会话在左侧抽屉。
- WSS + 自签证书指纹固定；设备 token 存 Android Keystore。
- sqflite 只存持久事件和 `lastEventId`；delta 不落库。
- 主页 / 会话抽屉 / 聊天页 / 权限与选择题弹层 / 设置页，状态由 Riverpod 管理。
- 主页与会话是同一个 `Scaffold` 的两种状态：标题栏始终是「☰ + 标题 + 操作」，不再有返回箭头；硬件返回键在会话内回到主页。主页和聊天共用同一个 `Composer` 组件。
- 前台服务（`dataSync`）+ 本地通知：连接期间保持进程，后台收到权限/问题时弹高优先级通知；受 Android 15 每 24 小时 6 小时限制。
- 附件：相机 / 相册 / 文件 → `POST /attachments` → daemon 组装 image / document content block。
- 设备管理：设备列表、撤销、token 轮换；多设备同时在线，权限由最先响应者决定。

### 3.3 传输与安全

- 仅监听局域网地址，拒绝非私有源 IP。
- 首次配对：终端打印二维码 `{ url, certSha256, pairingCode }`；一次性配对码换 `deviceId + deviceToken`；服务端只存 token 哈希。
- WSS 使用自签证书；手机用 `SecurityContext(withTrustedRoots: false)` + 证书 DER SHA-256 固定。
- WS 首条消息 `client.hello` 带 token；5 秒内未认证断开。
- token 可轮换、设备可撤销；审计日志不可关闭。

## 4. 关键数据模型

```ts
type LogicalSession = {
  id: string;                 // daemon 生成的 UUID
  title: string;
  cwd: string;                // 必须在 allowedRoots 内
  permissionMode: 'default' | 'plan';
  sdkSessionId?: string;      // Claude 的 session_id，用于 resume
  status: 'idle' | 'running' | 'waiting_permission' | 'closed';
  createdAt: number;
  lastActiveAt: number;
};

type LiveSession = {
  logicalId: string;
  query: Query;               // Agent SDK 的常驻 query
  childPid?: number;
  inputQueue: AsyncQueue<SDKUserMessage>;
  pendingPermissions: Map<string, PendingPermission>;
};
```

- 逻辑会话可以很多；活跃会话默认上限 3，空闲 10–20 分钟回收，之后 `resume` 恢复。
- 每个会话同一时刻一个 run；新消息排队。

## 5. 协议

完整定义见 `docs/protocol.md`。要点：

- 信封：`{ v: 1, type, id, ts, bootId, eventId? }`。
- 连接：`client.hello` → `server.hello` → `sync.request` → `sync.replay` / `sync.snapshot` → `sync.complete`。
- 业务：`prompt.send`、`run.*`、`message.*`、`tool.*`、`permission.*`、`question.*`、`status`。
- 设备：`devices.list`、`device.revoke`、`device.rotateToken`；`permission.resolved` 带 `decidedBy`。
- 错误码与关闭码：4401 认证失败、4409 被取代、1013 稍后重试。
- 权限响应必须带 `permissionId + bootId + requestId`，防止跨重启/跨会话误批。

## 6. 权限模型（安全边界）

1. SDK 先执行 hooks / deny 规则 / ask 规则 / permission mode / allow 规则，**只有需要 ask 的调用才会进 `canUseTool`**。
2. daemon 推送 `permission.request`，挂起 Promise，等手机 `permission.respond`。
3. 决策：
   - `allow_once` → `{ behavior: 'allow', updatedInput }`
   - `allow_session` → 只回传 `addRules` + `destination === 'session'` 的 suggestions
   - `deny` / `deny_stop` → `{ behavior: 'deny', message, interrupt? }`
4. 超时（默认 5 分钟）、`signal` abort、中断、SIGTERM、daemon 重启全部 deny；永不返回 `null`。
5. `AskUserQuestion` 走同一回调，手机返回 `updatedInput: { questions, answers }`。
6. 自动放行的调用用 `PreToolUse` hook 记录并在 UI 标注，不承诺“所有操作都要手机批准”。
7. 多设备：多个客户端可同时连接；权限/问题由最先响应者决定，`permission.resolved` / `question.resolved` 带 `decidedBy {id,name}`，其他设备关闭弹层并提示“已由 X 处理”。

**权限模式（按会话）**

| 模式 | 行为 | 安全边界 |
|---|---|---|
| `default` | 危险操作逐次推到手机 | 手机权限卡 |
| `plan` | 只读调研，计划批准后才执行 | 手机批准 `ExitPlanMode` |
| `acceptEdits` | 自动批准 Edit/Write，Bash 等仍询问 | 手机权限卡（部分） |
| `auto` | 模型分类器判定，不确定时询问 | 手机权限卡（兜底） |
| `bypassPermissions` | 全部跳过，手机不再弹卡 | 仅 daemon 配置 + App 二次确认 |

- `bypassPermissions` 需要 SDK 的 `allowDangerouslySkipPermissions`，daemon 在创建 query 时打开；是否允许由 `allowDangerousModes`（默认 true）控制，禁用时返回 `MODE_NOT_ALLOWED`。
- App 每次切到 Bypass 都弹确认框，会话内显示红色横幅，主页模式胶囊标红。
- 不提供 `dontAsk`（未预先批准的调用会被静默拒绝，手机上只会看到失败）。
- daemon 会把 CLI 上报的模式变化写回会话记录并广播 `session.updated`，避免批准计划后 UI 仍显示 Plan。

## 7. 断线与恢复

- 持久事件写 SQLite，`event_id` 全局单调；`message.delta` 只放内存。
- 运行中的部分文本每 1 秒或每 4 KB 更新快照；重连先发快照再续流。
- 先注册实时订阅并缓冲，再读 DB replay，最后按 `event_id` 去重 flush。
- 手机重连退避 1s→30s，只在认证成功后重置。
- daemon 重启：对话历史可 resume；**被中断的 turn 不自动重跑**，标记 interrupted，由用户确认。

## 8. 目录结构

```
Claude_Remote/
├── ARCHITECTURE.md
├── docs/protocol.md
├── ui-prototype.html          # 已确认的 UI 原型
├── README.md
├── deploy/claude-remote.service   # systemd 用户服务示例
├── daemon/
│   ├── package.json / tsconfig.json
│   ├── scripts/{smoke,e2e}.ts # SDK 冒烟与协议端到端脚本
│   └── src/
│       ├── index.ts           # CLI：serve / list-devices / revoke-device / rotate-device-token
│       ├── config.ts
│       ├── server.ts          # HTTP + WS + 鉴权 + 私有网段校验 + 配对 + 附件
│       ├── protocol/messages.ts
│       ├── security/{tls,pairing}.ts
│       ├── session/{manager,session,sdk-adapter,permissions}.ts
│       ├── store/event-store.ts
│       └── util/{logger,async-queue,files}.ts
└── app/
    ├── test/format_test.dart
    └── lib/
        ├── main.dart / app.dart
        ├── core/{models,pairing_service,remote_connection,database,security,storage,
        │         attachment_service,notifications}.dart
        ├── state/{app_controller,app_state}.dart
        └── ui/{pairing_page,home_shell,home_view,chat_view,permission_sheet,
                question_sheet,settings_page,new_session_dialog,theme,format,widgets}.dart
```

## 9. 运行方式

```bash
# daemon
cd daemon
npm install
npm run build
node dist/index.js serve   # 首次启动会生成自签证书并打印配对二维码
# 配对码过期后重新打印：kill -USR1 <daemon pid>

# app
cd app
flutter pub get
flutter build apk --debug
adb install -r build/app/outputs/flutter-apk/app-debug.apk
```

模拟器开发可以用 `--dart-define=CR_SERVER_URL=wss://10.0.2.2:8787/ws`
`--dart-define=CR_CERT_FP=... --dart-define=CR_PAIRING_CODE=...` 在首次启动时自动配对。
认证沿用 `ANTHROPIC_BASE_URL` / `ANTHROPIC_AUTH_TOKEN` / `ANTHROPIC_MODEL`，systemd 部署时通过
`EnvironmentFile` 注入，不下发手机。`allowDangerousModes`（默认 `true`）控制是否允许会话切到
`bypassPermissions`。

认证沿用本机环境变量（`ANTHROPIC_BASE_URL` / `ANTHROPIC_AUTH_TOKEN` / `ANTHROPIC_MODEL`），daemon 通过 `EnvironmentFile` 加载，不下发手机。

## 10. 已知限制与风险

- Android 15 `dataSync` 前台服务 6 小时/24 小时上限；不承诺永久在线。
- Agent SDK 0.3.x 迭代快，所有调用收口在 `sdk-adapter.ts`。
- 第三方 Anthropic 兼容网关可能对部分控制协议支持不全，M1 必须先验证。
- 每活跃会话约 1 GiB RAM；逻辑会话多、活跃子进程少。
- 局域网限制：出门不可用；后续接 Tailscale 只换传输层，仍保留 token 与证书 pin。

## 11. 实现状态（2026-11-08）

**已实现并验证**

- daemon：配对、WSS 鉴权、自签证书、私有网段校验、会话创建/恢复、常驻 SDK query、流式 delta、工具卡片、权限桥（允许一次 / 本会话总是允许 / 拒绝 / 拒绝并停止）、超时拒绝、事件 SQLite、全局 event_id、sync replay/snapshot、附件 HTTP、设备管理 CLI。
- app：配对页（手动 + 扫码）、自动重连、主页工作收件箱、会话抽屉（搜索 / 筛选）、聊天页（Markdown、工具卡片、停止按钮）、权限弹层（倒计时 / 写入预览 / 四档决策）、AskUserQuestion 弹层、设置页（权限模式 / 主题 / 断开）、sqflite 缓存、清除数据后重新配对并从 daemon 快照恢复。
- 附件：相机拍照 → 上传 → image content block → Claude 描述图片，已验证。
- 前台服务 + 本地通知：连接期间常驻，后台权限请求发高优先级通知，已验证。
- 多设备：第二客户端挂起 Write 权限，App 后台收通知、回前台弹出权限卡、批准后第二客户端收到 resolved 并完成，已验证。
- 设备管理：设备列表、撤销、本机 token 轮换后自动重连，已验证。
- 费用/限制：聊天底部显示累计费用 / tokens / 轮数；设置页显示预算与最大轮数，已验证。
- 权限模式：Manual / Plan / Accept Edits / Auto / Bypass 五种，可在新建会话时选择、在设置页按会话切换；Bypass 需二次确认并显示红色横幅，已验证（e2e：acceptEdits / auto / bypass 均无权限卡执行 Write，plan 批准计划后切回 default）。
- 端到端实测：配对 → WSS → 新建会话 → 发消息 → 流式 → Write 工具触发权限卡 → 允许一次 → 文件实际写入 → 工具结果与最终回复。
- 单测：daemon 14 个通过；Flutter 3 个通过；`flutter analyze` 仅剩 2 条 info 级 lint。

**待完成**

- 不同 OEM 真机的后台存活与锁屏通知点击深链（当前点击通知打开 App，权限弹层在恢复后自动出现，未按会话深链）。
- `interrupt`、`AskUserQuestion` 的真机实测（协议和 UI 已完成）。
- systemd unit 已提供（`deploy/claude-remote.service`），未在本机实际 enable；当前以 `node dist/index.js serve` 直接运行。
- 发布签名、iOS 客户端、Tailscale / 公网传输层。
- Android 15 `dataSync` 每 24 小时最多 6 小时，长时间后台需重新打开 App 或改用 `specialUse`。
