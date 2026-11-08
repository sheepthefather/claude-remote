import crypto from "node:crypto";
import { query } from "@anthropic-ai/claude-agent-sdk";
import type { SDKUserMessage } from "@anthropic-ai/claude-agent-sdk";

/**
 * M1 smoke test: proves the Agent SDK can start a streaming session against the
 * locally configured Anthropic-compatible gateway, emit text deltas, and invoke
 * canUseTool. Run with: npx tsx scripts/smoke.ts
 */

const userMessage = {
  type: "user",
  uuid: crypto.randomUUID(),
  message: {
    role: "user",
    content: "只回复一句话：已启动。不要调用任何工具。",
  },
  parent_tool_use_id: null,
  origin: { kind: "human" },
} as unknown as SDKUserMessage;

async function* inputStream(): AsyncGenerator<SDKUserMessage> {
  yield userMessage;
  // Keep stdin open so the CLI does not treat the session as finished.
  await new Promise<void>(() => {});
}

const timeout = setTimeout(() => {
  process.stderr.write("\nSMOKE_TIMEOUT\n");
  process.exit(1);
}, 90_000);
timeout.unref();

const q = query({
  prompt: inputStream(),
  options: {
    cwd: process.cwd(),
    permissionMode: "default",
    includePartialMessages: true,
    settingSources: ["user", "project", "local"],
    systemPrompt: { type: "preset", preset: "claude_code" },
    maxTurns: 1,
    canUseTool: async (toolName, input) => {
      process.stdout.write(
        `\n[permission] ${toolName} ${JSON.stringify(input).slice(0, 300)}\n`,
      );
      return { behavior: "deny", message: "smoke test: tools are disabled" };
    },
  },
});

let sawText = false;

for await (const message of q) {
  if (message.type === "system") {
    process.stdout.write(`\n[system] ${String((message as { subtype?: string }).subtype ?? "")}`);
  } else if (message.type === "assistant") {
    const content = (message as unknown as {
      message: { content: Array<Record<string, unknown>> };
    }).message.content;
    for (const block of content) {
      if (block.type === "text" && typeof block.text === "string") {
        process.stdout.write(`\n[assistant] ${block.text}`);
      }
    }
  } else if (message.type === "stream_event") {
    const event = (message as unknown as { event: Record<string, unknown> }).event;
    if (event.type === "content_block_delta") {
      const delta = event.delta as Record<string, unknown> | undefined;
      if (delta?.type === "text_delta" && typeof delta.text === "string") {
        sawText = true;
        process.stdout.write(delta.text);
      }
    }
  } else if (message.type === "result") {
    const result = message as unknown as Record<string, unknown>;
    process.stdout.write(
      `\n[result] ${JSON.stringify({
        subtype: result.subtype,
        costUsd: result.total_cost_usd,
        sessionId: result.session_id,
        result: result.result,
        errors: result.errors,
      })}\n`,
    );
    process.stdout.write(`\nSMOKE_OK streamText=${sawText}\n`);
    process.exit(0);
  }
}
