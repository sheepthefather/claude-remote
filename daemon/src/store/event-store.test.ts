import { afterEach, describe, expect, it } from "vitest";
import { EventStore } from "./event-store.js";

const stores: EventStore[] = [];

function makeStore(): EventStore {
  const store = new EventStore(":memory:");
  stores.push(store);
  return store;
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

describe("EventStore", () => {
  it("appends events with global ids and replays after a cursor", () => {
    const store = makeStore();
    const first = store.appendEvent("session.created", "s1", { a: 1 });
    const second = store.appendEvent("message.completed", "s1", { b: 2 });
    const third = store.appendEvent("run.result", "s2", { c: 3 });

    expect(first).toBe(1);
    expect(second).toBe(2);
    expect(third).toBe(3);
    expect(store.minEventId()).toBe(1);
    expect(store.maxEventId()).toBe(3);

    const replayed = store.eventsAfter(1, 10);
    expect(replayed.map((event) => event.eventId)).toEqual([2, 3]);
    expect(replayed[0]?.payload).toEqual({ b: 2 });

    const filtered = store.eventsAfter(0, 10, "s2");
    expect(filtered).toHaveLength(1);
    expect(filtered[0]?.eventId).toBe(3);
  });

  it("upserts and lists sessions", () => {
    const store = makeStore();
    const record = {
      id: "s1",
      title: "demo",
      cwd: "/tmp",
      permissionMode: "default" as const,
      sdkSessionId: null,
      status: "idle" as const,
      createdAt: 1,
      lastActiveAt: 1,
    };
    store.upsertSession(record);
    store.upsertSession({ ...record, status: "running", lastActiveAt: 2 });

    const listed = store.listSessions();
    expect(listed).toHaveLength(1);
    expect(listed[0]?.status).toBe("running");
    expect(listed[0]?.lastActiveAt).toBe(2);
  });

  it("stores devices and rotates tokens", () => {
    const store = makeStore();
    store.addDevice({
      id: "d1",
      name: "phone",
      tokenHash: "hash1",
      createdAt: 1,
      lastSeenAt: null,
    });
    expect(store.findDeviceByTokenHash("hash1")?.id).toBe("d1");
    expect(store.updateDeviceToken("d1", "hash2")).toBe(true);
    expect(store.findDeviceByTokenHash("hash1")).toBeUndefined();
    expect(store.findDeviceByTokenHash("hash2")?.id).toBe("d1");
    expect(store.listDevices()[0]?.name).toBe("phone");
    expect(store.revokeDevice("d1")).toBe(true);
    expect(store.findDeviceByTokenHash("hash2")).toBeUndefined();
  });

  it("drains pending permissions from previous boots", () => {
    const store = makeStore();
    store.addPending({
      permissionId: "p1",
      bootId: "old",
      sessionId: "s1",
      requestId: "r1",
      payload: { toolName: "Bash" },
      createdAt: 1,
    });
    store.addPending({
      permissionId: "p2",
      bootId: "current",
      sessionId: "s1",
      requestId: "r2",
      payload: { toolName: "Write" },
      createdAt: 2,
    });

    const stale = store.drainStalePending("current");
    expect(stale.map((item) => item.permissionId)).toEqual(["p1"]);
    expect(store.listPending().map((item) => item.permissionId)).toEqual(["p2"]);
  });
});
