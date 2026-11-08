import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFileSync } from "node:child_process";

export interface TlsMaterial {
  certPem: string;
  keyPem: string;
  /** lowercase hex SHA-256 of the DER certificate, no colons */
  fingerprintSha256: string;
}

export function listLocalIpv4(): string[] {
  const result: string[] = [];
  for (const addresses of Object.values(os.networkInterfaces())) {
    for (const address of addresses ?? []) {
      if (address.family === "IPv4" && !address.internal) result.push(address.address);
    }
  }
  return result;
}

function generateSelfSigned(certPath: string, keyPath: string): void {
  const sans = ["DNS:localhost", "IP:127.0.0.1", ...listLocalIpv4().map((ip) => `IP:${ip}`)].join(",");
  execFileSync(
    "openssl",
    [
      "req",
      "-x509",
      "-newkey",
      "ec",
      "-pkeyopt",
      "ec_paramgen_curve:prime256v1",
      "-nodes",
      "-keyout",
      keyPath,
      "-out",
      certPath,
      "-days",
      "825",
      "-subj",
      "/CN=claude-remote",
      "-addext",
      `subjectAltName=${sans}`,
    ],
    { stdio: "pipe" },
  );
  fs.chmodSync(keyPath, 0o600);
}

export function ensureTlsMaterial(certPath: string, keyPath: string): TlsMaterial {
  fs.mkdirSync(path.dirname(certPath), { recursive: true, mode: 0o700 });
  if (!fs.existsSync(certPath) || !fs.existsSync(keyPath)) {
    if (process.platform !== "linux" && process.platform !== "darwin") {
      throw new Error("自签证书生成目前只支持 openssl（Linux/macOS）");
    }
    generateSelfSigned(certPath, keyPath);
  }

  const certPem = fs.readFileSync(certPath, "utf8");
  const keyPem = fs.readFileSync(keyPath, "utf8");
  const fingerprintSha256 = new crypto.X509Certificate(certPem)
    .fingerprint256.replace(/:/g, "")
    .toLowerCase();

  return { certPem, keyPem, fingerprintSha256 };
}
