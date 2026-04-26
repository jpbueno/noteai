export const AUTH_COOKIE = "noteai-session";

type Env = Record<string, string | undefined>;

function envValue(env: Env, key: string): string {
  return env[key]?.trim() || "";
}

function toBase64(bytes: ArrayBuffer): string {
  return btoa(String.fromCharCode(...new Uint8Array(bytes)));
}

export function isExplicitAuthBypassEnabled(env: Env = process.env): boolean {
  return envValue(env, "NOTEAI_DISABLE_AUTH") === "true" && envValue(env, "NODE_ENV") !== "production";
}

export function isBrowserAuthConfigured(env: Env = process.env): boolean {
  return Boolean(envValue(env, "NOTEAI_AUTH_SECRET") && envValue(env, "GOOGLE_CLIENT_ID"));
}

export async function hmacSign(payload: string, secret: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(payload));
  return toBase64(sig);
}

export function constantTimeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) {
    diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  }
  return diff === 0;
}

async function sha256Base64(value: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return toBase64(digest);
}

export function configuredApiKeyHashes(env: Env = process.env): string[] {
  return envValue(env, "NOTEAI_API_KEY_HASHES")
    .split(",")
    .map((hash) => hash.trim())
    .filter(Boolean);
}

export async function isValidProgrammaticApiKey(token: string, env: Env = process.env): Promise<boolean> {
  const hashes = configuredApiKeyHashes(env);
  if (hashes.length === 0) return false;
  const actual = await sha256Base64(token);
  return hashes.some((expected) => constantTimeEqual(actual, expected));
}

export async function isValidSession(cookie: string, secret: string): Promise<boolean> {
  const [encoded, sig] = cookie.split(".");
  if (!encoded || !sig) return false;

  const expected = await hmacSign(encoded, secret);
  if (!constantTimeEqual(expected, sig)) return false;

  try {
    const payload = JSON.parse(atob(encoded));
    if (payload.exp < Date.now()) return false;
    return true;
  } catch {
    return false;
  }
}
