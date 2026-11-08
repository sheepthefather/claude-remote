import { describe, expect, it } from "vitest";
import { makeMessage, parseClientMessage } from "./messages.js";

describe("protocol messages", () => {
  it("parses client.hello and applies defaults", () => {
    const message = parseClientMessage(
      JSON.stringify({
        v: 1,
        type: "client.hello",
        id: "m1",
        ts: 1,
        payload: { protocolVersion: 1, deviceId: "dev", token: "tok" },
      }),
    );
    expect(message.type).toBe("client.hello");
    if (message.type === "client.hello") {
      expect(message.payload.capabilities).toEqual([]);
    }
  });

  it("applies prompt defaults", () => {
    const message = parseClientMessage(
      JSON.stringify({
        v: 1,
        type: "prompt.send",
        id: "m2",
        ts: 1,
        payload: {
          sessionId: "s1",
          clientMsgId: "c1",
          text: "hi",
        },
      }),
    );
    expect(message.type).toBe("prompt.send");
    if (message.type === "prompt.send") {
      expect(message.payload.attachments).toEqual([]);
    }
  });

  it("rejects unknown permission decisions", () => {
    expect(() =>
      parseClientMessage(
        JSON.stringify({
          v: 1,
          type: "permission.respond",
          id: "m3",
          ts: 1,
          payload: {
            permissionId: "p1",
            requestId: "r1",
            decision: "allow_forever",
          },
        }),
      ),
    ).toThrow();
  });

  it("rejects an unsupported protocol version", () => {
    expect(() =>
      parseClientMessage(
        JSON.stringify({ v: 2, type: "ping", id: "m4", ts: 1, payload: {} }),
      ),
    ).toThrow();
  });

  it("accepts every supported permission mode", () => {
    for (const mode of [
      "default",
      "plan",
      "acceptEdits",
      "auto",
      "bypassPermissions",
    ]) {
      const message = parseClientMessage(
        JSON.stringify({
          v: 1,
          type: "session.setPermissionMode",
          id: `m_${mode}`,
          ts: 1,
          payload: { sessionId: "s1", mode },
        }),
      );
      expect(message.type).toBe("session.setPermissionMode");
      if (message.type === "session.setPermissionMode") {
        expect(message.payload.mode).toBe(mode);
      }
    }
  });

  it("rejects dontAsk, which the phone never offers", () => {
    expect(() =>
      parseClientMessage(
        JSON.stringify({
          v: 1,
          type: "session.setPermissionMode",
          id: "m_dontask",
          ts: 1,
          payload: { sessionId: "s1", mode: "dontAsk" },
        }),
      ),
    ).toThrow();
  });

  it("builds outbound envelopes with event metadata", () => {
    const message = makeMessage("boot", "session.updated", { ok: true }, {
      sessionId: "s1",
      eventId: 42,
    });
    expect(message.v).toBe(1);
    expect(message.bootId).toBe("boot");
    expect(message.sessionId).toBe("s1");
    expect(message.eventId).toBe(42);
  });
});
