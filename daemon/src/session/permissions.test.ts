import { afterEach, describe, expect, it } from "vitest";
import type { CanUseTool, PermissionUpdate } from "@anthropic-ai/claude-agent-sdk";
import { EventStore } from "../store/event-store.js";
import { createLogger } from "../util/logger.js";
import { PermissionBridge } from "./permissions.js";

const stores: EventStore[] = [];

function setup(timeoutMs = 500) {
  const store = new EventStore(":memory:");
  stores.push(store);
  const emitted: Array<{ type: string; payload: Record<string, unknown> }> = [];
  const bridge = new PermissionBridge({
    bootId: "boot",
    timeoutMs,
    store,
    emit: (type, _sessionId, payload) => {
      emitted.push({ type, payload: payload as Record<string, unknown> });
    },
    logger: createLogger("error"),
  });
  return { store, emitted, bridge };
}

function options(controller: AbortController, requestId = "req1") {
  return {
    signal: controller.signal,
    requestId,
    toolUseID: "tool1",
    suggestions: [] as PermissionUpdate[],
  };
}

afterEach(() => {
  for (const store of stores.splice(0)) {
    try {
      store.close();
    } catch {
      /* ignore */
    }
  }
});

describe("PermissionBridge", () => {
  it("allows once after the phone responds", async () => {
    const { store, emitted, bridge } = setup();
    const handler: CanUseTool = bridge.createHandler("s1");
    const controller = new AbortController();
    const promise = handler("Bash", { command: "echo hi" }, options(controller));

    const request = emitted.find((event) => event.type === "permission.request");
    expect(request).toBeDefined();
    const permissionId = String(request?.payload.permissionId);
    expect(store.listPending()).toHaveLength(1);

    expect(bridge.respond(permissionId, "req1", "allow_once")).toBe(true);
    const result = await promise;
    expect(result).toMatchObject({ behavior: "allow" });
    expect(store.listPending()).toHaveLength(0);
    expect(
      emitted.some(
        (event) =>
          event.type === "permission.resolved" &&
          event.payload.source === "phone",
      ),
    ).toBe(true);
  });

  it("only persists session-scoped addRules for allow_session", async () => {
    const { store, emitted, bridge } = setup();
    const handler = bridge.createHandler("s1");
    const controller = new AbortController();
    const suggestions: PermissionUpdate[] = [
      {
        type: "addRules",
        rules: [{ toolName: "Bash", ruleContent: "echo *" }],
        behavior: "allow",
        destination: "session",
      },
      {
        type: "addRules",
        rules: [{ toolName: "Bash", ruleContent: "rm *" }],
        behavior: "allow",
        destination: "userSettings",
      },
      {
        type: "setMode",
        mode: "acceptEdits",
        destination: "session",
      },
    ];
    const promise = handler(
      "Bash",
      { command: "echo hi" },
      { ...options(controller), suggestions },
    );
    const request = emitted.find((event) => event.type === "permission.request");
    const permissionId = String(request?.payload.permissionId);

    bridge.respond(permissionId, "req1", "allow_session");
    const result = await promise;
    expect(result.behavior).toBe("allow");
    if (result && result.behavior === "allow") {
      expect(result.updatedPermissions).toHaveLength(1);
      expect(result.updatedPermissions?.[0]?.destination).toBe("session");
      expect(result.updatedPermissions?.[0]?.type).toBe("addRules");
    }
    expect(store.listPending()).toHaveLength(0);
  });

  it("denies on timeout", async () => {
    const { emitted, bridge } = setup(30);
    const handler = bridge.createHandler("s1");
    const controller = new AbortController();
    const result = await handler("Bash", { command: "rm -rf /tmp/x" }, options(controller));
    expect(result).toMatchObject({ behavior: "deny" });
    expect(
      emitted.some(
        (event) =>
          event.type === "permission.resolved" &&
          event.payload.source === "timeout",
      ),
    ).toBe(true);
  });

  it("denies when the SDK signal aborts", async () => {
    const { bridge } = setup(5000);
    const handler = bridge.createHandler("s1");
    const controller = new AbortController();
    const promise = handler("Bash", { command: "sleep 10" }, options(controller));
    controller.abort();
    const result = await promise;
    expect(result).toMatchObject({ behavior: "deny", interrupt: true });
  });

  it("answers AskUserQuestion through updatedInput", async () => {
    const { emitted, bridge } = setup();
    const handler = bridge.createHandler("s1");
    const controller = new AbortController();
    const questions = [{ question: "税率放哪里？", options: [] }];
    const promise = handler(
      "AskUserQuestion",
      { questions },
      options(controller, "req-q"),
    );

    const request = emitted.find((event) => event.type === "question.request");
    const permissionId = String(request?.payload.permissionId);
    expect(bridge.respondQuestion(permissionId, { "税率放哪里？": "环境变量" })).toBe(true);

    const result = await promise;
    expect(result).toMatchObject({ behavior: "allow" });
    if (result && result.behavior === "allow") {
      expect(result.updatedInput).toMatchObject({
        questions,
        answers: { "税率放哪里？": "环境变量" },
      });
    }
  });
});
