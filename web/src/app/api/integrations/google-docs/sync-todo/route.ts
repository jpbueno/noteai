import { NextRequest, NextResponse } from "next/server";
import { getById, upsert } from "@/lib/server-db";
import { appendTaskToManagerDoc, GoogleDocsConfigError, GoogleDocsApiError } from "@/lib/google-docs";

interface SyncBody {
  todoId?: string;
}

// POST /api/integrations/google-docs/sync-todo
// Body: { todoId: string }
//
// Idempotent: if the todo's syncedToGoogleDocs flag is already 1, returns
// { ok: true, skipped: "already_synced" } without touching the doc. The doc
// append itself is NOT idempotent on retries between the append and the DB
// flag update, so we accept that a crashed request mid-flight could produce
// one duplicate entry. The dedup flag prevents the common case (explicit
// retry from the client, rapid edits).
export async function POST(request: NextRequest) {
  let body: SyncBody;
  try {
    body = (await request.json()) as SyncBody;
  } catch {
    return NextResponse.json({ error: "Invalid JSON body" }, { status: 400 });
  }

  const todoId = body.todoId;
  if (!todoId || typeof todoId !== "string") {
    return NextResponse.json({ error: "todoId is required" }, { status: 400 });
  }

  const todo = await getById("todos", todoId);
  if (!todo) {
    return NextResponse.json({ error: "Todo not found" }, { status: 404 });
  }

  const title = String(todo.title ?? "").trim();
  if (!title) {
    return NextResponse.json({ ok: true, skipped: "empty_title" });
  }

  if (Number(todo.syncedToGoogleDocs ?? 0) === 1) {
    return NextResponse.json({
      ok: true,
      skipped: "already_synced",
      syncedAt: todo.googleDocsSyncedAt ?? null,
    });
  }

  try {
    const description = String(todo.description ?? "").trim() || undefined;
    const result = await appendTaskToManagerDoc(title, { description });
    const syncedAt = new Date().toISOString();
    await upsert("todos", {
      id: todoId,
      syncedToGoogleDocs: 1,
      googleDocsSyncedAt: syncedAt,
    });
    return NextResponse.json({ ok: true, syncedAt, ...result });
  } catch (err) {
    if (err instanceof GoogleDocsConfigError) {
      return NextResponse.json(
        { error: "Google Docs sync not configured", detail: err.message },
        { status: 503 }
      );
    }
    if (err instanceof GoogleDocsApiError) {
      return NextResponse.json(
        { error: "Google Docs API error", detail: err.message },
        { status: 502 }
      );
    }
    const msg = err instanceof Error ? err.message : "Unknown error";
    return NextResponse.json({ error: "Sync failed", detail: msg }, { status: 500 });
  }
}
