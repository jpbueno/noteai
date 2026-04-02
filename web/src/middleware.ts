import { NextRequest, NextResponse } from "next/server";

const AUTH_COOKIE = "noteai-session";

async function hmacSign(payload: string, secret: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(payload));
  return btoa(String.fromCharCode(...new Uint8Array(sig)));
}

async function isValidSession(cookie: string, secret: string): Promise<boolean> {
  const [encoded, sig] = cookie.split(".");
  if (!encoded || !sig) return false;

  const expected = await hmacSign(encoded, secret);
  if (expected !== sig) return false;

  try {
    const payload = JSON.parse(atob(encoded));
    if (payload.exp < Date.now()) return false;
    return true;
  } catch {
    return false;
  }
}

export async function middleware(request: NextRequest) {
  const { pathname } = request.nextUrl;
  const secret = process.env.NOTEAI_AUTH_SECRET;
  const clientId = process.env.GOOGLE_CLIENT_ID;

  // No auth configured → skip
  if (!secret || !clientId) return NextResponse.next();

  // Auth endpoint is always open
  if (pathname.startsWith("/api/auth")) return NextResponse.next();

  // API key auth for programmatic access (agents, scripts, etc.)
  // Derives a stable API key from NOTEAI_AUTH_SECRET via HMAC so it works
  // in the edge runtime without needing a separate env var.
  // Generate your key: run the app and GET /api/auth/apikey, or compute
  // HMAC-SHA256("noteai-api-key", NOTEAI_AUTH_SECRET) base64-encoded.
  if (pathname.startsWith("/api/") && secret) {
    const authHeader = request.headers.get("authorization");
    if (authHeader?.startsWith("Bearer ")) {
      const token = authHeader.slice(7);
      const expected = await hmacSign("noteai-api-key", secret);
      if (token === expected) {
        return NextResponse.next();
      }
    }
  }

  const cookie = request.cookies.get(AUTH_COOKIE)?.value;
  const isAuthed = cookie ? await isValidSession(cookie, secret) : false;

  // Block unauthenticated API calls
  if (pathname.startsWith("/api/") && !isAuthed) {
    return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  }

  return NextResponse.next();
}

export const config = {
  matcher: ["/((?!_next/static|_next/image|favicon.ico).*)"],
};
