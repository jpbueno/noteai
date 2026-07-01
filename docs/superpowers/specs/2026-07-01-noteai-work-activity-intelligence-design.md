# NoteAI Work Activity Intelligence Design

Date: 2026-07-01
Linear: JPB-215
Status: Draft for review

## Goal

Build a reusable source-ingestion and task-intelligence library inside the NoteAI repository. The library will let NoteAI and AI assistants answer work-activity questions and generate daily task summaries from Slack, Outlook, Microsoft Teams, Outlook Calendar, Google Docs, and NoteAI local data.

The first implementation target is a Python library and CLI under the NoteAI repo. NoteAI can later call the same library from the macOS app, scheduled automation, or developer workflows.

## Primary Use Cases

1. Interactive assistant questions:
   - Which projects did I work on this week?
   - Generate a summary for meeting X based on its Teams transcript.
   - What open tasks do I have today?
   - What did I commit to this week?

2. Daily task automation:
   - Query JP's current-day work activity using `America/New_York` day boundaries.
   - Extract JP-owned tasks, follow-ups, commitments, blockers, and action items.
   - Deduplicate overlapping items across sources.
   - Produce the required markdown daily task summary.
   - Send the same summary to JP on Slack user ID `U09BXNGD81L` when possible.

3. T5T support:
   - Produce T5T-ready task lists from the same normalized task intelligence.
   - Keep NoteAI tasks as the source of truth for T5T, but make the daily automation capable of generating task candidates from external evidence.

## Non-Goals For The First Slice

- Do not mutate the NoteAI SQLite database directly.
- Do not build a background local index of all Slack/email/Teams content.
- Do not store raw external source bodies unless the user explicitly saves generated output into NoteAI.
- Do not implement write operations for Outlook, Teams, Google Drive, or Slack beyond sending the final daily Slack DM.
- Do not replace NoteAI's existing T5T UI in the first slice.

## Source Capabilities Confirmed

The canonical `ai-pim-utils` repo is `ai-cli/ai-pim-utils`. The relevant CLIs are:

- `outlook-cli`: Outlook email search/read through Microsoft Graph.
- `calendar-cli`: Outlook calendar event search/read.
- `meeting-cli`: Teams meeting transcripts, attendance, recordings, and recap artifacts.
- `teams-cli`: Teams chat/channel list/read/search. Phase 1 uses read-only paths.
- `slack-cli`: Slack read-only search, direct/group DM history, thread context.
- `gdrive-cli`: Google Drive search, file content retrieval, and metadata.

Authentication remains owned by `ai-pim-utils`. Microsoft Graph CLIs share local state under `~/.ai-pim-utils/cache.toml`; provider-managed auth can use CLI-specific `*_ACCESS_TOKEN` environment variables. NoteAI must not read token stores directly.

## Architecture

### Module: `work_activity`

Location:

```text
tools/work_activity/
```

Public interface:

```bash
noteai-work-activity daily-summary --date today --timezone America/New_York
noteai-work-activity open-tasks --from 2026-07-01 --to 2026-07-01 --timezone America/New_York
noteai-work-activity weekly-projects --week current --timezone America/New_York
noteai-work-activity meeting-summary --title "Customer Sync"
noteai-work-activity t5t-ready --from 2026-06-17 --to 2026-07-01 --timezone America/New_York
```

Python interface:

```python
get_projects_worked_on(date_range)
summarize_meeting(meeting_id_or_title)
get_open_tasks(date_range)
get_daily_task_summary(date)
get_weekly_project_summary(week)
get_t5t_ready_tasks(date_range)
```

The command-line interface is the stable integration seam for NoteAI automation. The Python functions are the seam for tests and future direct app/helper integration.

### Module: `SourceConnectors`

Each source connector implements a common interface:

```python
query(range: DateRange, query: SourceQuery) -> SourceQueryResult
health() -> SourceHealth
```

Adapters:

- `SlackConnector`: calls `slack-cli message search`, thread/history commands, and user/DM commands as needed.
- `OutlookEmailConnector`: calls `outlook-cli message find` and `outlook-cli message read`.
- `OutlookCalendarConnector`: calls `calendar-cli find` and `calendar-cli get`.
- `TeamsMeetingConnector`: uses `calendar-cli` to find event IDs and `meeting-cli transcript read/find` for Teams transcripts.
- `GoogleDocConnector`: retrieves the configured Google Doc through Google Drive/Docs tooling and extracts entries that clearly belong to the requested date range.
- `NoteAILocalConnector`: reads `/Users/jbuenosantan/Library/Application Support/NoteAI/meetings.sqlite` tables `tasks`, `todos`, and `meetings` in read-only mode.

The connector interface is intentionally small. It gives callers leverage because all source-specific CLI flags, retries, and JSON/TOON parsing remain behind the adapter seam.

### Module: `ActivityNormalizer`

Converts source-specific records into:

```python
ActivityItem(
    source: SourceKind,
    source_id: str | None,
    timestamp: datetime | None,
    title: str,
    body: str,
    participants: list[Person],
    source_refs: list[SourceRef],
    ownership_signals: list[str],
    due_date: datetime | None,
    priority: str | None,
    status: str | None,
    project: str | None,
    raw_metadata: dict,
)
```

This keeps downstream extraction and summaries independent of Slack, Outlook, Teams, Google, or SQLite record shapes.

### Module: `TaskExtractor`

Extracts task-like items from normalized activity:

- explicit tasks
- follow-ups
- commitments
- blockers
- action items
- decisions that create follow-up work

Ownership rule:

Only include tasks clearly assigned to JP or clearly owned by JP. If ownership is ambiguous, omit the item unless context makes JP ownership clear. Do not invent tasks.

Output:

```python
TaskCandidate(
    title: str,
    description: str,
    due_date: datetime | None,
    priority: str | None,
    status: str,
    project: str | None,
    sources: list[SourceRef],
    confidence: float,
)
```

Task wording follows `/Users/jbuenosantan/.codex/skills/tasks/SKILL.md`: paste-ready, outcome-oriented, concise, and without evidence/source footers in the visible task description. Provenance stays in metadata and run output.

### Module: `Deduplicator`

Merges candidates that refer to the same underlying task across multiple sources. It uses:

- normalized title similarity
- shared project/account terms
- same meeting or thread source
- same due date or date proximity
- overlapping participant/context signals

When duplicates merge, the final task preserves all source references.

### Module: `SummaryEngine`

Produces:

- daily task summary
- weekly project summary
- meeting summary from Teams or NoteAI transcript
- open follow-up list
- blocker list
- T5T-ready task list

The first slice can use deterministic formatting plus a small LLM-backed summarization seam where needed. LLM calls must receive only normalized, truncated evidence and must report unavailable sources rather than filling gaps.

### Module: `AutomationRunner`

Daily task workflow:

1. Resolve day boundaries in `America/New_York`.
2. Query all enabled sources for that day only.
3. Normalize results.
4. Extract JP-owned tasks.
5. Deduplicate candidates.
6. Generate required markdown.
7. Print full markdown to run output.
8. Send the same markdown to Slack user `U09BXNGD81L`.
9. If Slack direct user send fails, resolve/create the DM and send there.
10. If Slack send still fails, include failure in run output.

Required daily output:

```markdown
# Daily Task Summary — {{date}}

## Tasks

### 1. {{Task Title}}
Description: {{clear description of the task, expected outcome, and relevant context}}
Source: {{Slack / Outlook / Teams / Calendar / NoteAI / Google Doc}}
Due date: {{if known, otherwise "Not specified"}}
Priority: {{if known, otherwise "Not specified"}}
```

If no open tasks are found, output and send a brief message saying no open tasks were identified for the day.

## Date And Time Handling

All query operations accept an explicit timezone. The default for JP work activity is `America/New_York`.

Supported ranges:

- current day
- current week
- custom start/end

Outlook email and calendar filtering use `America/New_York` boundaries by default because JP's Outlook mailbox timezone is Eastern Standard Time. NoteAI local database timestamps are Unix epoch seconds.

## Security And Privacy

- NoteAI does not read `~/.ai-pim-utils/cache.toml` directly.
- Source credentials remain managed by `ai-pim-utils` or provider-managed environment tokens.
- CLI subprocesses must avoid logging raw tokens, auth headers, or cache contents.
- NoteAI SQLite is opened read-only for this library.
- External source bodies are transient evidence, not persistent local cache content.
- Slack write capability is limited to sending the final daily summary DM to JP.
- Unavailable or unauthorized sources are reported explicitly.
- Generated task descriptions omit provenance and internal IDs by default; provenance remains in metadata/run output.

## Error Handling

Each source returns one of:

- available with results
- available with no results
- unavailable with reason
- unauthorized with remediation hint
- timed out

Summary output includes unavailable sources. A failed optional source must not fail the entire daily run unless all sources fail or required output cannot be generated.

## NoteAI Integration

Phase 1 exposes the CLI/library and does not change the NoteAI app UI.

Phase 2 can add:

- Settings > Sources status in the macOS app.
- AI assistant actions that call the library for source-aware questions.
- T5T generation path that calls `get_t5t_ready_tasks(date_range)`.
- A manual "Refresh daily tasks" action that presents task candidates for user approval.

Automatic task updates should create or update NoteAI tasks only through a NoteAI-owned app/API interface, not by direct SQLite mutation.

## Testing Strategy

Unit tests:

- date range resolution with `America/New_York`
- SQLite read-only connection enforcement
- source normalization for fixture payloads
- task extraction ownership filtering
- deduplication merge behavior
- daily markdown formatting
- unavailable source reporting

Integration/smoke tests:

- verify CLI discovery for `outlook-cli`, `calendar-cli`, `meeting-cli`, `teams-cli`, `slack-cli`, and `gdrive-cli`
- dry-run daily summary with unavailable sources
- read-only NoteAI SQLite query against a fixture database
- Slack send dry-run or mocked send path

No test should require live Slack/Outlook/Teams/Google credentials unless explicitly marked as an opt-in integration test.

## Delivery Slices

1. Library skeleton and models.
2. NoteAI read-only connector and date range handling.
3. CLI adapter framework plus source health checks.
4. Outlook/calendar/Teams transcript connectors.
5. Slack and Google Doc connectors.
6. Task extraction, deduplication, and daily summary formatting.
7. Slack DM delivery.
8. Assistant query and T5T-ready commands.
9. Optional NoteAI app integration.

## Acceptance Criteria

- Library can generate the required daily task summary format.
- Library can answer:
  - Which projects did I work on this week?
  - Generate a summary for meeting X based on its Teams transcript.
  - What open tasks do I have today?
- NoteAI local data is read from SQLite without direct mutation.
- Date ranges are timezone-aware and default to `America/New_York`.
- Duplicate task-like items are merged across supported sources.
- Daily automation can send the final summary to JP on Slack.
- Unavailable sources are reported in output.
- Task wording follows `/Users/jbuenosantan/.codex/skills/tasks/SKILL.md`.
- T5T-ready task output can feed NoteAI T5T generation.
