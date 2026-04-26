import { NextRequest, NextResponse } from "next/server";
import { getAll, upsert } from "@/lib/server-db";
import {
  appendTaskToManagerDoc,
  GoogleDocsApiError,
  GoogleDocsConfigError,
} from "@/lib/google-docs";

interface BackfillBody {
  // ISO date (YYYY-MM-DD) — only todos with createdDate strictly after this are synced.
  // Default: 2026-03-13 (the last entry already present in the manager's doc).
  since?: string;
  // When true, returns the list of todos that would be synced without touching
  // the doc or the DB. Useful for sanity-checking before the real run.
  dryRun?: boolean;
}

const DEFAULT_SINCE = "2026-03-13";

interface TodoRow {
  id: string;
  title: string;
  description: string;
  createdDate: string;
  syncedToGoogleDocs?: number;
  googleDocsSyncedAt?: string | null;
}

// POST /api/integrations/google-docs/backfill
// Body: { since?: "YYYY-MM-DD", dryRun?: boolean }
//
// Iterates todos created after `since`, oldest-first, and appends each to the
// manager's doc under a date-header matching its createdDate. The helper's
// planInsertion() places each section in the correct chronological slot
// between existing headers, so the doc stays roughly newest-first.
//
// Errors on individual todos do NOT abort the batch — the response includes a
// per-todo result list so you can retry just the failed ones (flipping their
// syncedToGoogleDocs flag back to 0 if needed).
export async function POST(request: NextRequest) {
  let body: BackfillBody = {};
  try {
    const parsed = await request.json();
    if (parsed && typeof parsed === "object") body = parsed as BackfillBody;
  } catch {
    // empty body is fine
  }

  const since = body.since || DEFAULT_SINCE;
  const dryRun = Boolean(body.dryRun);

  const allRaw = await getAll("todos");
  const all = allRaw as unknown as TodoRow[];

  const eligible = all
    .filter((t) => {
      const title = (t.title ?? "").trim();
      if (!title) return false;
      if (Number(t.syncedToGoogleDocs ?? 0) === 1) return false;
      const created = (t.createdDate ?? "").slice(0, 10);
      return created > since;
    })
    .sort((a, b) => (a.createdDate ?? "").localeCompare(b.createdDate ?? ""));

  if (dryRun) {
    return NextResponse.json({
      ok: true,
      dryRun: true,
      since,
      count: eligible.length,
      todos: eligible.map((t) => ({
        id: t.id,
        title: t.title,
        createdDate: t.createdDate,
        description: (t.description ?? "").slice(0, 200),
      })),
    });
  }

  interface ResultRow {
    id: string;
    title: string;
    createdDate: string;
    ok: boolean;
    error?: string;
  }
  const results: ResultRow[] = [];
  let synced = 0;
  let failed = 0;

  for (const todo of eligible) {
    try {
      const created = new Date(todo.createdDate);
      if (Number.isNaN(created.getTime())) {
        throw new Error(`Invalid createdDate: ${todo.createdDate}`);
      }
      await appendTaskToManagerDoc(todo.title, {
        now: created,
        description: todo.description,
      });
      const syncedAt = new Date().toISOString();
      await upsert("todos", {
        id: todo.id,
        syncedToGoogleDocs: 1,
        googleDocsSyncedAt: syncedAt,
      });
      results.push({ id: todo.id, title: todo.title, createdDate: todo.createdDate, ok: true });
      synced++;
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      results.push({
        id: todo.id,
        title: todo.title,
        createdDate: todo.createdDate,
        ok: false,
        error: msg,
      });
      failed++;
      // If it's a config error, no point continuing — remaining calls will fail the same way.
      if (err instanceof GoogleDocsConfigError) break;
      // Rate-limit / transient API error: keep going; the per-todo flag protects us from duplicates.
      if (err instanceof GoogleDocsApiError && err.status === 429) {
        // Simple backoff so we don't hammer on retries.
        await new Promise((r) => setTimeout(r, 1500));
      }
    }
  }

  return NextResponse.json({
    ok: failed === 0,
    since,
    processed: results.length,
    synced,
    failed,
    results,
  });
}
