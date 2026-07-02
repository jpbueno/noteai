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

## Slack And Teams JSON Interface

`source-status`, `source-auth`, and `source-search` are the stable subprocess interface for the native app. Each valid invocation prints one JSON object with `schemaVersion: 1`, `success`, `source`, `action`, `status`, `message`, `data`, and `metadata`.

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
