import { z } from "zod";
import crypto from "node:crypto";

export const PROTOCOL_VERSION = 1;

export const PermissionDecisionSchema = z.enum([
  "allow_once",
  "allow_session",
  "deny",
  "deny_stop",
]);
export type PermissionDecision = z.infer<typeof PermissionDecisionSchema>;

export const PermissionModeSchema = z.enum([
  "default",
  "plan",
  "acceptEdits",
  "auto",
  "bypassPermissions",
]);
export type PermissionMode = z.infer<typeof PermissionModeSchema>;

const Envelope = {
  v: z.literal(PROTOCOL_VERSION),
  id: z.string().min(1),
  ts: z.number(),
  bootId: z.string().optional(),
  eventId: z.number().int().optional(),
  sessionId: z.string().optional(),
};

const ClientHelloPayload = z.object({
  protocolVersion: z.number().int(),
  deviceId: z.string().min(1),
  token: z.string().min(1),
  capabilities: z.array(z.string()).default([]),
});

const SyncRequestPayload = z.object({
  lastEventId: z.number().int().min(0),
});

const SessionCreatePayload = z.object({
  cwd: z.string().min(1),
  title: z.string().min(1).max(120).optional(),
  permissionMode: PermissionModeSchema.default("default"),
});

const SessionRefPayload = z.object({
  sessionId: z.string().min(1),
});

const SessionSetPermissionModePayload = z.object({
  sessionId: z.string().min(1),
  mode: PermissionModeSchema,
});

const DeviceRefPayload = z.object({
  deviceId: z.string().min(1),
});

const AttachmentSchema = z.object({
  id: z.string().min(1),
  name: z.string().min(1).max(255),
  mime: z.string().min(1),
  size: z.number().int().min(0),
});

const PromptSendPayload = z.object({
  sessionId: z.string().min(1),
  clientMsgId: z.string().min(1).max(120),
  text: z.string().max(100_000),
  attachments: z.array(AttachmentSchema).max(16).default([]),
});

const PermissionRespondPayload = z.object({
  permissionId: z.string().min(1),
  requestId: z.string().min(1),
  decision: PermissionDecisionSchema,
  message: z.string().max(2000).optional(),
});

const QuestionRespondPayload = z.object({
  permissionId: z.string().min(1),
  answers: z.record(z.string(), z.string().max(10_000)),
});

const PingPayload = z.object({
  nonce: z.string().min(1).max(80),
});

function message<const K extends string, T extends z.ZodTypeAny>(type: K, payload: T) {
  return z.object({
    ...Envelope,
    type: z.literal(type),
    payload,
  });
}

export const ClientMessageSchema = z.discriminatedUnion("type", [
  message("client.hello", ClientHelloPayload),
  message("sync.request", SyncRequestPayload),
  message("session.create", SessionCreatePayload),
  message("session.resume", SessionRefPayload),
  message("session.close", SessionRefPayload),
  message("session.setPermissionMode", SessionSetPermissionModePayload),
  message("devices.list", z.object({})),
  message("device.revoke", DeviceRefPayload),
  message("device.rotateToken", DeviceRefPayload),
  message("prompt.send", PromptSendPayload),
  message("run.interrupt", SessionRefPayload),
  message("permission.respond", PermissionRespondPayload),
  message("question.respond", QuestionRespondPayload),
  message("ping", PingPayload),
]);

export type ClientMessage = z.infer<typeof ClientMessageSchema>;
export type ClientHelloMessage = Extract<ClientMessage, { type: "client.hello" }>;
export type PromptSendMessage = Extract<ClientMessage, { type: "prompt.send" }>;
export type PermissionRespondMessage = Extract<ClientMessage, { type: "permission.respond" }>;

export interface OutboundMessage<T = unknown> {
  v: typeof PROTOCOL_VERSION;
  id: string;
  type: string;
  ts: number;
  bootId: string;
  eventId?: number;
  sessionId?: string;
  payload: T;
}

export function makeMessage<T>(
  bootId: string,
  type: string,
  payload: T,
  options: { sessionId?: string; eventId?: number } = {},
): OutboundMessage<T> {
  const envelope: OutboundMessage<T> = {
    v: PROTOCOL_VERSION,
    id: crypto.randomUUID(),
    type,
    ts: Date.now(),
    bootId,
    payload,
  };
  if (options.sessionId !== undefined) envelope.sessionId = options.sessionId;
  if (options.eventId !== undefined) envelope.eventId = options.eventId;
  return envelope;
}

export function parseClientMessage(raw: string): ClientMessage {
  const json = JSON.parse(raw) as unknown;
  return ClientMessageSchema.parse(json);
}
