# NoteAI Storage Source of Truth

This document is the storage rule for Codex agents and app-agent work in NoteAI.

## Current Storage Adapter

The macOS app persists data in local GRDB-backed SQLite through `NoteAI/Storage/MeetingStore.swift` and the repository protocols in `NoteAI/Storage/Repositories.swift`. This remains the production storage Adapter until a deliberate cloud-sync design replaces it.

The web client and its Turso Adapter were retired in JPB-191. No remaining application Interface writes through a web API or Turso migration workflow.

## Approved Write Paths

Codex and NoteAI features must write through application Interfaces:

- Meetings, notes, tasks, todos, T5T reports, and other app data: use `MeetingStore` or the repository protocols built on top of it.
- Tests may use test stores, fixtures, or temporary databases scoped to the test process.

## Prohibited Direct Writes

Do not directly edit or insert user data into:

- `~/Library/Application Support/NoteAI/*.sqlite`
- Any checked-in or generated `.sqlite`, `.db`, `.sqlite3`, or WAL/SHM file
- Raw SQL consoles, `sqlite3`, or ad hoc database scripts

Exception: a user explicitly requests a data repair, import, export, or migration. That work must include:

- A backup/export before mutation
- A dry-run or preview when feasible
- A narrow Linear issue
- Verification that record counts and representative records match expectations
- A rollback note or accepted risk

Retirement of source code does not authorize deleting historical hosted data or changing the native database.

## Profile-Backed Settings

Google login establishes identity. It does not automatically make macOS data cloud-backed.

Until a cloud-sync Module exists, profile-aware settings must not be simulated by writing native data into an external store. A real profile-backed storage migration needs a design that defines:

- Which entities sync across devices
- Conflict resolution
- Offline behavior
- Secret and API-key handling
- Migration from existing local GRDB data
- User-visible backup/restore behavior

## Architecture Rule

`MeetingStore` is the concrete Adapter at the native repository Seam. Its Interface and Implementation preserve the Depth, Leverage, and Locality of persistence behavior inside the storage Module.

Do not add another persistence Adapter or bypass the native application Interface without a Linear issue and an explicit architecture decision.
