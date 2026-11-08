import { query } from "@anthropic-ai/claude-agent-sdk";
import type {
  CanUseTool,
  Query,
  SDKUserMessage,
} from "@anthropic-ai/claude-agent-sdk";
import type { Config } from "../config.js";
import type { PermissionMode } from "../protocol/messages.js";

export interface CreateQueryParams {
  prompt: AsyncIterable<SDKUserMessage>;
  cwd: string;
  permissionMode: PermissionMode;
  resume?: string;
  title?: string;
  canUseTool: CanUseTool;
  abortController: AbortController;
}

/**
 * The single place that knows the Agent SDK's option shape. Everything else
 * in the daemon talks to Query / SDKMessage through this adapter.
 */
export function createSdkQuery(params: CreateQueryParams, config: Config): Query {
  return query({
    prompt: params.prompt,
    options: {
      cwd: params.cwd,
      permissionMode: params.permissionMode,
      // Required by the SDK before a session may switch to bypassPermissions.
      // The mode itself is still gated per session (and by allowDangerousModes).
      allowDangerouslySkipPermissions: true,
      resume: params.resume,
      title: params.title,
      canUseTool: params.canUseTool,
      abortController: params.abortController,
      includePartialMessages: true,
      permissionPrompts: "host",
      settingSources: ["user", "project", "local"],
      systemPrompt: { type: "preset", preset: "claude_code" },
      maxTurns: config.maxTurns,
      maxBudgetUsd: config.maxBudgetUsd,
      ...(config.model ? { model: config.model } : {}),
      ...(config.sdkExecutable ? { pathToClaudeCodeExecutable: config.sdkExecutable } : {}),
    },
  });
}
