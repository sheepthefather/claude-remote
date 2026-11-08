import crypto from "node:crypto";
import type {
  CanUseTool,
  PermissionResult,
  PermissionUpdate,
} from "@anthropic-ai/claude-agent-sdk";
import type { PermissionDecision } from "../protocol/messages.js";
import type { EventStore } from "../store/event-store.js";
import type { Logger } from "../util/logger.js";

export type PermissionSource =
  | "phone"
  | "timeout"
  | "disconnect"
  | "daemon_restart"
  | "interrupt";

export interface DeviceActor {
  id: string;
  name: string;
}

export interface PermissionRequestPayload {
  permissionId: string;
  sessionId: string;
  requestId: string;
  toolUseID: string;
  toolName: string;
  input: Record<string, unknown>;
  title: string | null;
  displayName: string;
  description: string | null;
  decisionReason: string | null;
  blockedPath: string | null;
  mcpServer: { name: string; source: string } | null;
  defaultToNo: boolean;
  suppressAlwaysAllowRule: boolean;
  agentID: string | null;
  suggestions: PermissionUpdate[];
  expiresAt: number;
}

export interface QuestionRequestPayload {
  permissionId: string;
  sessionId: string;
  questions: unknown[];
  expiresAt: number;
}

interface PendingBase {
  permissionId: string;
  requestId: string;
  sessionId: string;
  toolUseID: string;
  input: Record<string, unknown>;
  finish: (result: PermissionResult) => void;
}

interface PendingPermission extends PendingBase {
  kind: "permission";
  toolName: string;
  suggestions: PermissionUpdate[];
  suppressAlwaysAllowRule: boolean;
}

interface PendingQuestion extends PendingBase {
  kind: "question";
}

type Pending = PendingPermission | PendingQuestion;

export interface PermissionBridgeDeps {
  bootId: string;
  timeoutMs: number;
  store: EventStore;
  emit: (type: string, sessionId: string, payload: unknown, durable?: boolean) => void;
  logger: Logger;
}

function deny(message: string, interrupt = false): PermissionResult {
  return { behavior: "deny", message, interrupt };
}

function summarizeInput(input: Record<string, unknown>): string {
  try {
    return JSON.stringify(input).slice(0, 2000);
  } catch {
    return "[unserializable input]";
  }
}

function sessionRules(suggestions: PermissionUpdate[] | undefined): PermissionUpdate[] {
  return (suggestions ?? []).filter(
    (update) => update.type === "addRules" && update.destination === "session",
  );
}

export class PermissionBridge {
  private pending = new Map<string, Pending>();

  constructor(private readonly deps: PermissionBridgeDeps) {}

  createHandler(sessionId: string): CanUseTool {
    return (toolName, input, options) => {
      const permissionId = `perm_${crypto.randomUUID()}`;
      const isQuestion = toolName === "AskUserQuestion";
      const expiresAt = Date.now() + this.deps.timeoutMs;
      const suggestions = options.suggestions ?? [];
      const suppressAlwaysAllowRule = options.suppressAlwaysAllowRule ?? false;

      return new Promise<PermissionResult>((resolve) => {
        let timer: NodeJS.Timeout | undefined;
        let onAbort: (() => void) | undefined;
        let settled = false;

        const cleanup = () => {
          if (timer) clearTimeout(timer);
          if (onAbort) options.signal.removeEventListener("abort", onAbort);
          this.pending.delete(permissionId);
        };

        const finish = (result: PermissionResult) => {
          if (settled) return;
          settled = true;
          cleanup();
          resolve(result);
        };

        const finishWithSource = (
          result: PermissionResult,
          source: PermissionSource,
          decision: string,
        ) => {
          this.deps.store.removePending(permissionId);
          this.deps.emit(
            isQuestion ? "question.resolved" : "permission.resolved",
            sessionId,
            { permissionId, decision, source },
            true,
          );
          finish(result);
        };

        if (isQuestion) {
          this.pending.set(permissionId, {
            kind: "question",
            permissionId,
            requestId: options.requestId,
            sessionId,
            toolUseID: options.toolUseID,
            input,
            finish,
          });
        } else {
          this.pending.set(permissionId, {
            kind: "permission",
            permissionId,
            requestId: options.requestId,
            sessionId,
            toolUseID: options.toolUseID,
            input,
            toolName,
            suggestions,
            suppressAlwaysAllowRule,
            finish,
          });
        }

        const pendingRecord = {
          permissionId,
          bootId: this.deps.bootId,
          sessionId,
          requestId: options.requestId,
          createdAt: Date.now(),
        };

        if (isQuestion) {
          const questions = Array.isArray(input.questions) ? input.questions : [];
          const payload: QuestionRequestPayload = {
            permissionId,
            sessionId,
            questions,
            expiresAt,
          };
          this.deps.store.addPending({ ...pendingRecord, payload });
          this.deps.emit("question.request", sessionId, payload, true);
        } else {
          const payload: PermissionRequestPayload = {
            permissionId,
            sessionId,
            requestId: options.requestId,
            toolUseID: options.toolUseID,
            toolName,
            input,
            title: options.title ?? null,
            displayName: options.displayName ?? toolName,
            description: options.description ?? null,
            decisionReason: options.decisionReason ?? null,
            blockedPath: options.blockedPath ?? null,
            mcpServer: options.mcpServer ?? null,
            defaultToNo: options.defaultToNo ?? false,
            suppressAlwaysAllowRule,
            agentID: options.agentID ?? null,
            suggestions,
            expiresAt,
          };
          this.deps.store.addPending({ ...pendingRecord, payload });
          this.deps.emit("permission.request", sessionId, payload, true);
        }

        timer = setTimeout(() => {
          const result = deny("等待超时，已自动拒绝");
          this.deps.store.appendAudit({
            sessionId,
            toolName,
            inputSummary: summarizeInput(input),
            decision: "deny",
            source: "timeout",
          });
          finishWithSource(result, "timeout", "deny");
        }, this.deps.timeoutMs);
        timer.unref?.();

        onAbort = () => {
          const result = deny("操作已中止（aborted）", true);
          this.deps.store.appendAudit({
            sessionId,
            toolName,
            inputSummary: summarizeInput(input),
            decision: "deny",
            source: "interrupt",
          });
          finishWithSource(result, "interrupt", "deny");
        };
        options.signal.addEventListener("abort", onAbort, { once: true });

        this.deps.logger.debug("permission.requested", {
          sessionId,
          permissionId,
          toolName,
          question: isQuestion,
        });
      });
    };
  }

  respond(
    permissionId: string,
    requestId: string,
    decision: PermissionDecision,
    message?: string,
    actor?: DeviceActor,
  ): boolean {
    const pending = this.pending.get(permissionId);
    if (!pending || pending.kind !== "permission") return false;
    if (pending.requestId !== requestId) return false;

    const effectiveDecision =
      decision === "allow_session" && pending.suppressAlwaysAllowRule
        ? "allow_once"
        : decision;

    let result: PermissionResult;
    if (effectiveDecision === "allow_once" || effectiveDecision === "allow_session") {
      const updatedPermissions =
        effectiveDecision === "allow_session" ? sessionRules(pending.suggestions) : [];
      result = {
        behavior: "allow",
        updatedInput: pending.input,
        ...(updatedPermissions.length > 0 ? { updatedPermissions } : {}),
      };
    } else {
      result = deny(
        message ?? "用户在手机上拒绝了该操作",
        effectiveDecision === "deny_stop",
      );
    }

    this.deps.store.removePending(permissionId);
    pending.finish(result);

    this.deps.emit(
      "permission.resolved",
      pending.sessionId,
      {
        permissionId,
        decision: effectiveDecision,
        source: "phone",
        decidedBy: actor ?? null,
      },
      true,
    );
    this.deps.store.appendAudit({
      sessionId: pending.sessionId,
      toolName: pending.toolName,
      inputSummary: summarizeInput(pending.input),
      decision: effectiveDecision,
      source: "phone",
      decidedBy: actor ? `${actor.name} (${actor.id})` : undefined,
    });
    return true;
  }

  respondQuestion(
    permissionId: string,
    answers: Record<string, string>,
    actor?: DeviceActor,
  ): boolean {
    const pending = this.pending.get(permissionId);
    if (!pending || pending.kind !== "question") return false;

    const result: PermissionResult = {
      behavior: "allow",
      updatedInput: { ...pending.input, answers },
    };

    this.deps.store.removePending(permissionId);
    pending.finish(result);

    this.deps.emit(
      "question.resolved",
      pending.sessionId,
      { permissionId, answers, decidedBy: actor ?? null },
      true,
    );
    this.deps.store.appendAudit({
      sessionId: pending.sessionId,
      toolName: "AskUserQuestion",
      inputSummary: summarizeInput(answers),
      decision: "answered",
      source: "phone",
      decidedBy: actor ? `${actor.name} (${actor.id})` : undefined,
    });
    return true;
  }

  cancelSession(sessionId: string, source: PermissionSource): void {
    for (const pending of [...this.pending.values()]) {
      if (pending.sessionId === sessionId) this.cancelOne(pending, source);
    }
  }

  cancelAll(source: PermissionSource): void {
    for (const pending of [...this.pending.values()]) {
      this.cancelOne(pending, source);
    }
  }

  hasPending(permissionId: string): boolean {
    return this.pending.has(permissionId);
  }

  private cancelOne(pending: Pending, source: PermissionSource): void {
    const result = deny("会话已中断，未执行的工具调用已取消", true);
    this.deps.store.removePending(pending.permissionId);
    pending.finish(result);
    this.deps.emit(
      pending.kind === "question" ? "question.resolved" : "permission.resolved",
      pending.sessionId,
      {
        permissionId: pending.permissionId,
        decision: "deny",
        source,
        cancelled: true,
      },
      true,
    );
  }
}
