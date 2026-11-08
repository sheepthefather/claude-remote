import crypto from "node:crypto";
import fs from "node:fs/promises";
import path from "node:path";
import type {
  CanUseTool,
  Query,
  SDKMessage,
  SDKUserMessage,
} from "@anthropic-ai/claude-agent-sdk";
import type { Config } from "../config.js";
import type { PermissionMode } from "../protocol/messages.js";
import type { SessionRecord, SessionStatus } from "../store/event-store.js";
import { AsyncQueue } from "../util/async-queue.js";
import { sanitizeFileName } from "../util/files.js";
import type { Logger } from "../util/logger.js";
import { createSdkQuery } from "./sdk-adapter.js";

export interface AttachmentRef {
  id: string;
  name: string;
  mime: string;
  size: number;
}

export interface Run {
  runId: string;
  clientMsgId: string;
  userMessageUuid: string;
}

export interface SessionDeps {
  record: SessionRecord;
  config: Config;
  canUseTool: CanUseTool;
  emit: (type: string, payload: unknown, durable?: boolean) => void;
  onSdkSessionId: (id: string) => void;
  onStatus: (status: SessionStatus) => void;
  onPermissionMode: (mode: PermissionMode) => void;
  onEnded: () => void;
  logger: Logger;
}

interface StreamBlock {
  type: "text" | "thinking";
  text: string;}

interface StreamBuffer {
  blocks: Map<number, StreamBlock>;
}

function normalizeToolResult(content: unknown): { text: string; truncated: boolean } {
  let text: string;
  if (typeof content === "string") {
    text = content;
  } else if (Array.isArray(content)) {
    text = content
      .map((block) =>
        block && typeof block === "object" && (block as { type?: string }).type === "text"
          ? String((block as { text?: unknown }).text ?? "")
          : "",
      )
      .filter(Boolean)
      .join("\n");
  } else {
    try {
      text = JSON.stringify(content ?? null);
    } catch {
      text = "[unserializable tool result]";
    }
  }
  const max = 100_000;
  return { text: text.length > max ? text.slice(0, max) : text, truncated: text.length > max };
}

async function buildUserContent(
  text: string,
  attachments: AttachmentRef[],
  cwd: string,
  attachmentsDir: string,
  maxAttachmentBytes: number,
): Promise<string | Array<Record<string, unknown>>> {
  if (attachments.length === 0) return text;

  const blocks: Array<Record<string, unknown>> = [];
  const notes: string[] = [];
  if (text.trim().length > 0) blocks.push({ type: "text", text });

  for (const attachment of attachments) {
    const filePath = path.join(attachmentsDir, attachment.id, sanitizeFileName(attachment.name));
    const data = await fs.readFile(filePath);
    if (data.length > maxAttachmentBytes) {
      throw new Error(`附件过大：${attachment.name}`);
    }

    if (attachment.mime.startsWith("image/")) {
      blocks.push({
        type: "image",
        source: {
          type: "base64",
          media_type: attachment.mime,
          data: data.toString("base64"),
        },
      });
    } else if (attachment.mime === "application/pdf") {
      blocks.push({
        type: "document",
        source: {
          type: "base64",
          media_type: "application/pdf",
          data: data.toString("base64"),
        },
      });
    } else {
      const destDir = path.join(cwd, ".claude-remote", "attachments");
      await fs.mkdir(destDir, { recursive: true });
      const dest = path.join(destDir, sanitizeFileName(attachment.name));
      await fs.writeFile(dest, data);
      notes.push(`附件已保存到：${dest}`);
    }
  }

  if (notes.length > 0) blocks.push({ type: "text", text: notes.join("\n") });
  return blocks;
}

const PERMISSION_MODES: ReadonlySet<string> = new Set([
  "default",
  "plan",
  "acceptEdits",
  "auto",
  "bypassPermissions",
]);

function asPermissionMode(value: unknown): PermissionMode | undefined {
  return typeof value === "string" && PERMISSION_MODES.has(value)
    ? (value as PermissionMode)
    : undefined;
}

export class Session {
  readonly id: string;
  lastActiveAt: number;
  private readonly input = new AsyncQueue<SDKUserMessage>();
  private readonly abortController = new AbortController();
  private readonly query: Query;
  private readonly consumer: Promise<void>;
  private readonly runs = new Map<string, Run>();
  private runQueue: string[] = [];
  private currentRunId: string | null = null;
  private currentMsgId: string | null = null;
  private readonly stream = new Map<string, StreamBuffer>();
  private readonly completedMessages = new Set<string>();
  private readonly emittedToolUses = new Set<string>();
  private closed = false;

  constructor(private readonly deps: SessionDeps) {
    this.id = deps.record.id;
    this.lastActiveAt = Date.now();
    this.query = createSdkQuery(
      {
        prompt: this.input,
        cwd: deps.record.cwd,
        permissionMode: deps.record.permissionMode,
        resume: deps.record.sdkSessionId ?? undefined,
        title: deps.record.title,
        canUseTool: deps.canUseTool,
        abortController: this.abortController,
      },
      deps.config,
    );
    this.consumer = this.consume();
  }

  async sendPrompt(params: {
    text: string;
    attachments: AttachmentRef[];
    clientMsgId: string;
  }): Promise<Run> {
    if (this.closed) throw new Error("会话已关闭");
    if (params.text.trim().length === 0 && params.attachments.length === 0) {
      throw new Error("消息内容为空");
    }

    const uuid = crypto.randomUUID();
    const content = await buildUserContent(
      params.text,
      params.attachments,
      this.deps.record.cwd,
      this.deps.config.attachmentsDir,
      this.deps.config.maxAttachmentBytes,
    );

    const userMessage = {
      type: "user",
      uuid,
      message: { role: "user", content },
      parent_tool_use_id: null,
      origin: { kind: "human" },
    } as unknown as SDKUserMessage;

    const run: Run = {
      runId: `run_${crypto.randomUUID()}`,
      clientMsgId: params.clientMsgId,
      userMessageUuid: uuid,
    };
    this.runs.set(uuid, run);
    this.runQueue.push(uuid);
    if (!this.currentRunId) this.currentRunId = run.runId;

    this.deps.emit(
      "user.message",
      {
        runId: run.runId,
        clientMsgId: run.clientMsgId,
        text: params.text,
        attachments: params.attachments,
        ts: Date.now(),
      },
      true,
    );
    this.deps.emit(
      "run.started",
      { runId: run.runId, clientMsgId: run.clientMsgId, userMessageUuid: run.userMessageUuid },
      true,
    );
    this.input.push(userMessage);
    this.lastActiveAt = Date.now();
    this.deps.onStatus("running");
    return run;
  }

  async setPermissionMode(mode: PermissionMode): Promise<void> {
    await this.query.setPermissionMode(mode);
    this.deps.record.permissionMode = mode;
    this.deps.onPermissionMode(mode);
  }

  async interrupt(): Promise<void> {
    try {
      await this.query.interrupt();
    } catch (error) {
      this.deps.logger.warn("session.interrupt_failed", {
        sessionId: this.id,
        error: String(error),
      });
    }

    for (const run of this.runs.values()) {
      this.deps.emit("run.interrupted", { runId: run.runId, reason: "user" }, true);
    }
    this.runs.clear();
    this.runQueue = [];
    this.currentRunId = null;
    this.currentMsgId = null;
    this.stream.clear();
    this.deps.onStatus("idle");
    this.deps.emit(
      "status",
      { state: "idle", permissionMode: this.deps.record.permissionMode, compacting: false },
      false,
    );
  }

  close(): void {
    if (this.closed) return;
    this.closed = true;
    this.input.close();
    try {
      this.query.close();
    } catch {
      /* already closed */
    }
    this.abortController.abort();
  }

  /* ---------------- SDK message handling ---------------- */

  private async consume(): Promise<void> {
    try {
      for await (const message of this.query) {
        try {
          this.handle(message);
        } catch (error) {
          this.deps.logger.warn("session.handle_failed", {
            sessionId: this.id,
            error: String(error),
          });
        }
      }
    } catch (error) {
      if (!this.closed) {
        this.deps.emit(
          "error",
          {
            code: "SDK_ERROR",
            message: `Claude 进程异常：${String((error as Error)?.message ?? error)}`,
            recoverable: true,
          },
          false,
        );
      }
    } finally {
      this.deps.onEnded();
    }
  }

  private handle(message: SDKMessage): void {
    switch (message.type) {
      case "system":
        this.handleSystem(message as unknown as Record<string, unknown>);
        break;
      case "stream_event":
        this.handleStreamEvent(message as unknown as Record<string, unknown>);
        break;
      case "assistant":
        this.handleAssistant(message as unknown as Record<string, unknown>);
        break;
      case "user":
        this.handleUser(message as unknown as Record<string, unknown>);
        break;
      case "result":
        this.handleResult(message as unknown as Record<string, unknown>);
        break;
      case "tool_progress":
        this.handleToolProgress(message as unknown as Record<string, unknown>);
        break;
      default:
        this.deps.logger.debug("sdk.message.ignored", {
          sessionId: this.id,
          type: (message as { type?: string }).type,
          subtype: (message as { subtype?: string }).subtype,
        });
    }
  }

  /**
   * The CLI reports its own mode in init/status frames (e.g. after approving
   * ExitPlanMode it switches back to default). Keep the persisted record in
   * sync so reconnecting clients show the truth instead of a stale label.
   */
  private adoptPermissionMode(value: unknown): PermissionMode {
    const mode = asPermissionMode(value);
    if (!mode) return this.deps.record.permissionMode;
    if (mode !== this.deps.record.permissionMode) {
      this.deps.record.permissionMode = mode;
      this.deps.onPermissionMode(mode);
    }
    return mode;
  }

  private handleSystem(message: Record<string, unknown>): void {
    const subtype = String(message.subtype ?? "");
    switch (subtype) {
      case "init": {
        const sessionId = message.session_id;
        if (typeof sessionId === "string") this.deps.onSdkSessionId(sessionId);
        const mode = this.adoptPermissionMode(message.permissionMode);
        this.deps.emit(
          "status",
          {
            state: this.currentRunId ? "running" : "idle",
            permissionMode: mode,
            compacting: false,
            model: message.model ?? null,
          },
          false,
        );
        break;
      }
      case "status": {
        const mode = this.adoptPermissionMode(message.permissionMode);
        this.deps.emit(
          "status",
          {
            state: this.currentRunId ? "running" : "idle",
            permissionMode: mode,
            compacting: message.status === "compacting",
          },
          false,
        );
        break;
      }
      case "compact_boundary": {
        this.deps.emit("context.compacted", message.compact_metadata ?? {}, true);
        break;
      }
      case "permission_denied": {
        this.deps.emit(
          "tool.denied",
          {
            toolName: message.tool_name ?? null,
            toolUseId: message.tool_use_id ?? null,
            reason: message.decision_reason ?? null,
            source: message.decision_reason_type ?? null,
          },
          true,
        );
        break;
      }
      case "worker_shutting_down": {
        this.deps.emit(
          "error",
          { code: "WORKER_SHUTDOWN", message: "Claude worker 正在关闭", recoverable: true },
          false,
        );
        break;
      }
      default:
        this.deps.logger.debug("sdk.system.ignored", { sessionId: this.id, subtype });
    }
  }

  private handleStreamEvent(message: Record<string, unknown>): void {
    const event = message.event as Record<string, unknown> | undefined;
    if (!event || typeof event.type !== "string") return;
    const index = typeof event.index === "number" ? event.index : 0;

    switch (event.type) {
      case "message_start": {
        const inner = event.message as Record<string, unknown> | undefined;
        const id = inner && typeof inner.id === "string" ? inner.id : undefined;
        if (id) {
          this.currentMsgId = id;
          this.stream.set(id, { blocks: new Map() });
        }
        break;
      }
      case "content_block_start": {
        const block = event.content_block as Record<string, unknown> | undefined;
        if (!block) break;
        if (block.type === "text" || block.type === "thinking") {
          const id = this.currentMsgId;
          if (!id) break;
          const buffer = this.stream.get(id) ?? { blocks: new Map<number, StreamBlock>() };
          if (!buffer.blocks.has(index)) {
            buffer.blocks.set(index, { type: block.type, text: "" });
          }
          this.stream.set(id, buffer);
        }
        break;
      }
      case "content_block_delta": {
        const delta = event.delta as Record<string, unknown> | undefined;
        const id = this.currentMsgId;
        if (!delta || !id) break;
        let buffer = this.stream.get(id);
        if (!buffer) {
          buffer = { blocks: new Map() };
          this.stream.set(id, buffer);
        }

        if (delta.type === "text_delta" && typeof delta.text === "string") {
          let block = buffer.blocks.get(index);
          if (!block || block.type !== "text") {
            block = { type: "text", text: "" };
            buffer.blocks.set(index, block);
          }
          block.text += delta.text;
          this.deps.emit(
            "message.delta",
            {
              runId: this.currentRunId ?? "run_unknown",
              msgId: id,
              blockIndex: index,
              text: delta.text,
            },
            false,
          );
        } else if (delta.type === "thinking_delta" && typeof delta.thinking === "string") {
          let block = buffer.blocks.get(index);
          if (!block || block.type !== "thinking") {
            block = { type: "thinking", text: "" };
            buffer.blocks.set(index, block);
          }
          block.text += delta.thinking;
          this.deps.emit(
            "message.delta",
            {
              runId: this.currentRunId ?? "run_unknown",
              msgId: id,
              blockIndex: index,
              text: delta.thinking,
              kind: "thinking",
            },
            false,
          );
        }
        break;
      }
      case "message_stop": {
        if (this.currentMsgId) this.completeStreamMessage(this.currentMsgId);
        this.currentMsgId = null;
        break;
      }
      default:
        break;
    }
  }

  private completeStreamMessage(msgId: string): void {
    const buffer = this.stream.get(msgId);
    this.stream.delete(msgId);
    if (!buffer || buffer.blocks.size === 0) return;

    const blocks = [...buffer.blocks.entries()]
      .sort((a, b) => a[0] - b[0])
      .map(([, block]) =>
        block.type === "text"
          ? { type: "text", text: block.text }
          : { type: "thinking", thinking: block.text },
      );

    this.deps.emit(
      "message.completed",
      { runId: this.currentRunId ?? "run_unknown", msgId, blocks },
      true,
    );
    this.remember(this.completedMessages, msgId);
  }

  private handleAssistant(message: Record<string, unknown>): void {
    const inner = message.message as Record<string, unknown> | undefined;
    const content = inner?.content;
    const msgId = inner && typeof inner.id === "string" ? inner.id : undefined;
    const runId = this.runIdFor(message);
    const parentToolUseId =
      typeof message.parent_tool_use_id === "string" ? message.parent_tool_use_id : null;

    if (!Array.isArray(content)) return;

    const textBlocks: Array<Record<string, unknown>> = [];
    for (const block of content as Array<Record<string, unknown>>) {
      if (block.type === "tool_use") {
        const toolUseId = String(block.id ?? "");
        if (!toolUseId || this.emittedToolUses.has(toolUseId)) continue;
        this.deps.emit(
          "tool.use",
          {
            runId,
            toolUseId,
            name: block.name ?? "unknown",
            input: block.input ?? {},
            parentToolUseId,
            agentId: parentToolUseId,
          },
          true,
        );
        this.remember(this.emittedToolUses, toolUseId);
      } else if (block.type === "text" && typeof block.text === "string") {
        textBlocks.push({ type: "text", text: block.text });
      } else if (block.type === "thinking" && typeof block.thinking === "string") {
        textBlocks.push({ type: "thinking", thinking: block.thinking });
      }
    }

    if (textBlocks.length === 0) return;
    if (msgId && this.stream.has(msgId)) return;
    if (msgId && this.completedMessages.has(msgId)) return;

    const completedMsgId = msgId ?? `msg_${crypto.randomUUID()}`;
    this.deps.emit(
      "message.completed",
      { runId, msgId: completedMsgId, blocks: textBlocks, parentToolUseId },
      true,
    );
    this.remember(this.completedMessages, completedMsgId);
  }

  private handleUser(message: Record<string, unknown>): void {
    const inner = message.message as Record<string, unknown> | undefined;
    const content = inner?.content;
    if (!Array.isArray(content)) return;

    for (const block of content as Array<Record<string, unknown>>) {
      if (block.type !== "tool_result") continue;
      const normalized = normalizeToolResult(block.content);
      this.deps.emit(
        "tool.result",
        {
          runId: this.currentRunId ?? "run_unknown",
          toolUseId: block.tool_use_id ?? null,
          isError: Boolean(block.is_error),
          content: normalized.text,
          truncated: normalized.truncated,
          structured: message.tool_use_result ?? null,
        },
        true,
      );
    }
  }

  private handleResult(message: Record<string, unknown>): void {
    const uuid =
      typeof message.user_message_uuid === "string" ? message.user_message_uuid : undefined;
    const run = uuid ? this.runs.get(uuid) : undefined;
    const runId = run?.runId ?? this.currentRunId ?? `run_${crypto.randomUUID()}`;

    const payload: Record<string, unknown> = {
      runId,
      subtype: message.subtype ?? "unknown",
      result: typeof message.result === "string" ? message.result : undefined,
      totalCostUsd: message.total_cost_usd ?? 0,
      usage: message.usage ?? null,
      modelUsage: message.modelUsage ?? null,
      permissionDenials: message.permission_denials ?? [],
      terminalReason: message.terminal_reason ?? null,
      errors: message.errors ?? [],
      numTurns: message.num_turns ?? 0,
      durationMs: message.duration_ms ?? 0,
      isError: Boolean(message.is_error),
    };
    this.deps.emit("run.result", payload, true);

    if (run && uuid) {
      this.runs.delete(uuid);
      this.runQueue = this.runQueue.filter((item) => item !== uuid);
    }

    const nextUuid = this.runQueue[0];
    this.currentRunId = nextUuid ? (this.runs.get(nextUuid)?.runId ?? null) : null;
    this.currentMsgId = null;
    this.stream.clear();
    this.lastActiveAt = Date.now();

    const queued = Number(message.queued_turn_count ?? 0);
    const state: SessionStatus =
      this.currentRunId || queued > 0 ? "running" : "idle";
    this.deps.onStatus(state);
    this.deps.emit(
      "status",
      { state, permissionMode: this.deps.record.permissionMode, compacting: false },
      false,
    );
  }

  private handleToolProgress(message: Record<string, unknown>): void {
    this.deps.emit(
      "tool.progress",
      {
        runId: this.currentRunId ?? "run_unknown",
        toolUseId: message.tool_use_id ?? null,
        name: message.tool_name ?? null,
        elapsedSeconds: message.elapsed_time_seconds ?? null,
        parentToolUseId: message.parent_tool_use_id ?? null,
      },
      false,
    );
  }

  private runIdFor(message: Record<string, unknown>): string {
    const uuid =
      typeof message.user_message_uuid === "string" ? message.user_message_uuid : undefined;
    if (uuid && this.runs.has(uuid)) return this.runs.get(uuid)!.runId;
    return this.currentRunId ?? "run_unknown";
  }

  private remember(set: Set<string>, value: string): void {
    set.add(value);
    if (set.size > 500) {
      const first = set.values().next().value;
      if (first !== undefined) set.delete(first);
    }
  }
}
