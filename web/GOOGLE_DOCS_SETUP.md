# Google Docs Sync — Setup

NoteAI appends every new todo (once its title is set) to a shared Google Doc — the running log your manager uses to track your work. This document covers the one-time Google Cloud setup.

## Architecture

- **Auth**: service account with JSON key. No OAuth dance in the app, no per-user consent.
- **Scope**: `https://www.googleapis.com/auth/documents` only.
- **Transport**: direct `fetch` + Web Crypto (RS256 JWT → access token). Works on Node, Vercel Functions, and Cloudflare Workers — no `googleapis` package.
- **Dedup**: each todo has `syncedToGoogleDocs` / `googleDocsSyncedAt` columns. The sync endpoint no-ops if the flag is already set.
- **Trigger**: fires from [TodoDetail.tsx](src/components/TodoDetail.tsx) on first save where the title is non-empty.

## One-time GCP setup

1. **Create (or pick) a Google Cloud project.**
   - Console: <https://console.cloud.google.com/>.
2. **Enable the Google Docs API** for that project.
   - Console → APIs & Services → Library → search "Google Docs API" → Enable.
3. **Create a service account.**
   - Console → IAM & Admin → Service accounts → Create service account.
   - Name: e.g. `noteai-docs-sync`. No roles needed (access comes from doc sharing, not IAM).
4. **Create a JSON key for the service account.**
   - Open the service account → Keys tab → Add key → Create new key → JSON.
   - A `something.json` file downloads. Keep it — it's the only copy.
5. **Share the target Google Doc with the service account.**
   - Open `https://docs.google.com/document/d/<DOC_ID>/edit`.
   - Share → add the service account's `client_email` (looks like `noteai-docs-sync@your-project.iam.gserviceaccount.com`) with **Editor** permission.
   - No email notification needed.

## Env vars

Set these in `.env.local` for dev and in Vercel (Project Settings → Env Variables) for production. See [`.env.example`](.env.example) for the full list.

```bash
# The doc ID from the URL: .../document/d/<THIS>/edit
GOOGLE_DOCS_MANAGER_DOC_ID=1vuJ0pPMXzq7TlBDweHuTNgyMghuEXuwdz3w7SI9drMg

# The full JSON key file as a single-line string. The private_key field
# contains real newlines — escape them as \n so the env var is one line.
GOOGLE_SERVICE_ACCOUNT_KEY={"type":"service_account","project_id":"...","private_key":"-----BEGIN PRIVATE KEY-----\n...\n-----END PRIVATE KEY-----\n","client_email":"noteai-docs-sync@...","...":"..."}
```

One-liner to turn a downloaded JSON key into the env var value:

```bash
cat service-account.json | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)))'
```

Paste the output as the value of `GOOGLE_SERVICE_ACCOUNT_KEY` (single line, quotes as-is).

## Verify the setup

With the dev server running:

```bash
curl -s http://localhost:3000/api/integrations/google-docs/verify | jq
```

Expected success:

```json
{ "ok": true, "documentId": "1vuJ0pPMXzq7...", "title": "JP:Brandon" }
```

Failure modes (mapped to specific status codes so you can tell them apart):

| Status | Meaning                                                                 | Fix                                                                          |
| ------ | ----------------------------------------------------------------------- | ---------------------------------------------------------------------------- |
| 503    | Missing env vars or malformed service-account JSON                      | Set `GOOGLE_DOCS_MANAGER_DOC_ID` / `GOOGLE_SERVICE_ACCOUNT_KEY` and restart. |
| 502    | Docs API rejected the call (403 from Google = doc not shared)           | Re-share the doc with the service account email as Editor.                   |
| 502    | Docs API returned 401                                                   | The JSON key was rotated / revoked. Create a new one.                        |
| 500    | Unexpected error (network, parsing)                                     | Check logs; re-check env values.                                             |

## How sync triggers fire

The flow in [TodoDetail.tsx](src/components/TodoDetail.tsx):

1. User edits a todo's title and clicks Save.
2. `db.todos.update(...)` persists the todo to Turso.
3. If the todo's `syncedToGoogleDocs` flag is 0 **and** title is non-empty, the component does a fire-and-forget `POST /api/integrations/google-docs/sync-todo` with `{ todoId }`.
4. The route:
   - Re-reads the todo from the DB.
   - Returns `{ ok: true, skipped: "already_synced" }` if the flag is already 1 (handles rapid double-saves, retries).
   - Otherwise fetches the doc, finds the top date-header, and appends the task under it (creates a new `Mon D, YYYY` section if today doesn't have one yet).
   - On success, sets `syncedToGoogleDocs=1` + `googleDocsSyncedAt=<ISO now>`.

The UI shows a subtle "Synced to Docs" chip in the todo header once this completes (second refresh tick).

## Backfill existing todos

One-shot endpoint to push every unsynced todo that was created after a given date. Default `since` is `2026-03-13` — the last dated entry already present in the manager's doc — so a plain call backfills everything newer than that.

```bash
# Dry-run first — lists what WOULD be synced, no writes.
curl -s -X POST http://localhost:3000/api/integrations/google-docs/backfill \
  -H 'Content-Type: application/json' \
  -d '{"dryRun": true}' | jq

# Real run. Processes oldest-first, places each entry under a date-header
# matching its createdDate in the correct chronological slot.
curl -s -X POST http://localhost:3000/api/integrations/google-docs/backfill \
  -H 'Content-Type: application/json' \
  -d '{}' | jq

# Custom cutoff — e.g. backfill everything in the last 7 days only.
curl -s -X POST http://localhost:3000/api/integrations/google-docs/backfill \
  -H 'Content-Type: application/json' \
  -d '{"since": "2026-04-16"}' | jq
```

Response shape:

```json
{
  "ok": true,
  "since": "2026-03-13",
  "processed": 7,
  "synced": 7,
  "failed": 0,
  "results": [
    { "id": "...", "title": "...", "createdDate": "2026-03-14T...", "ok": true },
    ...
  ]
}
```

Per-todo errors don't abort the batch. If `failed > 0`, inspect `results` for the failures, fix the root cause, and re-run — the dedup flag skips the ones already synced.

## Manual re-sync / testing

To force a resync of a single todo (e.g. after fixing a failed sync), flip the flag in Turso and save the todo again in the UI, or re-hit the backfill endpoint:

```sql
UPDATE todos SET syncedToGoogleDocs = 0, googleDocsSyncedAt = NULL WHERE id = '<todo-id>';
```

## What gets inserted

For a new todo with title `"Review Grove v0.7 release"` created on Apr 23, 2026, when the doc's topmost date header is `Apr 20, 2026`:

```text
Apr 23, 2026           ← new section header (plain paragraph)
  • Review Grove v0.7 release     ← real Google Docs bullet (BULLET_DISC_CIRCLE_SQUARE)

Apr 20, 2026           ← existing content, untouched
  • Model Optimizer Recap
  ...
```

If the topmost header is already `Apr 23, 2026`, the new bullet is appended under it and no new header is created.

## Security notes

- The service-account JSON is stored **only** in env vars — never in Turso, never in the client bundle, never logged.
- The service account has no GCP IAM roles — its only capability is whatever you share with it. Revoking access = unsharing the doc.
- To rotate: create a new key, update the env var, delete the old key in the GCP Console.
- The sync endpoint is currently unauthenticated at the HTTP layer (same as the rest of the `/api/data/*` routes). If you expose this deployment beyond yourself, put your existing auth gate in front of `/api/integrations/google-docs/*` too.
