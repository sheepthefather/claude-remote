import crypto from "node:crypto";

const CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";

export interface PairingCode {
  code: string;
  expiresAt: number;
}

export interface DeviceToken {
  token: string;
  hash: string;
}

export function createDeviceToken(): DeviceToken {
  const token = crypto.randomBytes(32).toString("base64url");
  return { token, hash: hashToken(token) };
}

export function hashToken(token: string): string {
  return crypto.createHash("sha256").update(token).digest("hex");
}

export function timingSafeEqualString(a: string, b: string): boolean {
  const left = Buffer.from(a);
  const right = Buffer.from(b);
  if (left.length !== right.length) return false;
  return crypto.timingSafeEqual(left, right);
}

export class PairingManager {
  private active: PairingCode | null = null;

  constructor(private readonly ttlMs: number) {}

  /**
   * Creates a new one-time code, invalidating any previous code.
   */
  create(): PairingCode {
    let code = "";
    for (let i = 0; i < 8; i += 1) {
      code += CODE_ALPHABET[crypto.randomInt(CODE_ALPHABET.length)];
    }
    this.active = { code, expiresAt: Date.now() + this.ttlMs };
    return this.active;
  }

  current(): PairingCode | null {
    if (this.active && this.active.expiresAt <= Date.now()) {
      this.active = null;
    }
    return this.active;
  }

  redeem(code: string): boolean {
    const active = this.current();
    if (!active) return false;
    if (!timingSafeEqualString(code.trim().toUpperCase(), active.code)) return false;
    this.active = null;
    return true;
  }
}
