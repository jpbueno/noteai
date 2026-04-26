import { NextRequest, NextResponse } from "next/server";
import { parseSession } from "../route";
import { configuredApiKeyHashes } from "@/lib/security";

const AUTH_COOKIE = "noteai-session";

/** Returns programmatic API key status without disclosing secret material. */
export async function GET(request: NextRequest) {
  // Must be logged in via browser to retrieve the key
  const cookie = request.cookies.get(AUTH_COOKIE)?.value;
  if (!cookie) {
    return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  }
  const session = await parseSession(cookie);
  if (!session) {
    return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  }

  return NextResponse.json({
    configured: configuredApiKeyHashes().length > 0,
    message: "Programmatic API keys are configured with NOTEAI_API_KEY_HASHES.",
  });
}
