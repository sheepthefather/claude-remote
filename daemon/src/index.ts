import crypto from "node:crypto";
import { loadConfig, ensureRuntimeDirs } from "./config.js";
import {
  makeMessage,
  type OutboundMessage,
} from "./protocol/messages.js";
import { createDeviceToken } from "./security/pairing.js";
import { PermissionBridge } from "./session/permissions.js";
import { SessionManager } from "./session/manager.js";
import { RemoteServer } from "./server.js";
import { EventStore } from "./store/event-store.js";
import { createLogger } from "./util/logger.js";

async function serve(): Promise<void> {
  const config = loadConfig();
  ensureRuntimeDirs(config);

  const logger = createLogger(config.logLevel);
  const bootId = crypto.randomUUID();
  const store = new EventStore(config.dbPath);

  let broadcast: (message: OutboundMessage) => void = () => {};
  const emit = (
    type: string,
    sessionId: string | null,
    payload: unknown,
    durable = true,
  ): void => {
    const eventId = durable
      ? store.appendEvent(type, sessionId, payload)
      : undefined;
    broadcast(
      makeMessage(bootId, type, payload, {
        sessionId: sessionId ?? undefined,
        eventId,
      }),
    );
  };

  // Requests that were pending when the previous daemon process died can no
  // longer be answered. Record them as denied before any client reconnects.
  for (const pending of store.drainStalePending(bootId)) {
    const payload = pending.payload as { questions?: unknown } | null;
    const isQuestion = Array.isArray(payload?.questions);
    store.appendEvent(
      isQuestion ? "question.resolved" : "permission.resolved",
      pending.sessionId,
      {
        permissionId: pending.permissionId,
        decision: "deny",
        source: "daemon_restart",
        cancelled: true,
      },
    );
  }

  const pruned = store.pruneEvents(config.eventRetentionDays);
  if (pruned > 0) logger.info("events.pruned", { count: pruned });

  const bridge = new PermissionBridge({
    bootId,
    timeoutMs: config.permissionTimeoutMs,
    store,
    emit,
    logger,
  });
  const manager = new SessionManager({
    config,
    store,
    bootId,
    bridge,
    emit,
    logger,
  });
  const server = new RemoteServer({
    config,
    store,
    manager,
    bridge,
    bootId,
    logger,
  });
  broadcast = (message) => server.broadcast(message);

  await server.start();
  process.on("SIGUSR1", () => server.regeneratePairing());

  const shutdown = async (signal: string): Promise<void> => {
    logger.info("daemon.shutdown", { signal });
    try {
      manager.closeAll();
    } catch (error) {
      logger.warn("daemon.close_sessions_failed", { error: String(error) });
    }
    try {
      await server.stop();
    } catch (error) {
      logger.warn("daemon.close_server_failed", { error: String(error) });
    }
    try {
      store.close();
    } catch {
      /* ignore */
    }
    process.exit(0);
  };

  process.on("SIGTERM", () => void shutdown("SIGTERM"));
  process.on("SIGINT", () => void shutdown("SIGINT"));

  logger.info("daemon.ready", {
    bootId,
    dataDir: config.dataDir,
    allowedRoots: config.allowedRoots,
  });
}

function listDevices(): void {
  const config = loadConfig();
  const store = new EventStore(config.dbPath);
  const devices = store.listDevices();
  if (devices.length === 0) {
    process.stdout.write("没有已配对设备。\n");
  } else {
    for (const device of devices) {
      const last = device.lastSeenAt
        ? new Date(device.lastSeenAt).toLocaleString()
        : "从未连接";
      process.stdout.write(`${device.id}\t${device.name}\t${last}\n`);
    }
  }
  store.close();
}

function revokeDevice(id: string | undefined): void {
  if (!id) {
    process.stderr.write("用法: claude-remote revoke-device <deviceId>\n");
    process.exit(1);
  }
  const config = loadConfig();
  const store = new EventStore(config.dbPath);
  const ok = store.revokeDevice(id);
  store.close();
  process.stdout.write(ok ? `已撤销设备 ${id}\n` : `设备不存在: ${id}\n`);
}

function rotateDeviceToken(id: string | undefined): void {
  if (!id) {
    process.stderr.write("用法: claude-remote rotate-device-token <deviceId>\n");
    process.exit(1);
  }
  const config = loadConfig();
  const store = new EventStore(config.dbPath);
  const token = createDeviceToken();
  const ok = store.updateDeviceToken(id, token.hash);
  store.close();
  if (!ok) {
    process.stderr.write(`设备不存在: ${id}\n`);
    process.exit(1);
  }
  process.stdout.write("新 token（只显示这一次，请在手机上重新输入）：\n");
  process.stdout.write(`${token.token}\n`);
}

function usage(): void {
  process.stdout.write(
    [
      "用法: claude-remote <command>",
      "",
      "  serve                         启动 daemon（默认）",
      "  list-devices                  列出已配对设备",
      "  revoke-device <deviceId>      撤销设备",
      "  rotate-device-token <deviceId> 轮换设备 token",
      "",
      "环境变量：",
      "  CLAUDE_REMOTE_CONFIG_DIR      配置目录（默认 ~/.config/claude-remote）",
      "  CLAUDE_REMOTE_DATA_DIR        数据目录（默认 ~/.local/share/claude-remote）",
      "  ANTHROPIC_*                   由 daemon 继承并传给 Claude Code",
      "",
    ].join("\n"),
  );
}

const command = process.argv[2] ?? "serve";
switch (command) {
  case "serve":
    await serve();
    break;
  case "list-devices":
    listDevices();
    break;
  case "revoke-device":
    revokeDevice(process.argv[3]);
    break;
  case "rotate-device-token":
    rotateDeviceToken(process.argv[3]);
    break;
  case "help":
  case "--help":
  case "-h":
    usage();
    break;
  default:
    usage();
    process.exit(1);
}
