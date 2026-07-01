from datetime import datetime
from zoneinfo import ZoneInfo
import unittest

from tools.work_activity.deduplication import deduplicate_tasks
from tools.work_activity.extraction import extract_task_candidates
from tools.work_activity.models import ActivityItem, SourceKind, SourceRef, TaskCandidate


class ExtractionAndDeduplicationTests(unittest.TestCase):
    def test_extracts_jp_owned_task_from_noteai_activity(self):
        item = ActivityItem(
            source=SourceKind.NOTEAI,
            timestamp=datetime(2026, 7, 1, tzinfo=ZoneInfo("America/New_York")),
            title="Follow up with Nscale",
            body="Confirm the runtime owner for the Dynamo PoC.",
            status="open",
            source_refs=[SourceRef(SourceKind.NOTEAI, "NoteAI task", source_id="1")],
            ownership_signals=["JP"],
        )
        tasks = extract_task_candidates([item])
        self.assertEqual(len(tasks), 1)
        self.assertEqual(tasks[0].title, "Follow up with Nscale")
        self.assertIn("Confirm the runtime owner", tasks[0].description)

    def test_extracts_open_task_with_whitespace_padded_status(self):
        item = ActivityItem(
            source=SourceKind.NOTEAI,
            timestamp=None,
            title="Confirm PoC owner",
            body="Runtime owner needs confirmation.",
            status=" Open ",
            source_refs=[SourceRef(SourceKind.NOTEAI, "NoteAI task", source_id="3")],
        )
        tasks = extract_task_candidates([item])
        self.assertEqual(len(tasks), 1)
        self.assertEqual(tasks[0].status, "open")

    def test_extracts_missing_status_noteai_item_with_task_hint(self):
        item = ActivityItem(
            source=SourceKind.NOTEAI,
            timestamp=None,
            title="Confirm PoC owner",
            body="Runtime owner discussion from imported task.",
            status=None,
            source_refs=[SourceRef(SourceKind.NOTEAI, "NoteAI task", source_id="4")],
            raw_metadata={"table": "tasks"},
        )
        tasks = extract_task_candidates([item])
        self.assertEqual(len(tasks), 1)
        self.assertEqual(tasks[0].status, "open")

    def test_ignores_missing_status_noteai_meeting_without_task_signal(self):
        item = ActivityItem(
            source=SourceKind.NOTEAI,
            timestamp=datetime(2026, 7, 1, tzinfo=ZoneInfo("America/New_York")),
            title="Nscale Sync",
            body="JP and Alex discussed Dynamo runtime ownership and deployment context.",
            status=None,
            source_refs=[SourceRef(SourceKind.NOTEAI, "NoteAI meeting", source_id="meeting-1")],
            raw_metadata={"table": "meetings"},
        )
        self.assertEqual(extract_task_candidates([item]), [])

    def test_ignores_generic_needs_language_in_noteai_meeting(self):
        item = ActivityItem(
            source=SourceKind.NOTEAI,
            timestamp=datetime(2026, 7, 1, tzinfo=ZoneInfo("America/New_York")),
            title="Customer pricing discussion",
            body="The customer needs better pricing before committing to the rollout.",
            status=None,
            source_refs=[SourceRef(SourceKind.NOTEAI, "NoteAI meeting", source_id="meeting-2")],
            raw_metadata={"table": "meetings"},
        )
        self.assertEqual(extract_task_candidates([item]), [])

    def test_ignores_completed_items_without_remaining_followup(self):
        item = ActivityItem(
            source=SourceKind.NOTEAI,
            timestamp=None,
            title="Completed old work",
            body="No remaining follow-up.",
            status="completed",
            source_refs=[SourceRef(SourceKind.NOTEAI, "NoteAI task", source_id="2")],
        )
        self.assertEqual(extract_task_candidates([item]), [])

    def test_deduplicates_same_task_across_sources(self):
        first = TaskCandidate(
            title="Follow up with Nscale",
            description="Confirm runtime owner.",
            sources=[SourceRef(SourceKind.SLACK, "Slack message", source_id="s1")],
        )
        second = TaskCandidate(
            title="Follow-up with Nscale",
            description="Confirm the runtime ownership path.",
            sources=[SourceRef(SourceKind.OUTLOOK, "Outlook email", source_id="m1")],
        )
        merged = deduplicate_tasks([first, second])
        self.assertEqual(len(merged), 1)
        self.assertEqual({source.source for source in merged[0].sources}, {SourceKind.SLACK, SourceKind.OUTLOOK})

    def test_deduplicates_preserving_distinct_refs_without_source_ids(self):
        first = TaskCandidate(
            title="Follow up with Nscale",
            description="Confirm runtime owner.",
            sources=[
                SourceRef(SourceKind.SLACK, "Slack channel mention", url="https://slack.example/messages/one")
            ],
        )
        second = TaskCandidate(
            title="Follow-up with Nscale",
            description="Confirm the runtime ownership path.",
            sources=[
                SourceRef(SourceKind.SLACK, "Slack thread reply", url="https://slack.example/messages/two")
            ],
        )
        merged = deduplicate_tasks([first, second])
        self.assertEqual(len(merged), 1)
        refs = {(source.source, source.label, source.url, source.source_id) for source in merged[0].sources}
        self.assertEqual(
            refs,
            {
                (SourceKind.SLACK, "Slack channel mention", "https://slack.example/messages/one", None),
                (SourceKind.SLACK, "Slack thread reply", "https://slack.example/messages/two", None),
            },
        )

    def test_deduplicates_does_not_merge_empty_title_keys(self):
        first = TaskCandidate(
            title="...",
            description="First malformed title.",
            sources=[SourceRef(SourceKind.SLACK, "Slack message", source_id="empty-1")],
        )
        second = TaskCandidate(
            title="---",
            description="Second malformed title.",
            sources=[SourceRef(SourceKind.OUTLOOK, "Outlook email", source_id="empty-2")],
        )
        merged = deduplicate_tasks([first, second])
        self.assertEqual(len(merged), 2)
