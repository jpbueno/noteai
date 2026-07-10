# Daily Task Approval Automation

## Purpose

This workflow reviews the previous `America/New_York` calendar day, proposes concise accomplishment tasks in JP's preferred task format, sends the proposal to JP's private Slack DM, and writes only explicitly approved items to NoteAI `Tasks`.

It never writes proposed work to `Todos`, and it never mutates NoteAI before a valid approval.

## Modules And Seams

- The **source aggregation Module** is the Codex producer automation. Its Interface is a strict candidate JSON document containing sanitized task titles, descriptions, source labels, and source health.
- The **approval Module** is `tools.work_activity.daily_task_approval`. It owns revision state, legal transitions, Slack approval-evidence validation, expiry, backups, deduplication, and transactional writes. This is the high-leverage Interface shared by both automations.
- The **Slack Adapter** is the connected Codex Slack app. The local `slack-cli` remains read-only and is not used to send approval messages.
- The **NoteAI Adapter** is the approval Module's narrow SQLite writer. It writes only to `tasks` and validates the complete expected schema before opening a transaction.

The Slack Adapter supplies the complete trimmed command text plus actor, private-DM channel, and message timestamp evidence. The approval Module enforces that evidence at its `decide` Interface and revalidates the exact approved command hash before `apply`; local persistence remains at the NoteAI seam. This improves Locality without adding a hypothetical application-wide abstraction.

## Producer

The producer runs at 8:00 AM Eastern and uses the immediately preceding Eastern calendar day. It:

1. Reads `/Users/jbuenosantan/.codex/skills/tasks/SKILL.md`.
2. Reviews bounded Slack, Outlook email, Outlook calendar, Teams, Google Doc, and NoteAI evidence for that date.
3. Infers only work JP completed or materially advanced. It does not create follow-up todos.
4. Deduplicates overlapping evidence and writes a sanitized candidate file with the strict schema documented in `tools/work_activity/README.md`.
5. Calls `stage`, then `render`.
6. Sends the rendered proposal only to Slack user `U09BXNGD81L` and records the returned private DM conversation ID (`D...`) and message timestamp with `record-delivery`.

The producer does not resend an identical delivered revision and does not replace an applied date.

## Approval Monitor

The monitor checks delivered, unapplied revisions. It accepts only an exact command authored by Slack user `U09BXNGD81L` in that user's private DM:

```text
APPROVE YYYY-MM-DD R<N>
REJECT YYYY-MM-DD R<N>
EDIT YYYY-MM-DD R<N>: <requested changes>
```

- `APPROVE` records the decision and calls `apply`.
- `REJECT` records the decision and writes nothing to NoteAI.
- `EDIT` records `needs_revision`, applies only the requested changes to the sanitized candidates, stages a new revision, and sends a new approval message. The old revision becomes stale. State persists only the command type and hash, never the raw requested changes.
- Ambiguous text, reactions, commands from other users, and stale revision numbers are ignored.
- Pending approvals expire after 48 hours and write nothing to NoteAI.

Every decision call must carry the complete trimmed Slack command and event evidence; the approval message timestamp must be strictly newer than the recorded delivery timestamp. A channel/message timestamp may be used as evidence for only one date and revision in the state directory:

```bash
python3 -m tools.work_activity.daily_task_approval decide --date 2026-07-09 --revision 1 --decision approved --actor-user-id U09BXNGD81L --channel-id D123 --approval-message-ts 1720000000.000200 --command-text 'APPROVE 2026-07-09 R1' --state-dir "$HOME/Library/Application Support/NoteAI/daily-task-approvals"
```

## Idempotency And Recovery

- One protected state file is used per source date.
- Each staged candidate receives a stable candidate ID. Unambiguous revisions preserve that ID, while same-title candidates with different descriptions receive different IDs.
- Each candidate ID produces a deterministic import key stored in SQL `source_action_item_id` and JSON `sourceActionItemID`.
- Replaying an applied revision returns the prior result.
- A retry after a database commit but before state persistence discovers the deterministic keys and does not duplicate tasks, even when NoteAI normalized the title or a user edited title, description, or status presentation fields.
- Existing legacy same-day tasks without import keys are skipped only when normalized title and description both match; changed descriptions import independently.
- Import-key identity or immutable source-provenance conflicts fail closed.
- A database-scoped owner-only lock covers backup planning and creation, the database transaction, and final state persistence. Cross-date imports therefore form a serialized backup sequence, and apply retries reuse the original persisted pre-import backup instead of snapshotting a post-import database.

## Privacy And Security

- Candidate state contains concise task output, not raw Slack messages, email bodies, transcripts, credentials, or access tokens.
- State directories are mode `0700`; state files, decision-evidence locks, database locks, and backups are mode `0600`.
- Approval is bound in code to JP's exact Slack identity, the recorded private DM channel, a newer Slack message timestamp, and the exact anchored `APPROVE` command hash. The evidence is persisted with the decision and revalidated by `apply`.
- Logs contain dates, revision numbers, source health, counts, identifiers, and error classes only.
- NoteAI schema mismatches abort before any write.

## Runtime Paths

```text
State:   ~/Library/Application Support/NoteAI/daily-task-approvals
Tasks:   ~/Library/Application Support/NoteAI/meetings.sqlite
Backups: ~/Library/Application Support/NoteAI/backups
```

## Verification

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest tools.work_activity.tests.test_daily_task_approval -v
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tools/work_activity/tests -v
swift test --filter ArchitectureModuleTests/testAppActivationRefreshesExternallyImportedTasks
swift test
```

For a smoke test, use a temporary state directory and fixture database. Do not use `decide approved` or `apply` against the live NoteAI database without an actual matching Slack approval.

## Rollback

If an approved import must be undone, stop further approval processing, identify the persisted `backupPath` on that revision (also returned in `applyResult` after a successful final state write), restore the backup while NoteAI is closed, run `PRAGMA quick_check`, and then restart NoteAI. Keep the approval state for audit and idempotency analysis.
