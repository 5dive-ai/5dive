// Session signing for the UI server.
//
// Format: <base64url(payloadJSON)>.<base64url(HMAC-SHA256(payload))>
// Payload: { iat, exp }. There is only ever one logical user ("admin").
// Fixed 7-day expiry — user logs in again at the end. (Sliding expiry would
// require rewriting Set-Cookie on every authenticated response; deferred.)

import { createHmac, timingSafeEqual } from "crypto";

const SESSION_TTL_MS = 7 * 24 * 60 * 60 * 1000; // 7 days

interface SessionPayload {
  iat: number;
  exp: number;
}

function b64urlEncode(buf: Buffer | string): string {
  return Buffer.from(buf).toString("base64url");
}

function b64urlDecode(s: string): Buffer {
  return Buffer.from(s, "base64url");
}

function hmac(secret: string, data: string): Buffer {
  return createHmac("sha256", Buffer.from(secret, "base64")).update(data).digest();
}

export function signSession(secret: string, now: number = Date.now()): string {
  const payload: SessionPayload = { iat: now, exp: now + SESSION_TTL_MS };
  const payloadStr = b64urlEncode(JSON.stringify(payload));
  const sig = b64urlEncode(hmac(secret, payloadStr));
  return `${payloadStr}.${sig}`;
}

export function verifySession(secret: string, token: string, now: number = Date.now()): SessionPayload | null {
  if (!token) return null;
  const dot = token.indexOf(".");
  if (dot < 0) return null;
  const payloadStr = token.slice(0, dot);
  const sig = token.slice(dot + 1);

  let expected: Buffer;
  let provided: Buffer;
  try {
    expected = hmac(secret, payloadStr);
    provided = b64urlDecode(sig);
  } catch {
    return null;
  }
  if (expected.length !== provided.length) return null;
  if (!timingSafeEqual(expected, provided)) return null;

  let payload: SessionPayload;
  try {
    payload = JSON.parse(b64urlDecode(payloadStr).toString("utf8")) as SessionPayload;
  } catch {
    return null;
  }
  if (typeof payload.exp !== "number" || payload.exp <= now) return null;
  return payload;
}

export function parseCookies(header: string | null): Record<string, string> {
  if (!header) return {};
  const out: Record<string, string> = {};
  for (const part of header.split(";")) {
    const eq = part.indexOf("=");
    if (eq < 0) continue;
    const k = part.slice(0, eq).trim();
    const v = part.slice(eq + 1).trim();
    if (k) out[k] = decodeURIComponent(v);
  }
  return out;
}

export const SESSION_COOKIE = "5dive_session";

export function sessionCookieHeader(token: string, secure: boolean): string {
  const attrs = [
    `${SESSION_COOKIE}=${token}`,
    "HttpOnly",
    "SameSite=Strict",
    "Path=/",
    `Max-Age=${Math.floor(SESSION_TTL_MS / 1000)}`,
  ];
  if (secure) attrs.push("Secure");
  return attrs.join("; ");
}

export function clearCookieHeader(secure: boolean): string {
  const attrs = [
    `${SESSION_COOKIE}=`,
    "HttpOnly",
    "SameSite=Strict",
    "Path=/",
    "Max-Age=0",
  ];
  if (secure) attrs.push("Secure");
  return attrs.join("; ");
}

export function isRequestSecure(req: Request): boolean {
  if (new URL(req.url).protocol === "https:") return true;
  const xf = req.headers.get("x-forwarded-proto");
  if (xf && xf.toLowerCase().split(",")[0].trim() === "https") return true;
  return false;
}
