// httpOnly session cookie for SIWE (§10.4). The cookie holds `<sessionId>.<hmac>`; the session row in
// app.siwe_session is the source of truth (logout and expiry delete it).
import { createHmac, randomBytes, randomUUID, timingSafeEqual } from "node:crypto";

export const SESSION_COOKIE = "credence_session";

export function newSessionId(): string {
  return randomUUID();
}

export function newNonce(): string {
  // SIWE nonces: alphanumeric, ≥ 8 chars (EIP-4361)
  return randomBytes(16).toString("hex");
}

function mac(secret: string, id: string): string {
  return createHmac("sha256", secret).update(id).digest("base64url");
}

export function signSession(secret: string, id: string): string {
  return `${id}.${mac(secret, id)}`;
}

export function verifySession(secret: string, value: string | undefined): string | undefined {
  if (!value) return undefined;
  const i = value.lastIndexOf(".");
  if (i <= 0) return undefined;
  const id = value.slice(0, i);
  const got = Buffer.from(value.slice(i + 1));
  const want = Buffer.from(mac(secret, id));
  return got.length === want.length && timingSafeEqual(got, want) ? id : undefined;
}
