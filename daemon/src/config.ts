import { z } from "zod";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const RawConfigSchema = z.object({
  host: z.string().default("0.0.0.0"),
  port: z.number().int().min(1024).max(65535).default(8787),
  allowedRoots: z.array(z.string()).default([]),
  maxLiveSessions: z.number().int().min(1).max(8).default(3),
  idleReapMs: z.number().int().min(60_000).default(15 * 60_000),
  permissionTimeoutMs: z.number().int().min(30_000).default(5 * 60_000),
  pairingCodeTtlMs: z.number().int().min(60_000).default(5 * 60_000),
  maxTurns: z.number().int().min(1).default(40),
  maxBudgetUsd: z.number().min(0).default(5),
  allowDangerousModes: z.boolean().default(true),
  maxAttachmentBytes: z.number().int().min(1024).default(20 * 1024 * 1024),
  eventRetentionDays: z.number().int().min(1).default(7),
  sdkExecutable: z.string().optional(),
  model: z.string().optional(),
  logLevel: z.enum(["debug", "info", "warn", "error"]).default("info"),
});

export type RawConfig = z.infer<typeof RawConfigSchema>;

export interface Config extends RawConfig {
  configDir: string;
  dataDir: string;
  dbPath: string;
  attachmentsDir: string;
  tlsCertPath: string;
  tlsKeyPath: string;
}

function expandHome(input: string): string {
  if (input === "~") return os.homedir();
  if (input.startsWith("~/")) return path.join(os.homedir(), input.slice(2));
  return input;
}

export function configDirPath(): string {
  return process.env.CLAUDE_REMOTE_CONFIG_DIR ?? path.join(os.homedir(), ".config", "claude-remote");
}

export function dataDirPath(): string {
  return process.env.CLAUDE_REMOTE_DATA_DIR ?? path.join(os.homedir(), ".local", "share", "claude-remote");
}

export function loadConfig(overrides: Partial<RawConfig> = {}): Config {
  const configDir = configDirPath();
  const dataDir = dataDirPath();
  const configPath = path.join(configDir, "config.json");

  let fileConfig: unknown = {};
  if (fs.existsSync(configPath)) {
    try {
      fileConfig = JSON.parse(fs.readFileSync(configPath, "utf8"));
    } catch (error) {
      throw new Error(`无法读取配置文件 ${configPath}: ${(error as Error).message}`);
    }
  }

  const parsed = RawConfigSchema.parse({ ...(fileConfig as object), ...overrides });
  const roots = (parsed.allowedRoots.length > 0
    ? parsed.allowedRoots
    : [path.join(os.homedir(), "code")]
  ).map((root) => path.resolve(expandHome(root)));

  return {
    ...parsed,
    allowedRoots: roots,
    configDir,
    dataDir,
    dbPath: path.join(dataDir, "sessions.db"),
    attachmentsDir: path.join(dataDir, "attachments"),
    tlsCertPath: path.join(configDir, "tls", "cert.pem"),
    tlsKeyPath: path.join(configDir, "tls", "key.pem"),
  };
}

/**
 * Path containment check used for session cwd validation.
 * Not a security sandbox: Bash can still reach outside the workspace.
 */
export function isPathAllowed(candidate: string, roots: string[]): boolean {
  let resolved: string;
  try {
    resolved = fs.realpathSync(candidate);
  } catch {
    resolved = path.resolve(candidate);
  }

  return roots.some((root) => {
    let realRoot: string;
    try {
      realRoot = fs.realpathSync(root);
    } catch {
      realRoot = path.resolve(root);
    }
    const rel = path.relative(realRoot, resolved);
    return rel === "" || (!rel.startsWith("..") && !path.isAbsolute(rel));
  });
}

export function ensureRuntimeDirs(config: Config): void {
  fs.mkdirSync(config.configDir, { recursive: true, mode: 0o700 });
  fs.mkdirSync(path.dirname(config.tlsCertPath), { recursive: true, mode: 0o700 });
  fs.mkdirSync(config.dataDir, { recursive: true, mode: 0o700 });
  fs.mkdirSync(config.attachmentsDir, { recursive: true, mode: 0o700 });
}
