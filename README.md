# Claude Remote

在 Android 手机上远程操控运行在电脑上的 Claude Code CLI：看流式输出、发指令、批准权限、中断任务、切换会话。

- 桌面端：Node 24 + TypeScript daemon，使用 Claude Agent SDK 驱动本机 Claude Code 子进程。
- 手机端：Flutter Android App，局域网 WSS + 自签证书指纹固定 + 一次性配对码。
- 数据：daemon 用 SQLite 保存会话与事件；手机端用 sqflite 缓存，断线后按事件 ID 补齐或走快照。

完整设计见 [ARCHITECTURE.md](ARCHITECTURE.md)，协议见 [docs/protocol.md](docs/protocol.md)，可交互 UI 原型是 [ui-prototype.html](ui-prototype.html)。

## 快速开始

### 1. 启动 daemon

```bash
cd daemon
npm install
npm run build
node dist/index.js serve
```

首次启动会：

1. 生成自签 TLS 证书（`~/.config/claude-remote/tls/`）。
2. 在 `~/.local/share/claude-remote/` 创建 SQLite 和附件目录。
3. 在终端打印 WSS 地址、证书 SHA-256、一次性配对码和二维码。

认证沿用当前 shell 的 `ANTHROPIC_*` 环境变量（`ANTHROPIC_BASE_URL`、`ANTHROPIC_AUTH_TOKEN`、`ANTHROPIC_MODEL` 等），daemon 会原样传给 Claude Code 子进程。

常用参数（写在 `~/.config/claude-remote/config.json`）：

```json
{
  "host": "0.0.0.0",
  "port": 8787,
  "allowedRoots": ["/home/you/code"],
  "maxLiveSessions": 3,
  "permissionTimeoutMs": 300000,
  "allowDangerousModes": true
}
```

`allowDangerousModes` 默认 `true`；设为 `false` 后 App 无法把会话切到 Bypass 模式（daemon 返回 `MODE_NOT_ALLOWED`）。

配对码过期后，向 daemon 发送 `SIGUSR1` 会重新打印二维码：

```bash
kill -USR1 $(pgrep -f "node dist/index.js serve" | tail -1)
```

### 2. 安装手机端

```bash
cd app
flutter pub get
flutter build apk --debug
adb install -r build/app/outputs/flutter-apk/app-debug.apk
```

首次打开进入配对页：扫描电脑终端里的二维码，或手动填写 WSS 地址、证书指纹和配对码。

**模拟器开发**（模拟器通过 `10.0.2.2` 访问宿主机）：

```bash
flutter build apk --debug \
  --dart-define=CR_SERVER_URL=wss://10.0.2.2:8787/ws \
  --dart-define=CR_CERT_FP=<daemon 打印的 64 位指纹> \
  --dart-define=CR_PAIRING_CODE=<一次性配对码>
```

这三个 define 只用于开发构建：首次启动会自动配对，之后使用已保存的设备 token。

## 当前功能

- 配对与连接：WSS、自签证书 SHA-256 固定、设备 token（Android Keystore）、断线指数退避重连。
- 主页：待确认 / 运行中 / 继续上次 / 新建会话，最近会话列表。
- 会话抽屉：搜索、运行中 / 待确认筛选、会话列表、daemon 连接状态。
- 聊天：流式文本、Markdown、工具卡片（Bash / Read / Edit / Write / Grep 等）、停止按钮。
- 权限确认：允许一次 / 本会话总是允许 / 拒绝 / 拒绝并停止，倒计时自动拒绝，写入 / 编辑内容预览。
- 权限模式：Manual / Plan / Accept Edits / Auto / Bypass，新建会话时可选，设置页按会话切换；Bypass 需二次确认并显示红色横幅。
- AskUserQuestion：单选 / 多选 / 自由输入。
- 设置：服务器信息、权限模式、主题（浅色默认 / 深色 / 跟随系统）、工作目录、断开并清除配对。
- 持久化：daemon SQLite 事件流 + 手机端 sqflite 缓存 + 重连快照。
- 附件：拍照 / 相册 / 文件，上传到 daemon 后作为 image / document content block；任意文件复制到工作区并让 Claude 用 Read 读取。
- 前台服务 + 本地通知：连接期间保持进程；后台收到权限或选择题时发高优先级通知。
- 多设备并发：多台设备同时在线，权限/问题由最先响应者决定，其他设备弹层自动关闭并提示「已由 X 处理」。
- 设备管理：设备列表、撤销、轮换 token（本机轮换后自动用新 token 重连）。
- 费用/限制：聊天底部显示累计费用、tokens 和轮数；设置页显示 daemon 的单轮预算与最大轮数。
- systemd：提供用户级 unit 示例，见下方。

## 测试

```bash
cd daemon && npm test          # 协议 / 事件存储 / 权限桥
cd app && flutter test         # 路径与格式化工具
cd app && flutter analyze
```

端到端验证已覆盖：配对 → WSS 认证 → 新建会话 → 发消息 → 流式输出 → Write 工具触发权限卡 → 允许一次 → 文件实际写入 → 工具结果与最终回复 → 清除 App 数据后重新配对并从 daemon 快照恢复历史。

另外已实测：

- 相机拍照 → 附件上传 → 图片作为 content block 送到 Claude → Claude 描述图片。
- 前台服务运行（dataSync），通知栏显示「已连接 · N 个会话」。
- 第二台设备（e2e 客户端）挂起 Write 权限，App 退到后台收到高优先级通知；App 回到前台后权限弹层自动出现，批准后第二台设备收到 resolved、工具执行并成功结束。
- 本机 token 轮换：App 保存新 token 并自动重连，daemon 日志显示新的 `ws.authenticated`。
- 聊天底部显示「累计 $0.10 · 1.8k tok · 1 轮」。
- acceptEdits / auto / bypassPermissions 三种模式：Write 工具直接执行、不弹权限卡；plan 模式批准计划后自动切回 default 并广播 `session.updated`。
- 主页与会话共用同一标题栏和输入框，会话内没有返回箭头；硬件返回键回到主页，抽屉顶部有「主页」入口。

## systemd 用户服务

```bash
cd ~/code/myproject/Claude_Remote/daemon
npm run build

mkdir -p ~/.config/systemd/user ~/.config/claude-remote
cp ../deploy/claude-remote.service ~/.config/systemd/user/

# 创建环境文件：写入你现有的 ANTHROPIC_* 变量
cat > ~/.config/claude-remote/env <<'EOF'
ANTHROPIC_BASE_URL=https://api.deepseek.com/anthropic
ANTHROPIC_AUTH_TOKEN=替换成你的 token
ANTHROPIC_MODEL=deepseek-flash[1M]
EOF
chmod 600 ~/.config/claude-remote/env

systemctl --user daemon-reload
systemctl --user enable --now claude-remote
journalctl --user -u claude-remote -f   # 配对二维码和日志在这里
loginctl enable-linger "$USER"           # 登出后继续运行
```

unit 假设仓库在 `~/code/myproject/Claude_Remote`、Node 在 `~/.local/bin/node`。路径不同就改 `ExecStart` / `WorkingDirectory`。

## 尚未完成

- 不同 OEM 真机的后台存活、锁屏通知点击深链（当前点击通知会打开 App，权限弹层在恢复后自动出现）。
- `interrupt`、`AskUserQuestion` 在真机上的完整实测（协议和 UI 已实现）。
- 发布签名、iOS 客户端、Tailscale/公网传输层。
- Android 15 `dataSync` 前台服务每 24 小时最多 6 小时；长时间后台需要重新打开 App 或改用 `specialUse`。

## 安全说明

- daemon 只接受私有网段来源，手机连接必须通过 WSS；证书固定比对的是整张证书的 SHA-256，不依赖公共 CA。
- 二维码只包含一次性配对码、WSS 地址和证书指纹；长期设备 token 由 `/pair` 换取，服务端只保存其哈希。
- 权限桥 fail-closed：超时、断线、中断、daemon 重启都会拒绝；不提供 `bypassPermissions`。
- `allowedRoots` 只是工作目录白名单，**不是文件系统沙箱**：Claude 仍可通过 Bash 访问其他路径，真正的硬隔离需要容器或 sandbox。
