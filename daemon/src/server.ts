import crypto from "node:crypto";
import fs from "node:fs";
import https from "node:https";
import type { IncomingMessage, ServerResponse } from "node:http";
import os from "node:os";
import path from "node:path";
import qrcode from "qrcode-terminal";
import { WebSocket, WebSocketServer } from "ws";
import { z } from "zod";
import type { Config } from "./config.js";
import { ensureRuntimeDirs } from "./config.js";
import {
  makeMessage,
  parseClientMessage,
  PROTOCOL_VERSION,
  type ClientMessage,
  type OutboundMessage,
} from "./protocol/messages.js";
import {
  createDeviceToken,
  hashToken,
  PairingManager,
} from "./security/pairing.js";
import { ensureTlsMaterial, listLocalIpv4, type TlsMaterial } from "./security/tls.js";
import type { EventStore } from "./store/event-store.js";
import type { SessionManager } from "./session/manager.js";
import { SessionError } from "./session/manager.js";
import type { PermissionBridge } from "./session/permissions.js";
import { sanitizeFileName } from "./util/files.js";
import type { Logger } from "./util/logger.js";

const SERVER_VERSION = "0.1.0";

const PairRequestSchema = z.object({
  code: z.string().min(1).max(64),
  deviceName: z.string().min(1).max(60).default("Android"),
});

interface ClientState {
  ws: WebSocket;
  ip: string;
  authenticated: boolean;
  deviceId?: string;
  deviceName?: string;
  authTimer?: NodeJS.Timeout;
}

export interface RemoteServerDeps {
  config: Config;
  store: EventStore;
  manager: SessionManager;
  bridge: PermissionBridge;
  bootId: string;
  logger: Logger;
}

function json(res: ServerResponse, status: number, body: unknown): void {
  const data = JSON.stringify(body);
  res.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "content-length": Buffer.byteLength(data),
  });
  res.end(data);
}

function normalizeIp(ip: string | undefined): string {
  if (!ip) return "unknown";
  return ip.startsWith("::ffff:") ? ip.slice(7) : ip;
}

function isPrivateIp(ip: string): boolean {
  if (ip === "::1" || ip.startsWith("127.")) return true;
  if (ip.startsWith("10.") || ip.startsWith("192.168.")) return true;
  if (ip.startsWith("172.")) {
    const second = Number(ip.split(".")[1]);
    if (second >= 16 && second <= 31) return true;
  }
  // Tailscale CGNAT range, kept for the future transport option.
  if (ip.startsWith("100.")) {
    const second = Number(ip.split(".")[1]);
    if (second >= 64 && second <= 127) return true;
  }
  if (ip.startsWith("fc") || ip.startsWith("fd") || ip.startsWith("fe80:")) return true;
  return false;
}

function readJson(req: IncomingMessage, limit = 8192): Promise<unknown> {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks: Buffer[] = [];
    req.on("data", (chunk: Buffer) => {
      size += chunk.length;
      if (size > limit) {
        reject(new Error("请求体过大"));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on("end", () => {
      try {
        const raw = Buffer.concat(chunks).toString("utf8");
        resolve(raw.length ? JSON.parse(raw) : {});
      } catch (error) {
        reject(error);
      }
    });
    req.on("error", reject);
  });
}

export class RemoteServer {
  private tls!: TlsMaterial;
  private httpsServer!: https.Server;
  private wss!: WebSocketServer;
  private readonly clients = new Set<ClientState>();
  private readonly pairing: PairingManager;
  private readonly authAttempts = new Map<string, { count: number; resetAt: number }>();

  constructor(private readonly deps: RemoteServerDeps) {
    this.pairing = new PairingManager(deps.config.pairingCodeTtlMs);
  }

  async start(): Promise<void> {
    ensureRuntimeDirs(this.deps.config);
    this.tls = ensureTlsMaterial(this.deps.config.tlsCertPath, this.deps.config.tlsKeyPath);

    this.httpsServer = https.createServer(
      { cert: this.tls.certPem, key: this.tls.keyPem },
      (req, res) => this.handleHttp(req, res),
    );
    this.wss = new WebSocketServer({
      server: this.httpsServer,
      maxPayload: 2 * 1024 * 1024,
    });
    this.wss.on("connection", (ws, req) => this.handleConnection(ws, req));

    await new Promise<void>((resolve, reject) => {
      const onError = (error: Error) => reject(error);
      this.httpsServer.once("error", onError);
      this.httpsServer.listen(this.deps.config.port, this.deps.config.host, () => {
        this.httpsServer.off("error", onError);
        resolve();
      });
    });

    this.printPairing();
    this.deps.logger.info("server.listening", {
      host: this.deps.config.host,
      port: this.deps.config.port,
      certSha256: this.tls.fingerprintSha256,
    });
  }

  async stop(): Promise<void> {
    for (const client of this.clients) {
      try {
        client.ws.close(1001, "server shutdown");
      } catch {
        /* ignore */
      }
    }
    this.clients.clear();

    this.httpsServer.closeAllConnections?.();
    await Promise.race([
      new Promise<void>((resolve) => this.wss.close(() => resolve())),
      new Promise<void>((resolve) => setTimeout(resolve, 1500)),
    ]);
    await Promise.race([
      new Promise<void>((resolve) => this.httpsServer.close(() => resolve())),
      new Promise<void>((resolve) => setTimeout(resolve, 1500)),
    ]);
  }

  broadcast(message: OutboundMessage): void {
    const data = JSON.stringify(message);
    for (const client of this.clients) {
      if (!client.authenticated || client.ws.readyState !== WebSocket.OPEN) continue;
      try {
        client.ws.send(data);
      } catch (error) {
        this.deps.logger.warn("ws.send_failed", {
          deviceId: client.deviceId,
          error: String(error),
        });
      }
    }
  }

  regeneratePairing(): void {
    this.printPairing();
  }

  /* ---------------- websocket ---------------- */

  private handleConnection(ws: WebSocket, req: IncomingMessage): void {
    const ip = normalizeIp(req.socket.remoteAddress);
    if (!isPrivateIp(ip)) {
      ws.close(1008, "LAN only");
      return;
    }

    const client: ClientState = { ws, ip, authenticated: false };
    this.clients.add(client);

    client.authTimer = setTimeout(() => {
      if (!client.authenticated) ws.close(4401, "auth timeout");
    }, 5000);
    client.authTimer.unref?.();

    ws.on("message", (data) => {
      void this.onMessage(client, data.toString());
    });
    ws.on("close", () => {
      if (client.authTimer) clearTimeout(client.authTimer);
      this.clients.delete(client);
      this.deps.logger.info("ws.closed", {
        ip: client.ip,
        deviceId: client.deviceId ?? null,
      });
    });
    ws.on("error", (error) => {
      this.deps.logger.warn("ws.error", { ip: client.ip, error: String(error) });
    });
  }

  private async onMessage(client: ClientState, raw: string): Promise<void> {
    let message: ClientMessage;
    try {
      message = parseClientMessage(raw);
    } catch (error) {
      this.sendError(client, "PROTOCOL_ERROR", `消息格式错误：${String(error)}`);
      client.ws.close(4400, "protocol error");
      return;
    }

    if (!client.authenticated) {
      if (message.type !== "client.hello") {
        client.ws.close(4401, "auth required");
        return;
      }
      this.handleHello(client, message);
      return;
    }

    try {
      switch (message.type) {
        case "client.hello":
          this.sendError(client, "PROTOCOL_ERROR", "重复的 client.hello");
          break;

        case "sync.request":
          this.handleSync(client, message.payload.lastEventId);
          break;

        case "session.create":
          if (!this.allowMode(client, message.payload.permissionMode)) break;
          this.deps.manager.create({
            cwd: message.payload.cwd,
            title: message.payload.title,
            permissionMode: message.payload.permissionMode,
          });
          break;

        case "session.resume":
          this.deps.manager.resume(message.payload.sessionId);
          break;

        case "session.close":
          this.deps.manager.close(message.payload.sessionId);
          break;

        case "session.setPermissionMode":
          if (!this.allowMode(client, message.payload.mode)) break;
          await this.deps.manager.setPermissionMode(
            message.payload.sessionId,
            message.payload.mode,
          );
          break;

        case "prompt.send": {
          const run = await this.deps.manager.sendPrompt(message.payload.sessionId, {
            text: message.payload.text,
            attachments: message.payload.attachments,
            clientMsgId: message.payload.clientMsgId,
          });
          this.send(
            client,
            makeMessage(
              this.deps.bootId,
              "command.ack",
              {
                clientMsgId: message.payload.clientMsgId,
                accepted: true,
                runId: run.runId,
              },
              { sessionId: message.payload.sessionId },
            ),
          );
          break;
        }

        case "run.interrupt":
          await this.deps.manager.interrupt(message.payload.sessionId);
          break;

        case "permission.respond": {
          if (message.bootId && message.bootId !== this.deps.bootId) {
            this.sendError(client, "STALE_BOOT", "daemon 已重启，请重新同步", true);
            break;
          }
          const ok = this.deps.manager.respondPermission(
            message.payload.permissionId,
            message.payload.requestId,
            message.payload.decision,
            message.payload.message,
            this.actorFor(client),
          );
          if (!ok) {
            this.sendError(
              client,
              "PERMISSION_NOT_FOUND",
              "权限请求不存在、已处理或 requestId 不匹配",
              true,
            );
          }
          break;
        }

        case "question.respond": {
          if (message.bootId && message.bootId !== this.deps.bootId) {
            this.sendError(client, "STALE_BOOT", "daemon 已重启，请重新同步", true);
            break;
          }
          const ok = this.deps.manager.respondQuestion(
            message.payload.permissionId,
            message.payload.answers,
            this.actorFor(client),
          );
          if (!ok) {
            this.sendError(
              client,
              "PERMISSION_NOT_FOUND",
              "选择题不存在或已处理",
              true,
            );
          }
          break;
        }

        case "devices.list": {
          const devices = this.deps.store.listDevices().map((device) => ({
            ...device,
            current: device.id === client.deviceId,
          }));
          this.send(
            client,
            makeMessage(this.deps.bootId, "devices.list", { devices }),
          );
          break;
        }

        case "device.revoke": {
          const target = this.deps.store
            .listDevices()
            .find((device) => device.id === message.payload.deviceId);
          if (!target) {
            this.sendError(client, "DEVICE_NOT_FOUND", "设备不存在");
            break;
          }
          this.deps.store.revokeDevice(target.id);
          this.send(
            client,
            makeMessage(this.deps.bootId, "device.revoked", {
              deviceId: target.id,
            }),
          );
          setTimeout(
            () => this.closeDeviceConnection(target.id, 4401, "device revoked"),
            200,
          );
          this.deps.logger.info("device.revoked", {
            deviceId: target.id,
            by: client.deviceName,
          });
          break;
        }

        case "device.rotateToken": {
          const target = this.deps.store
            .listDevices()
            .find((device) => device.id === message.payload.deviceId);
          if (!target) {
            this.sendError(client, "DEVICE_NOT_FOUND", "设备不存在");
            break;
          }
          const token = createDeviceToken();
          this.deps.store.updateDeviceToken(target.id, token.hash);
          const isCurrent = target.id === client.deviceId;
          this.send(
            client,
            makeMessage(this.deps.bootId, "device.tokenRotated", {
              deviceId: target.id,
              token: isCurrent ? token.token : null,
              requiresRepair: !isCurrent,
            }),
          );
          if (!isCurrent) {
            setTimeout(
              () => this.closeDeviceConnection(target.id, 4401, "token rotated"),
              200,
            );
          }
          this.deps.logger.info("device.token_rotated", {
            deviceId: target.id,
            by: client.deviceName,
          });
          break;
        }

        case "ping":
          this.send(
            client,
            makeMessage(this.deps.bootId, "pong", { nonce: message.payload.nonce }),
          );
          break;

        default:
          this.sendError(client, "PROTOCOL_ERROR", "未知消息类型");
      }
    } catch (error) {
      if (error instanceof SessionError) {
        this.sendError(client, error.code, error.message, true);
      } else {
        this.deps.logger.error("ws.handler_failed", {
          deviceId: client.deviceId,
          error: String((error as Error)?.stack ?? error),
        });
        this.sendError(client, "INTERNAL", "服务端内部错误", true);
      }
    }
  }

  private handleHello(
    client: ClientState,
    message: Extract<ClientMessage, { type: "client.hello" }>,
  ): void {
    if (message.payload.protocolVersion !== PROTOCOL_VERSION) {
      this.sendError(client, "PROTOCOL_ERROR", "协议版本不兼容，请升级 App");
      client.ws.close(4400, "protocol version mismatch");
      return;
    }

    if (!this.allowAuthAttempt(client.ip)) {
      this.sendError(client, "RATE_LIMITED", "尝试过于频繁，请稍后再试");
      client.ws.close(1013, "rate limited");
      return;
    }

    const device = this.deps.store.findDeviceByTokenHash(hashToken(message.payload.token));
    if (!device || device.id !== message.payload.deviceId) {
      this.sendError(client, "AUTH_FAILED", "设备 token 无效，请重新配对");
      client.ws.close(4401, "auth failed");
      return;
    }

    for (const other of this.clients) {
      if (other !== client && other.deviceId === device.id) {
        try {
          other.ws.close(4409, "replaced by a new connection");
        } catch {
          /* ignore */
        }
        this.clients.delete(other);
      }
    }

    client.authenticated = true;
    client.deviceId = device.id;
    client.deviceName = device.name;
    if (client.authTimer) {
      clearTimeout(client.authTimer);
      client.authTimer = undefined;
    }
    this.authAttempts.delete(client.ip);
    this.deps.store.touchDevice(device.id);

    this.send(
      client,
      makeMessage(this.deps.bootId, "server.hello", {
        protocolVersion: PROTOCOL_VERSION,
        serverVersion: SERVER_VERSION,
        serverName: os.hostname(),
        allowedRoots: this.deps.config.allowedRoots,
        maxTurns: this.deps.config.maxTurns,
        maxBudgetUsd: this.deps.config.maxBudgetUsd,
        minEventId: this.deps.store.minEventId(),
        maxEventId: this.deps.store.maxEventId(),
        capabilities: [
          "attachments",
          "questions",
          "interrupt",
          "snapshot",
          "devices",
        ],
      }),
    );
    this.deps.logger.info("ws.authenticated", {
      deviceId: device.id,
      deviceName: device.name,
      ip: client.ip,
    });
  }

  private handleSync(client: ClientState, lastEventId: number): void {
    const min = this.deps.store.minEventId();
    const max = this.deps.store.maxEventId();

    if (lastEventId < min && min > 0) {
      const recent = this.deps.store.eventsAfter(Math.max(0, max - 200), 200);
      this.send(
        client,
        makeMessage(this.deps.bootId, "sync.snapshot", {
          lastEventId: max,
          sessions: this.deps.manager.list(),
          messages: recent,
          runs: [],
          pendingPermissions: this.deps.store.listPending().map((item) => item.payload),
        }),
      );
      this.send(
        client,
        makeMessage(this.deps.bootId, "sync.complete", { lastEventId: max }),
      );
      return;
    }

    const events = this.deps.store.eventsAfter(lastEventId, 200);
    const nextEventId = events.length > 0 ? events[events.length - 1]!.eventId : lastEventId;
    const hasMore = events.length === 200 && nextEventId < max;

    this.send(
      client,
      makeMessage(this.deps.bootId, "sync.replay", {
        events: events.map((event) => ({
          eventId: event.eventId,
          type: event.type,
          sessionId: event.sessionId,
          payload: event.payload,
          createdAt: event.createdAt,
        })),
        nextEventId,
        hasMore,
      }),
    );

    if (!hasMore) {
      this.send(
        client,
        makeMessage(this.deps.bootId, "sync.complete", { lastEventId: nextEventId }),
      );
    }
  }

  /* ---------------- http ---------------- */

  private handleHttp(req: IncomingMessage, res: ServerResponse): void {
    const url = new URL(req.url ?? "/", `https://${req.headers.host ?? "localhost"}`);

    if (req.method === "GET" && url.pathname === "/health") {
      json(res, 200, {
        ok: true,
        name: "claude-remote",
        serverVersion: SERVER_VERSION,
        protocolVersion: PROTOCOL_VERSION,
        bootId: this.deps.bootId,
      });
      return;
    }

    if (req.method === "POST" && url.pathname === "/pair") {
      void this.handlePair(req, res);
      return;
    }

    if (req.method === "POST" && url.pathname === "/attachments") {
      void this.handleAttachment(req, res);
      return;
    }

    if (req.method === "GET" && url.pathname === "/") {
      json(res, 200, {
        name: "claude-remote",
        hint: "POST /pair with the one-time code from the terminal; use WSS for /ws",
      });
      return;
    }

    json(res, 404, { error: "not found" });
  }

  private async handlePair(req: IncomingMessage, res: ServerResponse): Promise<void> {
    try {
      const ip = normalizeIp(req.socket.remoteAddress);
      if (!isPrivateIp(ip)) {
        json(res, 403, { error: "LAN only" });
        return;
      }
      if (!this.allowAuthAttempt(ip)) {
        json(res, 429, { error: "too many attempts" });
        return;
      }

      const body = await readJson(req);
      const parsed = PairRequestSchema.safeParse(body);
      if (!parsed.success) {
        json(res, 400, { error: "code 与 deviceName 必填" });
        return;
      }
      if (!this.pairing.redeem(parsed.data.code)) {
        json(res, 403, { error: "配对码无效或已过期" });
        return;
      }

      const token = createDeviceToken();
      const deviceId = `dev_${crypto.randomUUID()}`;
      this.deps.store.addDevice({
        id: deviceId,
        name: parsed.data.deviceName,
        tokenHash: token.hash,
        createdAt: Date.now(),
        lastSeenAt: null,
      });
      this.authAttempts.delete(ip);
      this.deps.logger.info("device.paired", { deviceId, deviceName: parsed.data.deviceName });
      json(res, 200, {
        deviceId,
        token: token.token,
        serverName: os.hostname(),
        protocolVersion: PROTOCOL_VERSION,
      });
    } catch (error) {
      this.deps.logger.warn("pair.failed", { error: String(error) });
      json(res, 400, { error: "配对请求无效" });
    }
  }

  private async handleAttachment(req: IncomingMessage, res: ServerResponse): Promise<void> {
    const auth = req.headers.authorization ?? "";
    const token = auth.startsWith("Bearer ") ? auth.slice("Bearer ".length) : "";
    const device = token
      ? this.deps.store.findDeviceByTokenHash(hashToken(token))
      : undefined;
    if (!device) {
      json(res, 401, { error: "unauthorized" });
      return;
    }

    const fileName = sanitizeFileName(String(req.headers["x-file-name"] ?? "file"));
    const mime = String(req.headers["content-type"] ?? "application/octet-stream");
    const id = crypto.randomUUID();
    const dir = path.join(this.deps.config.attachmentsDir, id);
    const dest = path.join(dir, fileName);

    try {
      fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
    } catch (error) {
      json(res, 500, { error: "无法创建附件目录" });
      this.deps.logger.error("attachment.mkdir_failed", { error: String(error) });
      return;
    }

    const out = fs.createWriteStream(dest, { mode: 0o600 });
    let size = 0;
    let failed = false;

    const fail = (status: number, message: string) => {
      if (failed) return;
      failed = true;
      out.destroy();
      fs.rmSync(dir, { recursive: true, force: true });
      if (!res.headersSent) json(res, status, { error: message });
      req.destroy();
    };

    req.on("data", (chunk: Buffer) => {
      if (failed) return;
      size += chunk.length;
      if (size > this.deps.config.maxAttachmentBytes) {
        fail(413, "附件过大");
        return;
      }
      out.write(chunk);
    });
    req.on("error", () => fail(400, "上传中断"));
    req.on("end", () => {
      if (failed) return;
      out.end(() => {
        json(res, 200, { id, name: fileName, mime, size });
        this.deps.logger.info("attachment.uploaded", {
          deviceId: device.id,
          id,
          name: fileName,
          size,
        });
      });
    });
  }

  /* ---------------- helpers ---------------- */

  private actorFor(client: ClientState): { id: string; name: string } | undefined {
    if (!client.deviceId) return undefined;
    return { id: client.deviceId, name: client.deviceName ?? "unknown" };
  }

  private closeDeviceConnection(deviceId: string, code: number, reason: string): void {
    for (const other of [...this.clients]) {
      if (other.deviceId !== deviceId) continue;
      try {
        other.ws.close(code, reason);
      } catch {
        /* ignore */
      }
      this.clients.delete(other);
    }
  }

  private send(client: ClientState, message: OutboundMessage): void {
    if (client.ws.readyState !== WebSocket.OPEN) return;
    try {
      client.ws.send(JSON.stringify(message));
    } catch (error) {
      this.deps.logger.warn("ws.send_failed", { error: String(error) });
    }
  }

  private sendError(
    client: ClientState,
    code: string,
    message: string,
    recoverable = false,
  ): void {
    this.send(
      client,
      makeMessage(this.deps.bootId, "error", { code, message, recoverable }),
    );
  }

  private allowMode(client: ClientState, mode: string): boolean {
    if (
      mode === "bypassPermissions" &&
      !this.deps.config.allowDangerousModes
    ) {
      this.sendError(
        client,
        "MODE_NOT_ALLOWED",
        "daemon 配置禁用了 bypassPermissions（allowDangerousModes=false）",
      );
      return false;
    }
    return true;
  }

  private allowAuthAttempt(ip: string): boolean {
    const now = Date.now();
    const entry = this.authAttempts.get(ip);
    if (!entry || entry.resetAt <= now) {
      this.authAttempts.set(ip, { count: 1, resetAt: now + 60_000 });
      return true;
    }
    if (entry.count >= 10) return false;
    entry.count += 1;
    return true;
  }

  private printPairing(): void {
    const code = this.pairing.create();
    const ips = listLocalIpv4();
    const ip = ips[0] ?? "127.0.0.1";
    const url = `wss://${ip}:${this.deps.config.port}/ws`;
    const payload = {
      v: 1,
      url,
      certSha256: this.tls.fingerprintSha256,
      code: code.code,
      expiresAt: code.expiresAt,
      name: os.hostname(),
    };

    process.stdout.write("\n");
    process.stdout.write("Claude Remote daemon 已启动\n");
    process.stdout.write(`  LAN IP       : ${ips.length ? ips.join(", ") : "未检测到局域网地址"}\n`);
    process.stdout.write(`  WSS          : ${url}\n`);
    process.stdout.write(`  证书 SHA-256 : ${this.tls.fingerprintSha256}\n`);
    process.stdout.write(
      `  配对码       : ${code.code}（${new Date(code.expiresAt).toLocaleTimeString()} 前有效）\n`,
    );
    process.stdout.write("  手机扫描下面的二维码：\n\n");
    qrcode.generate(JSON.stringify(payload), { small: true }, (qr) => {
      process.stdout.write(qr);
      process.stdout.write("\n");
    });
    if (ips.length === 0) {
      process.stdout.write("警告：没有检测到局域网 IPv4，手机可能无法连接。\n");
    }
  }
}
