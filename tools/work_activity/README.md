# NoteAI Work Activity Intelligence

Reusable source-ingestion and task-intelligence library for NoteAI.

This package provides a small CLI and Python facade for collecting NoteAI work activity, extracting JP-owned task candidates, deduplicating them, and formatting daily summaries for assistant and automation workflows.

## Commands

```bash
python3 -m tools.work_activity daily-summary --date today --timezone America/New_York
python3 -m tools.work_activity daily-summary --date 2026-07-01 --noteai-db "/Users/jbuenosantan/Library/Application Support/NoteAI/meetings.sqlite"
python3 -m tools.work_activity daily-summary --date today --send-slack --slack-user-id U1234567890
python3 -m tools.work_activity source-status --source slack
python3 -m tools.work_activity source-auth --source teams --action login
python3 -m tools.work_activity source-search --source slack --from 2026-07-01 --to 2026-07-07 --query NoteAI --limit 50
python3 -m tools.work_activity source-search --source teams --from 2026-07-01 --to 2026-07-07 --query NoteAI --limit 50 --messages-per-chat 50
```

`daily-summary` reads the local NoteAI database through `NoteAILocalConnector`, extracts task candidates, deduplicates them, and prints Markdown. Slack delivery is opt-in and requires an explicit `--slack-user-id`.

## Approval-Gated Daily Task Import

`daily_task_approval` is the durable local seam between the previous-day Codex producer, the Slack approval automation, and NoteAI's native tasks table. Slack retrieval and delivery remain outside this module. The `decide` command requires Slack evidence and enforces JP's exact user ID (`U09BXNGD81L`), the channel recorded by `record-delivery`, and an approval message timestamp newer than the delivery timestamp.

```bash
python3 -m tools.work_activity.daily_task_approval stage --date 2026-07-09 --tasks-file /secure/candidates.json --state-dir "$HOME/Library/Application Support/NoteAI/daily-task-approvals"
python3 -m tools.work_activity.daily_task_approval render --date 2026-07-09 --state-dir "$HOME/Library/Application Support/NoteAI/daily-task-approvals"
python3 -m tools.work_activity.daily_task_approval record-delivery --date 2026-07-09 --revision 1 --channel-id D123 --message-ts 1720000000.000100 --state-dir "$HOME/Library/Application Support/NoteAI/daily-task-approvals"
python3 -m tools.work_activity.daily_task_approval decide --date 2026-07-09 --revision 1 --decision approved --actor-user-id U09BXNGD81L --channel-id D123 --approval-message-ts 1720000000.000200 --state-dir "$HOME/Library/Application Support/NoteAI/daily-task-approvals"
python3 -m tools.work_activity.daily_task_approval apply --date 2026-07-09 --revision 1 --database "$HOME/Library/Application Support/NoteAI/meetings.sqlite" --state-dir "$HOME/Library/Application Support/NoteAI/daily-task-approvals" --backup-dir "$HOME/Library/Application Support/NoteAI/backups"
python3 -m tools.work_activity.daily_task_approval expire --date 2026-07-09 --revision 1 --after-hours 24 --state-dir "$HOME/Library/Application Support/NoteAI/daily-task-approvals"
```

Candidate files use a strict schema:

```json
{
  "tasks": [
    {
      "title": "Concise title",
      "description": "Completion-focused description",
      "sources": ["Slack", "Outlook"],
      "dueDate": null,
      "priority": null
    }
  ],
  "sourceHealth": {"Slack": "available"}
}
```

State is schema-versioned, process-locked, atomically replaced, and owner-readable only. Staging assigns each normalized candidate a stable `candidateID`, preserves it across unambiguous revisions, and permits the same title when descriptions differ. `apply` requires valid persisted Slack approval evidence, plans and persists the original owner-only SQLite backup before opening the database transaction, uses `BEGIN IMMEDIATE`, and writes completed records only to `tasks`. A retry reuses that pre-import backup. Each imported task stores a deterministic candidate-based import key in both `source_action_item_id` and JSON `sourceActionItemID`; replay skips identical content and fails closed if the key is bound to different content. Legacy same-day rows without an import key are skipped only when normalized title and description both match. Work and completion timestamps use noon `America/New_York` to preserve the intended calendar day across time zones.

The protected state contains normalized candidates, candidate IDs, Slack delivery and approval references, and the backup path only. Do not place raw source evidence, Slack bodies, credentials, tokens, or secrets in candidate files or state. CLI status output omits task descriptions; `render` is the explicit Slack-ready disclosure path.

## Slack And Teams JSON Interface

`source-status`, `source-auth`, and `source-search` provide a stable JSON interface for automation and contract testing. The macOS app implements the same bounded source contract directly in Swift and launches `slack-cli` / `teams-cli` without a Python or shell dependency. Each valid harness invocation prints one JSON object with `schemaVersion: 1`, `success`, `source`, `action`, `status`, `message`, `data`, and `metadata`.

Search results are normalized under `data.items`. Each item contains only `id`, `source`, `timestamp`, `title`, `body`, `url`, `author`, and `context`. The harness does not return upstream query echoes, raw metadata, stderr, auth callbacks, or credential fields.

Slack status uses `slack-cli me --output json`. Teams status uses the standalone `teams-cli auth status --json` object and accepts only an explicit boolean `authenticated` field. Neither status path returns the upstream user profile, username, configuration, or diagnostics.

Slack search first resolves the authenticated Slack user ID, then calls page 1 with an explicit limit of at most 100 and adds these server-side filters:

```text
from:me after:<inclusive-start-date> before:<exclusive-end-date>
```

Returned Slack matches are also checked locally against that user ID and the requested date range. Matches without a valid ID, timestamp, body, or title are discarded.

Teams has no server-side search in the inspected ai-pim-utils interface. This harness performs bounded **Teams chat search**, not complete Teams history search: it resolves the authenticated username through Teams auth status, lists at most 50 chats, resolves that username to a per-chat member ID, reads at most 200 messages per chat, and returns only messages authored by that member ID. List, member, and message commands request only the fields needed by the normalized interface. The bounded chat operation stops after 60 seconds and filters dates and optional query text locally. Teams HTML message bodies are normalized to plain text. Every successful Teams chat search is partial with `channel_coverage_missing`; additional `metadata.partialReasons` report member, chat, message, result, time, or read limits that can omit coverage. A malformed auth identity fails the search, and a failed member lookup returns no unverified authors' messages.

## Library Facade

Use `tools.work_activity.assistant_queries` for assistant-facing workflows:

- `get_open_tasks(date_range, activity_items)`
- `get_daily_task_summary(date_range, activity_items, unavailable_sources=None)`
- `get_t5t_ready_tasks(date_range, activity_items)`
- `get_projects_worked_on(date_range, activity_items)`

## Security

- Source credentials stay behind existing source CLIs and are not stored by this package.
- Status and login actions invoke only ai-pim-utils commands; the package never reads ai-pim-utils credential files.
- Envelope-based JSON operations are accepted only when the process exits 0 and the response contains `success: true`. Teams auth status is validated against its standalone `authenticated` boolean contract.
- Interactive `auth login` output is never forwarded. Exit status 0 triggers an immediate machine-readable status check, and login succeeds only when that check confirms authentication.
- Subprocesses use argument arrays without a shell, with bounded runtime and combined output size. On POSIX systems, timeout and output overflow terminate the isolated subprocess group before the runner reaps the command.
- NoteAI SQLite is opened read-only with SQLite URI `mode=ro`.
- External source bodies are not cached by default.
- Slack write behavior is limited to an explicit `--send-slack` request with an explicit recipient.
- `--dry-run` never sends Slack messages, even when `--send-slack` is also present.

## Testing

```bash
python3 -m unittest discover -s tools/work_activity/tests -v
```

## Current Scope

This package supports NoteAI local activity plus live Slack message search and bounded Teams chat enumeration through ai-pim-utils. Teams channel enumeration remains a follow-up, so Teams results cannot represent complete history. A broader source-adapter refactor is intentionally deferred while the stable public commands remain unchanged. Live Outlook, calendar, meeting-artifact, and Google Drive ingestion remain future integration slices.
