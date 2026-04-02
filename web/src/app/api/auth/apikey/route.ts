import { NextRequest, NextResponse } from "next/server";
import { parseSession } from "../route";

const AUTH_COOKIE = "noteai-session";

/** Returns the derived API key for programmatic access.
 *  Only accessible to authenticated browser sessions (cookie auth). */
export async function GET(request: NextRequest) {
  const secret = process.env.NOTEAI_AUTH_SECRET;
  if (!secret) {
    return NextResponse.json({ error: "Auth not configured" }, { status: 500 });
  }

  // Must be logged in via browser to retrieve the key
  const cookie = request.cookies.get(AUTH_COOKIE)?.value;
  if (!cookie) {
    return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  }
  const session = await parseSession(cookie);
  if (!session) {
    return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  }

  // Compute the same HMAC the middleware checks
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = await crypto.subtle.sign(
    "HMAC",
    key,
    new TextEncoder().encode("noteai-api-key"),
  );
  const apiKey = btoa(String.fromCharCode(...new Uint8Array(sig)));

  return NextResponse.json({ apiKey });
}
