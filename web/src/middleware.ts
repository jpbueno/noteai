import { NextRequest, NextResponse } from "next/server";
import {
  AUTH_COOKIE,
  isBrowserAuthConfigured,
  isExplicitAuthBypassEnabled,
  isValidProgrammaticApiKey,
  isValidSession,
} from "./lib/security";

export async function middleware(request: NextRequest) {
  const { pathname } = request.nextUrl;
  const secret = process.env.NOTEAI_AUTH_SECRET;

  if (!isBrowserAuthConfigured()) {
    if (isExplicitAuthBypassEnabled()) return NextResponse.next();
    if (pathname.startsWith("/api/auth")) return NextResponse.next();
    return pathname.startsWith("/api/")
      ? NextResponse.json({ error: "Authentication is not configured" }, { status: 503 })
      : NextResponse.next();
  }

  // Auth endpoint is always open
  if (pathname.startsWith("/api/auth")) return NextResponse.next();

  // API key auth for programmatic access (agents, scripts, etc.)
  if (pathname.startsWith("/api/")) {
    const authHeader = request.headers.get("authorization");
    if (authHeader?.startsWith("Bearer ")) {
      const token = authHeader.slice(7);
      if (await isValidProgrammaticApiKey(token)) {
        return NextResponse.next();
      }
    }
  }

  const cookie = request.cookies.get(AUTH_COOKIE)?.value;
  if (!secret) {
    return NextResponse.json({ error: "Authentication is not configured" }, { status: 503 });
  }
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
