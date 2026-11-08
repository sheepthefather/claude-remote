import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { isPathAllowed } from "../config.js";
import type { Config } from "../config.js";
import type { PermissionDecision, PermissionMode } from "../protocol/messages.js";
import type { EventStore, SessionRecord, SessionStatus } from "../store/event-store.js";
import type { Logger } from "../util/logger.js";
import type { DeviceActor, PermissionBridge } from "./permissions.js";
import { Session, type AttachmentRef, type Run } from "./session.js";

export interface WireSession extends SessionRecord {
  live: boolean;
}

export class SessionError extends Error {
  constructor(
    public readonly code: string,
    message: string,
  ) {
    super(message);
    this.name = "SessionError";
  }
}

export interface SessionManagerDeps {
  config: Config;
  store: EventStore;
  bootId: string;
  bridge: PermissionBridge;
  emit: (type: string, sessionId: string, payload: unknown, durable?: boolean) => void;
  logger: Logger;
}

export interface CreateSessionInput {
  cwd: string;
  title?: string;
  permissionMode: PermissionMode;
}

export interface SendPromptInput {
  text: string;
  attachments: AttachmentRef[];
  clientMsgId: string;
}

function expandHome(input: string): string {
  if (input === "~") return os.homedir();
  if (input.startsWith("~/")) return path.join(os.homedir(), input.slice(2));
  return input;
}

export class SessionManager {
  private readonly live = new Map<string, Session>();
  private readonly sent = new Map<string, Run>();
  private readonly reaper: NodeJS.Timeout;

  constructor(private readonly deps: SessionManagerDeps) {
    this.reaper = setInterval(() => this.reapIdle(), 60_000);
    this.reaper.unref();
  }

  list(): WireSession[] {
    return this.deps.store.listSessions().map((record) => this.wire(record));
  }

  create(input: CreateSessionInput): SessionRecord {
    const cwd = path.resolve(expandHome(input.cwd));
    if (!isPathAllowed(cwd, this.deps.config.allowedRoots)) {
      throw new SessionError(
        "CWD_NOT_ALLOWED",
        `目录不在 allowedRoots 内：${cwd}`,
      );
    }
    if (!fs.existsSync(cwd) || !fs.statSync(cwd).isDirectory()) {
      throw new SessionError("CWD_NOT_ALLOWED", `目录不存在或不是目录：${cwd}`);
    }

    const now = Date.now();
    const record: SessionRecord = {
      id: crypto.randomUUID(),
      title: input.title?.trim() || path.basename(cwd) || "新会话",
      cwd,
      permissionMode: input.permissionMode,
      sdkSessionId: null,
      status: "idle",
      createdAt: now,
      lastActiveAt: now,
    };
    this.deps.store.upsertSession(record);
    this.deps.emit("session.created", record.id, { session: this.wire(record) }, true);
    this.deps.logger.info("session.created", { sessionId: record.id, cwd });
    return record;
  }

  resume(sessionId: string): WireSession {
    const record = this.deps.store.getSession(sessionId);
    if (!record) throw new SessionError("SESSION_NOT_FOUND", "会话不存在");
    if (record.status === "closed") {
      throw new SessionError("SESSION_CLOSED", "会话已关闭");
    }
    record.lastActiveAt = Date.now();
    this.deps.store.upsertSession(record);
    this.deps.emit(
      "session.updated",
      sessionId,
      { session: this.wire(record) },
      true,
    );
    return this.wire(record);
  }

  async sendPrompt(sessionId: string, input: SendPromptInput): Promise<Run> {
    const key = `${sessionId}:${input.clientMsgId}`;
    const existing = this.sent.get(key);
    if (existing) return existing;

    const session = this.ensureLive(sessionId);
    const run = await session.sendPrompt(input);

    this.sent.set(key, run);
    if (this.sent.size > 1000) {
      const first = this.sent.keys().next().value;
      if (first !== undefined) this.sent.delete(first);
    }

    this.updateRecord(sessionId, { status: "running", lastActiveAt: Date.now() });
    return run;
  }

  async interrupt(sessionId: string): Promise<void> {
    const session = this.live.get(sessionId);
    this.deps.bridge.cancelSession(sessionId, "interrupt");
    if (session) {
      await session.interrupt();
    } else {
      this.updateRecord(sessionId, { status: "idle" });
    }
  }

  respondPermission(
    permissionId: string,
    requestId: string,
    decision: PermissionDecision,
    message?: string,
    actor?: DeviceActor,
  ): boolean {
    return this.deps.bridge.respond(
      permissionId,
      requestId,
      decision,
      message,
      actor,
    );
  }

  respondQuestion(
    permissionId: string,
    answers: Record<string, string>,
    actor?: DeviceActor,
  ): boolean {
    return this.deps.bridge.respondQuestion(permissionId, answers, actor);
  }

  async setPermissionMode(sessionId: string, mode: PermissionMode): Promise<void> {
    const session = this.live.get(sessionId);
    if (session) {
      await session.setPermissionMode(mode);
    } else {
      this.updateRecord(sessionId, { permissionMode: mode });
    }
  }

  close(sessionId: string): void {
    const session = this.live.get(sessionId);
    this.deps.bridge.cancelSession(sessionId, "interrupt");
    if (session) {
      session.close();
      this.live.delete(sessionId);
    }
    this.updateRecord(sessionId, { status: "closed", lastActiveAt: Date.now() });
    this.deps.emit("session.closed", sessionId, { sessionId }, true);
    this.deps.logger.info("session.closed", { sessionId });
  }

  closeAll(): void {
    this.deps.bridge.cancelAll("interrupt");
    for (const session of this.live.values()) session.close();
    this.live.clear();
    clearInterval(this.reaper);
  }

  private ensureLive(sessionId: string): Session {
    const existing = this.live.get(sessionId);
    if (existing) {
      existing.lastActiveAt = Date.now();
      return existing;
    }

    if (this.live.size >= this.deps.config.maxLiveSessions) {
      if (!this.reapOneIdle()) {
        throw new SessionError(
          "LIVE_LIMIT",
          `同时最多 ${this.deps.config.maxLiveSessions} 个活跃会话，请先关闭一个`,
        );
      }
    }

    const record = this.deps.store.getSession(sessionId);
    if (!record) throw new SessionError("SESSION_NOT_FOUND", "会话不存在");
    if (record.status === "closed") {
      throw new SessionError("SESSION_CLOSED", "会话已关闭");
    }

    const session = new Session({
      record,
      config: this.deps.config,
      canUseTool: this.deps.bridge.createHandler(sessionId),
      emit: (type, payload, durable = true) =>
        this.deps.emit(type, sessionId, payload, durable),
      onSdkSessionId: (sdkSessionId) => {
        this.updateRecord(sessionId, { sdkSessionId });
      },
      onStatus: (status) => {
        this.updateRecord(sessionId, { status, lastActiveAt: Date.now() });
      },
      onPermissionMode: (permissionMode) => {
        this.updateRecord(sessionId, { permissionMode });
      },
      onEnded: () => this.onLiveEnded(sessionId),
      logger: this.deps.logger.child({ sessionId }),
    });

    this.live.set(sessionId, session);
    this.deps.logger.info("session.live_started", {
      sessionId,
      resumed: Boolean(record.sdkSessionId),
    });
    return session;
  }

  private onLiveEnded(sessionId: string): void {
    if (!this.live.delete(sessionId)) return;
    const record = this.deps.store.getSession(sessionId);
    if (record && record.status !== "closed") {
      this.updateRecord(sessionId, { status: "idle" });
    }
    this.deps.logger.info("session.live_ended", { sessionId });
  }

  private reapIdle(): void {
    const now = Date.now();
    for (const [sessionId, session] of [...this.live.entries()]) {
      const record = this.deps.store.getSession(sessionId);
      if (!record || record.status !== "idle") continue;
      if (now - session.lastActiveAt < this.deps.config.idleReapMs) continue;
      session.close();
      this.live.delete(sessionId);
      this.updateRecord(sessionId, { status: "idle" });
      this.deps.logger.info("session.reaped", { sessionId });
    }
  }

  private reapOneIdle(): boolean {
    let candidate: [string, Session] | undefined;
    for (const entry of this.live.entries()) {
      const record = this.deps.store.getSession(entry[0]);
      if (record?.status !== "idle") continue;
      if (!candidate || entry[1].lastActiveAt < candidate[1].lastActiveAt) {
        candidate = entry;
      }
    }
    if (!candidate) return false;
    candidate[1].close();
    this.live.delete(candidate[0]);
    this.updateRecord(candidate[0], { status: "idle" });
    this.deps.logger.info("session.evicted", { sessionId: candidate[0] });
    return true;
  }

  private updateRecord(sessionId: string, patch: Partial<SessionRecord>): void {
    const current = this.deps.store.getSession(sessionId);
    if (!current) return;
    const next: SessionRecord = {
      ...current,
      ...patch,
      lastActiveAt: patch.lastActiveAt ?? current.lastActiveAt,
    };
    this.deps.store.upsertSession(next);
    this.deps.emit(
      "session.updated",
      sessionId,
      { session: this.wire(next) },
      true,
    );
  }

  private wire(record: SessionRecord): WireSession {
    return { ...record, live: this.live.has(record.id) };
  }
}
