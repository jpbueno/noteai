import { NextResponse } from "next/server";
import { verifyAccess, GoogleDocsConfigError, GoogleDocsApiError } from "@/lib/google-docs";

// GET /api/integrations/google-docs/verify
// Read-only connectivity check. Resolves the service-account credentials,
// mints an access token, and fetches the target doc's metadata. Does NOT
// write. Use this to confirm setup after rotating the service account key
// or doc sharing.
export async function GET() {
  try {
    const info = await verifyAccess();
    return NextResponse.json({ ok: true, ...info });
  } catch (err) {
    if (err instanceof GoogleDocsConfigError) {
      return NextResponse.json(
        { ok: false, error: "Not configured", detail: err.message },
        { status: 503 }
      );
    }
    if (err instanceof GoogleDocsApiError) {
      return NextResponse.json(
        { ok: false, error: "Google Docs API error", detail: err.message },
        { status: 502 }
      );
    }
    const msg = err instanceof Error ? err.message : "Unknown error";
    return NextResponse.json({ ok: false, error: "Verify failed", detail: msg }, { status: 500 });
  }
}
