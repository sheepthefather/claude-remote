import crypto from "node:crypto";
import https from "node:https";
import { WebSocket } from "ws";

/**
 * End-to-end protocol test against a running daemon.
 *
 *   CR_CODE=ABCD1234 npx tsx scripts/e2e.ts
 */

const CODE = process.env.CR_CODE;
const BASE = process.env.CR_BASE ?? "https://127.0.0.1:8787";
const WS_URL = process.env.CR_WS ?? "wss://127.0.0.1:8787/ws";
const CWD = process.env.CR_CWD ?? process.cwd();
const PROMPT =
  process.env.CR_PROMPT ??
  "必须使用 Bash 工具运行 pwd 命令，然后把输出告诉我。不要直接回答。";
const MODE = process.env.CR_MODE ?? "default";
const REQUIRES_PERMISSION = MODE === "default" || MODE === "plan";

if (!CODE) {
  process.stderr.write("缺少 CR_CODE 环境变量\n");
  process.exit(1);
}

function postJson(path: string, body: unknown): Promise<{ status: number; data: unknown }> {
  const url = new URL(path, BASE);
  const payload = JSON.stringify(body);
  return new Promise((resolve, reject) => {
    const req = https.request(
      {
        hostname: url.hostname,
        port: url.port,
        path: url.pathname,
        method: "POST",
        rejectUnauthorized: false,
        headers: {
          "content-type": "application/json",
          "content-length": Buffer.byteLength(payload),
        },
      },
      (res) => {
        const chunks: Buffer[] = [];
        res.on("data", (chunk: Buffer) => chunks.push(chunk));
        res.on("end", () => {
          const raw = Buffer.concat(chunks).toString("utf8");
          let data: unknown = raw;
          try {
            data = JSON.parse(raw);
          } catch {
            /* keep raw */
          }
          resolve({ status: res.statusCode ?? 0, data });
        });
      },
    );
    req.on("error", reject);
    req.end(payload);
  });
}

async function main(): Promise<void> {
  const paired = await postJson("/pair", { code: CODE, deviceName: "e2e-cli" });
  process.stdout.write(`pair: ${paired.status} ${JSON.stringify(paired.data)}\n`);
  if (paired.status !== 200) process.exit(2);

  const pairing = paired.data as { deviceId: string; token: string };
  let bootId = "";
  let sessionId = "";
  let sawPermission = false;
  let sawToolResult = false;
  let reportedMode = "";

  const ws = new WebSocket(WS_URL, { rejectUnauthorized: false });
  const timeout = setTimeout(() => {
    process.stderr.write("E2E_TIMEOUT\n");
    ws.close();
    process.exit(3);
  }, 120_000);
  timeout.unref();

  const send = (type: string, payload: unknown): void => {
    ws.send(
      JSON.stringify({
        v: 1,
        type,
        id: crypto.randomUUID(),
        ts: Date.now(),
        bootId: bootId || undefined,
        sessionId: sessionId || undefined,
        payload,
      }),
    );
  };

  ws.on("open", () => {
    process.stdout.write("ws: open\n");
    ws.send(
      JSON.stringify({
        v: 1,
        type: "client.hello",
        id: crypto.randomUUID(),
        ts: Date.now(),
        payload: {
          protocolVersion: 1,
          deviceId: pairing.deviceId,
          token: pairing.token,
          capabilities: ["interrupt", "questions", "attachments"],
        },
      }),
    );
  });

  ws.on("message", (data) => {
    const message = JSON.parse(data.toString()) as {
      type: string;
      bootId?: string;
      eventId?: number;
      sessionId?: string;
      payload?: Record<string, unknown>;
    };

    const type = message.type;
    if (type !== "message.delta" && type !== "tool.progress" && type !== "status") {
      process.stdout.write(`<< ${type}${message.eventId ? ` #${message.eventId}` : ""}\n`);
    }

    switch (type) {
      case "server.hello": {
        bootId = message.bootId ?? "";
        send("sync.request", { lastEventId: 0 });
        break;
      }
      case "sync.replay":
      case "sync.snapshot":
        break;
      case "sync.complete": {
        send("session.create", {
          cwd: CWD,
          title: "e2e smoke",
          permissionMode: MODE,
        });
        break;
      }
      case "session.created": {
        const session = message.payload?.session as { id?: string } | undefined;
        if (!session?.id) break;
        sessionId = session.id;
        process.stdout.write(`session: ${sessionId}\n`);
        send("prompt.send", {
          sessionId,
          clientMsgId: `c_${crypto.randomUUID()}`,
          text: PROMPT,
          attachments: [],
        });
        break;
      }
      case "permission.request": {
        sawPermission = true;
        const payload = message.payload ?? {};
        process.stdout.write(
          `permission: ${String(payload.toolName)} ${JSON.stringify(payload.input).slice(0, 300)}\n`,
        );
        if (process.env.CR_HOLD_PERMISSION === "1") {
          process.stdout.write("HOLDING_PERMISSION\n");
          break;
        }
        send("permission.respond", {
          permissionId: payload.permissionId,
          requestId: payload.requestId,
          decision: "allow_once",
        });
        break;
      }
      case "question.request": {
        const payload = message.payload ?? {};
        const questions = payload.questions as Array<{ question?: string }> | undefined;
        const answers: Record<string, string> = {};
        for (const question of questions ?? []) {
          if (question.question) answers[question.question] = "（e2e 自动回答）";
        }
        send("question.respond", { permissionId: payload.permissionId, answers });
        break;
      }
      case "tool.result": {
        sawToolResult = true;
        const payload = message.payload ?? {};
        process.stdout.write(
          `tool.result: ${String(payload.content).slice(0, 200)}\n`,
        );
        break;
      }
      case "message.completed": {
        const blocks = message.payload?.blocks as Array<Record<string, unknown>> | undefined;
        for (const block of blocks ?? []) {
          if (block.type === "text") process.stdout.write(`assistant: ${String(block.text)}\n`);
        }
        break;
      }
      case "session.updated": {
        const session = message.payload?.session as
          | { permissionMode?: string }
          | undefined;
        if (session?.permissionMode && session.permissionMode !== reportedMode) {
          reportedMode = session.permissionMode;
          process.stdout.write(`mode: ${reportedMode}\n`);
        }
        break;
      }
      case "run.result": {
        process.stdout.write(
          `run.result: ${JSON.stringify(message.payload).slice(0, 800)}\n`,
        );
        process.stdout.write(
          `E2E_DONE permission=${sawPermission} toolResult=${sawToolResult} mode=${MODE}\n`,
        );
        send("session.close", { sessionId });
        setTimeout(() => {
          ws.close();
          process.exit(
            sawToolResult && (!REQUIRES_PERMISSION || sawPermission) ? 0 : 4,
          );
        }, 300);
        break;
      }
      case "error": {
        process.stdout.write(`ERROR ${JSON.stringify(message.payload)}\n`);
        break;
      }
      default:
        break;
    }
  });

  ws.on("close", (code, reason) => {
    process.stdout.write(`ws: closed ${code} ${reason.toString()}\n`);
  });
  ws.on("error", (error) => {
    process.stderr.write(`ws error: ${String(error)}\n`);
  });
}

void main();
