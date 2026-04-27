import { NextRequest, NextResponse } from "next/server";
import {
  AUTH_COOKIE,
  isBrowserAuthConfigured,
  isExplicitAuthBypassEnabled,
  isValidProgrammaticApiKey,
  isValidSession,
} from "./security";

export async function requireApiAuth(request: NextRequest): Promise<NextResponse | null> {
  if (!isBrowserAuthConfigured()) {
    if (isExplicitAuthBypassEnabled()) return null;
    return NextResponse.json({ error: "Authentication is not configured" }, { status: 503 });
  }

  const authHeader = request.headers.get("authorization");
  if (authHeader?.startsWith("Bearer ")) {
    const token = authHeader.slice(7);
    if (await isValidProgrammaticApiKey(token)) return null;
  }

  const secret = process.env.NOTEAI_AUTH_SECRET;
  if (!secret) {
    return NextResponse.json({ error: "Authentication is not configured" }, { status: 503 });
  }

  const cookie = request.cookies.get(AUTH_COOKIE)?.value;
  const isAuthed = cookie ? await isValidSession(cookie, secret) : false;
  if (!isAuthed) {
    return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  }

  return null;
}
