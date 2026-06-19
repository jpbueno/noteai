# NoteAI Storage Source of Truth

This document is the storage rule for Codex agents and app-agent work in NoteAI.

## Current Storage Adapters

NoteAI currently has two valid persistence adapters:

| Surface | Adapter | Interface | Notes |
| --- | --- | --- | --- |
| macOS native app | Local GRDB-backed SQLite | `NoteAI/Storage/MeetingStore.swift` and repository protocols in `NoteAI/Storage/Repositories.swift` | Correct native app storage until a deliberate cloud-sync migration replaces it. |
| Web/cloud app | Turso HTTP API | `web/src/lib/server-db.ts`, API routes, and `web/src/lib/db.ts` | Turso is hosted SQLite/libSQL. It is the correct web/cloud storage adapter. |

The word "SQLite" is ambiguous in this project. The macOS app uses a local SQLite file. Turso is also SQLite-compatible hosted storage. When discussing storage, specify either `macOS local GRDB store` or `web/cloud Turso store`.

## Approved Write Paths

Codex and NoteAI features must write through application interfaces, not directly into data files or database consoles:

- macOS meetings, notes, tasks, todos, T5T reports, settings-like app data: use `MeetingStore` or the repository protocols built on top of it.
- Web meetings, notes, tasks, todos, T5T reports, daily logs, chat messages, settings: use `web/src/lib/db.ts`, `/api/data/*`, or `/api/settings`.
- Tests may use test stores, fixtures, or temporary databases scoped to the test process.

## Prohibited Direct Writes

Do not directly edit or insert user data into:

- `~/Library/Application Support/NoteAI/*.sqlite`
- Any checked-in or generated `.sqlite`, `.db`, `.sqlite3`, or WAL/SHM file
- Turso production, preview, or local fallback tables through ad hoc scripts
- Raw SQL consoles, `sqlite3`, `turso db shell`, or one-off HTTP calls

Exception: a user explicitly requests a data repair, import, export, or migration. That work must include:

- A backup/export before mutation
- A dry-run or preview when feasible
- A narrow Linear issue
- Verification that record counts and representative records match expectations
- A rollback note or accepted risk

## Profile-Backed Settings

Google login establishes identity. It does not automatically make macOS data cloud-backed.

Until a cloud-sync module exists, profile-aware settings must not be simulated by writing native app data into Turso. A real profile-backed storage migration needs a design that defines:

- Which entities sync across devices
- Conflict resolution
- Offline behavior
- Secret and API-key handling
- Migration from existing local GRDB data
- User-visible backup/restore behavior

## Architecture Rule

Treat storage as a seam with two concrete adapters:

- `MeetingStore` is the native-app adapter.
- `server-db.ts`/API routes are the web-cloud adapter.

Do not add a third persistence adapter or bypass these adapters without a Linear issue and an explicit architecture decision.
