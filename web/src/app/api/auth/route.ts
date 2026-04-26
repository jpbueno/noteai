import { NextRequest, NextResponse } from "next/server";
import { AUTH_COOKIE, constantTimeEqual, hmacSign, isBrowserAuthConfigured } from "@/lib/security";

function getSessionSecret(): string {
  return process.env.NOTEAI_AUTH_SECRET || "";
}

function getAllowedEmails(): string[] {
  const raw = process.env.GOOGLE_ALLOWED_EMAILS || "";
  return raw.split(",").map((e) => e.trim().toLowerCase()).filter(Boolean);
}

// --- Google ID token verification ---

async function verifyGoogleToken(credential: string): Promise<{ email: string; name: string; picture: string } | null> {
  const clientId = process.env.GOOGLE_CLIENT_ID;
  if (!clientId) return null;

  // Verify via Google's tokeninfo endpoint (no extra deps)
  const res = await fetch(`https://oauth2.googleapis.com/tokeninfo?id_token=${credential}`);
  if (!res.ok) return null;

  const payload = await res.json();

  // Verify audience matches our client ID
  if (payload.aud !== clientId) return null;

  // Verify issuer
  if (payload.iss !== "accounts.google.com" && payload.iss !== "https://accounts.google.com") return null;

  // Verify not expired
  if (Number(payload.exp) * 1000 < Date.now()) return null;

  // Verify email is verified
  if (payload.email_verified !== "true") return null;

  return {
    email: payload.email,
    name: payload.name || payload.email,
    picture: payload.picture || "",
  };
}

// --- Session cookie helpers ---

async function createSessionCookie(email: string, name: string, picture: string): Promise<string> {
  const payload = JSON.stringify({ email, name, picture, exp: Date.now() + 30 * 24 * 60 * 60 * 1000 });
  const encoded = btoa(payload);
  const sig = await hmacSign(encoded, getSessionSecret());
  return `${encoded}.${sig}`;
}

export async function parseSession(cookie: string): Promise<{ email: string; name: string; picture: string } | null> {
  const secret = getSessionSecret();
  if (!secret) return null;

  const [encoded, sig] = cookie.split(".");
  if (!encoded || !sig) return null;

  const expected = await hmacSign(encoded, secret);
  if (!constantTimeEqual(expected, sig)) return null;

  try {
    const payload = JSON.parse(atob(encoded));
    if (payload.exp < Date.now()) return null;

    const allowed = getAllowedEmails();
    if (allowed.length > 0 && !allowed.includes(payload.email.toLowerCase())) return null;

    return { email: payload.email, name: payload.name, picture: payload.picture };
  } catch {
    return null;
  }
}

// --- Route handlers ---

// Check auth status
export async function GET(request: NextRequest) {
  const clientId = process.env.GOOGLE_CLIENT_ID;

  if (!isBrowserAuthConfigured()) {
    return NextResponse.json(
      { authenticated: false, required: true, configured: false, error: "Auth not configured" },
      { status: 503 },
    );
  }

  const cookie = request.cookies.get(AUTH_COOKIE)?.value;
  if (!cookie) {
    return NextResponse.json({ authenticated: false, required: true, clientId });
  }

  const session = await parseSession(cookie);
  if (!session) {
    return NextResponse.json({ authenticated: false, required: true, clientId });
  }

  return NextResponse.json({
    authenticated: true,
    required: true,
    user: session,
  });
}

// Login with Google credential
export async function POST(request: NextRequest) {
  const secret = getSessionSecret();
  if (!secret) {
    return NextResponse.json({ error: "Auth not configured" }, { status: 500 });
  }

  const { credential } = await request.json();
  if (!credential) {
    return NextResponse.json({ error: "Missing credential" }, { status: 400 });
  }

  const user = await verifyGoogleToken(credential);
  if (!user) {
    return NextResponse.json({ error: "Invalid Google token" }, { status: 401 });
  }

  // Check email allowlist
  const allowed = getAllowedEmails();
  if (allowed.length > 0 && !allowed.includes(user.email.toLowerCase())) {
    return NextResponse.json({ error: "Email not authorized" }, { status: 403 });
  }

  const sessionValue = await createSessionCookie(user.email, user.name, user.picture);
  const response = NextResponse.json({ ok: true, user });

  response.cookies.set(AUTH_COOKIE, sessionValue, {
    httpOnly: true,
    secure: true,
    sameSite: "strict",
    path: "/",
    maxAge: 60 * 60 * 24 * 30, // 30 days
  });

  return response;
}

// Logout
export async function DELETE() {
  const response = NextResponse.json({ ok: true });
  response.cookies.delete(AUTH_COOKIE);
  return response;
}
