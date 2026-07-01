# NoteAI Work Activity Intelligence

Reusable source-ingestion and task-intelligence library for NoteAI.

This package provides a small CLI and Python facade for collecting NoteAI work activity, extracting JP-owned task candidates, deduplicating them, and formatting daily summaries for assistant and automation workflows.

## Commands

```bash
python3 -m tools.work_activity daily-summary --date today --timezone America/New_York
python3 -m tools.work_activity daily-summary --date 2026-07-01 --noteai-db "/Users/jbuenosantan/Library/Application Support/NoteAI/meetings.sqlite"
python3 -m tools.work_activity daily-summary --date today --send-slack --slack-user-id U1234567890
```

`daily-summary` reads the local NoteAI database through `NoteAILocalConnector`, extracts task candidates, deduplicates them, and prints Markdown. Slack delivery is opt-in and requires an explicit `--slack-user-id`.

## Library Facade

Use `tools.work_activity.assistant_queries` for assistant-facing workflows:

- `get_open_tasks(date_range, activity_items)`
- `get_daily_task_summary(date_range, activity_items, unavailable_sources=None)`
- `get_t5t_ready_tasks(date_range, activity_items)`
- `get_projects_worked_on(date_range, activity_items)`

## Security

- Source credentials stay behind existing source CLIs and are not stored by this package.
- NoteAI SQLite is opened read-only with SQLite URI `mode=ro`.
- External source bodies are not cached by default.
- Slack write behavior is limited to an explicit `--send-slack` request with an explicit recipient.
- `--dry-run` never sends Slack messages, even when `--send-slack` is also present.

## Testing

```bash
python3 -m unittest discover -s tools/work_activity/tests -v
```

## Current Scope

This slice wires NoteAI local activity into the daily summary path and defines seams for external source health checks and Slack delivery. Live Outlook, Slack, Teams, and Google Drive ingestion remain future integration slices.
