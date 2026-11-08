import { DatabaseSync } from "node:sqlite";
import fs from "node:fs";
import path from "node:path";
import type { PermissionMode } from "../protocol/messages.js";

export type SessionStatus = "idle" | "running" | "waiting_permission" | "closed";

const PERMISSION_MODES: ReadonlySet<string> = new Set([
  "default",
  "plan",
  "acceptEdits",
  "auto",
  "bypassPermissions",
]);

function isPermissionMode(value: unknown): value is PermissionMode {
  return typeof value === "string" && PERMISSION_MODES.has(value);
}

export interface SessionRecord {
  id: string;
  title: string;
  cwd: string;
  permissionMode: PermissionMode;
  sdkSessionId: string | null;
  status: SessionStatus;
  createdAt: number;
  lastActiveAt: number;
}

export interface StoredEvent {
  eventId: number;
  type: string;
  sessionId: string | null;
  payload: unknown;
  createdAt: number;
}

export interface DeviceRecord {
  id: string;
  name: string;
  tokenHash: string;
  createdAt: number;
  lastSeenAt: number | null;
}

export interface PendingPermissionRecord {
  permissionId: string;
  bootId: string;
  sessionId: string;
  requestId: string;
  payload: unknown;
  createdAt: number;
}

export interface AuditRecord {
  sessionId?: string;
  toolName?: string;
  inputSummary?: string;
  decision?: string;
  source?: string;
  decidedBy?: string;
}

export class EventStore {
  private db: DatabaseSync;

  constructor(dbPath: string) {
    fs.mkdirSync(path.dirname(dbPath), { recursive: true, mode: 0o700 });
    this.db = new DatabaseSync(dbPath);
    this.db.exec(`
      PRAGMA journal_mode = WAL;
      PRAGMA synchronous = NORMAL;
      PRAGMA foreign_keys = ON;

      CREATE TABLE IF NOT EXISTS events (
        event_id INTEGER PRIMARY KEY AUTOINCREMENT,
        type TEXT NOT NULL,
        session_id TEXT,
        payload TEXT NOT NULL,
        created_at INTEGER NOT NULL
      );
      CREATE INDEX IF NOT EXISTS idx_events_session ON events(session_id, event_id);

      CREATE TABLE IF NOT EXISTS sessions (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        cwd TEXT NOT NULL,
        permission_mode TEXT NOT NULL,
        sdk_session_id TEXT,
        status TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        last_active_at INTEGER NOT NULL
      );

      CREATE TABLE IF NOT EXISTS devices (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        token_hash TEXT NOT NULL UNIQUE,
        created_at INTEGER NOT NULL,
        last_seen_at INTEGER
      );

      CREATE TABLE IF NOT EXISTS pending_permissions (
        permission_id TEXT PRIMARY KEY,
        boot_id TEXT NOT NULL,
        session_id TEXT NOT NULL,
        request_id TEXT NOT NULL,
        payload TEXT NOT NULL,
        created_at INTEGER NOT NULL
      );

      CREATE TABLE IF NOT EXISTS audit (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        ts INTEGER NOT NULL,
        session_id TEXT,
        tool_name TEXT,
        input_summary TEXT,
        decision TEXT,
        source TEXT,
        decided_by TEXT
      );
    `);
  }

  /* ---------------- events ---------------- */

  appendEvent(type: string, sessionId: string | null, payload: unknown): number {
    const result = this.db
      .prepare("INSERT INTO events (type, session_id, payload, created_at) VALUES (?, ?, ?, ?)")
      .run(type, sessionId, JSON.stringify(payload), Date.now());
    return Number(result.lastInsertRowid);
  }

  eventsAfter(lastEventId: number, limit = 200, sessionId?: string): StoredEvent[] {
    const rows = (
      sessionId
        ? this.db
            .prepare(
              "SELECT event_id, type, session_id, payload, created_at FROM events WHERE event_id > ? AND session_id = ? ORDER BY event_id ASC LIMIT ?",
            )
            .all(lastEventId, sessionId, limit)
        : this.db
            .prepare(
              "SELECT event_id, type, session_id, payload, created_at FROM events WHERE event_id > ? ORDER BY event_id ASC LIMIT ?",
            )
            .all(lastEventId, limit)
    ) as Array<Record<string, unknown>>;

    return rows.map((row) => ({
      eventId: Number(row.event_id),
      type: String(row.type),
      sessionId: row.session_id === null ? null : String(row.session_id),
      payload: JSON.parse(String(row.payload)) as unknown,
      createdAt: Number(row.created_at),
    }));
  }

  minEventId(): number {
    const row = this.db.prepare("SELECT MIN(event_id) AS v FROM events").get() as
      | Record<string, unknown>
      | undefined;
    return row && row.v !== null ? Number(row.v) : 0;
  }

  maxEventId(): number {
    const row = this.db.prepare("SELECT MAX(event_id) AS v FROM events").get() as
      | Record<string, unknown>
      | undefined;
    return row && row.v !== null ? Number(row.v) : 0;
  }

  pruneEvents(retentionDays: number): number {
    const cutoff = Date.now() - retentionDays * 24 * 60 * 60 * 1000;
    const result = this.db.prepare("DELETE FROM events WHERE created_at < ?").run(cutoff);
    return Number(result.changes);
  }

  /* ---------------- sessions ---------------- */

  upsertSession(session: SessionRecord): void {
    this.db
      .prepare(`
        INSERT INTO sessions (id, title, cwd, permission_mode, sdk_session_id, status, created_at, last_active_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
          title = excluded.title,
          cwd = excluded.cwd,
          permission_mode = excluded.permission_mode,
          sdk_session_id = excluded.sdk_session_id,
          status = excluded.status,
          last_active_at = excluded.last_active_at
      `)
      .run(
        session.id,
        session.title,
        session.cwd,
        session.permissionMode,
        session.sdkSessionId,
        session.status,
        session.createdAt,
        session.lastActiveAt,
      );
  }

  getSession(id: string): SessionRecord | undefined {
    const row = this.db.prepare("SELECT * FROM sessions WHERE id = ?").get(id) as
      | Record<string, unknown>
      | undefined;
    return row ? this.toSession(row) : undefined;
  }

  listSessions(): SessionRecord[] {
    const rows = this.db
      .prepare("SELECT * FROM sessions WHERE status != 'closed' ORDER BY last_active_at DESC")
      .all() as Array<Record<string, unknown>>;
    return rows.map((row) => this.toSession(row));
  }

  private toSession(row: Record<string, unknown>): SessionRecord {
    return {
      id: String(row.id),
      title: String(row.title),
      cwd: String(row.cwd),
      permissionMode: isPermissionMode(row.permission_mode)
        ? row.permission_mode
        : "default",
      sdkSessionId: row.sdk_session_id === null ? null : String(row.sdk_session_id),
      status: String(row.status) as SessionStatus,
      createdAt: Number(row.created_at),
      lastActiveAt: Number(row.last_active_at),
    };
  }

  /* ---------------- devices ---------------- */

  addDevice(device: DeviceRecord): void {
    this.db
      .prepare("INSERT INTO devices (id, name, token_hash, created_at, last_seen_at) VALUES (?, ?, ?, ?, ?)")
      .run(device.id, device.name, device.tokenHash, device.createdAt, device.lastSeenAt);
  }

  findDeviceByTokenHash(tokenHash: string): DeviceRecord | undefined {
    const row = this.db
      .prepare("SELECT * FROM devices WHERE token_hash = ?")
      .get(tokenHash) as Record<string, unknown> | undefined;
    if (!row) return undefined;
    return {
      id: String(row.id),
      name: String(row.name),
      tokenHash: String(row.token_hash),
      createdAt: Number(row.created_at),
      lastSeenAt: row.last_seen_at === null ? null : Number(row.last_seen_at),
    };
  }

  listDevices(): Array<Omit<DeviceRecord, "tokenHash">> {
    const rows = this.db
      .prepare("SELECT id, name, created_at, last_seen_at FROM devices ORDER BY created_at ASC")
      .all() as Array<Record<string, unknown>>;
    return rows.map((row) => ({
      id: String(row.id),
      name: String(row.name),
      createdAt: Number(row.created_at),
      lastSeenAt: row.last_seen_at === null ? null : Number(row.last_seen_at),
    }));
  }

  touchDevice(id: string): void {
    this.db.prepare("UPDATE devices SET last_seen_at = ? WHERE id = ?").run(Date.now(), id);
  }

  revokeDevice(id: string): boolean {
    const result = this.db.prepare("DELETE FROM devices WHERE id = ?").run(id);
    return Number(result.changes) > 0;
  }

  updateDeviceToken(id: string, tokenHash: string): boolean {
    const result = this.db
      .prepare("UPDATE devices SET token_hash = ? WHERE id = ?")
      .run(tokenHash, id);
    return Number(result.changes) > 0;
  }

  /* ---------------- pending permissions ---------------- */

  addPending(record: PendingPermissionRecord): void {
    this.db
      .prepare(
        "INSERT OR REPLACE INTO pending_permissions (permission_id, boot_id, session_id, request_id, payload, created_at) VALUES (?, ?, ?, ?, ?, ?)",
      )
      .run(
        record.permissionId,
        record.bootId,
        record.sessionId,
        record.requestId,
        JSON.stringify(record.payload),
        record.createdAt,
      );
  }

  removePending(permissionId: string): void {
    this.db.prepare("DELETE FROM pending_permissions WHERE permission_id = ?").run(permissionId);
  }

  listPending(): PendingPermissionRecord[] {
    const rows = this.db
      .prepare("SELECT * FROM pending_permissions ORDER BY created_at ASC")
      .all() as Array<Record<string, unknown>>;
    return rows.map((row) => ({
      permissionId: String(row.permission_id),
      bootId: String(row.boot_id),
      sessionId: String(row.session_id),
      requestId: String(row.request_id),
      payload: JSON.parse(String(row.payload)) as unknown,
      createdAt: Number(row.created_at),
    }));
  }

  /**
   * Called at startup: requests from a previous daemon boot can no longer be
   * answered. Delete them and return the records so the caller can emit
   * permission.resolved {source: "daemon_restart"} events.
   */
  drainStalePending(currentBootId: string): PendingPermissionRecord[] {
    const rows = this.db
      .prepare("SELECT * FROM pending_permissions WHERE boot_id != ?")
      .all(currentBootId) as Array<Record<string, unknown>>;
    this.db.prepare("DELETE FROM pending_permissions WHERE boot_id != ?").run(currentBootId);
    return rows.map((row) => ({
      permissionId: String(row.permission_id),
      bootId: String(row.boot_id),
      sessionId: String(row.session_id),
      requestId: String(row.request_id),
      payload: JSON.parse(String(row.payload)) as unknown,
      createdAt: Number(row.created_at),
    }));
  }

  /* ---------------- audit ---------------- */

  appendAudit(record: AuditRecord): void {
    this.db
      .prepare(
        "INSERT INTO audit (ts, session_id, tool_name, input_summary, decision, source, decided_by) VALUES (?, ?, ?, ?, ?, ?, ?)",
      )
      .run(
        Date.now(),
        record.sessionId ?? null,
        record.toolName ?? null,
        record.inputSummary ?? null,
        record.decision ?? null,
        record.source ?? null,
        record.decidedBy ?? null,
      );
  }

  close(): void {
    this.db.close();
  }
}
