import subprocess
import sys
import unittest
from datetime import datetime
from zoneinfo import ZoneInfo

from tools.work_activity.assistant_queries import (
    get_daily_task_summary,
    get_open_tasks,
    get_projects_worked_on,
    get_t5t_ready_tasks,
)
from tools.work_activity.date_ranges import day_range
from tools.work_activity.models import ActivityItem, SourceKind, SourceRef, TaskCandidate
from tools.work_activity.summaries import format_daily_task_summary, format_open_tasks


class WorkActivityCLITests(unittest.TestCase):
    def run_cli(self, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, "-m", "tools.work_activity", *args],
            cwd=str(__import__("pathlib").Path(__file__).resolve().parents[3]),
            text=True,
            capture_output=True,
            check=False,
        )

    def test_help_lists_daily_summary_command(self):
        result = self.run_cli("--help")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("daily-summary", result.stdout)

    def test_daily_summary_dry_run_outputs_markdown(self):
        result = self.run_cli("daily-summary", "--date", "2026-07-01", "--dry-run")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("# Daily Task Summary — 2026-07-01", result.stdout)
        self.assertIn("No open tasks were identified for the day.", result.stdout)

    def test_format_daily_task_summary_includes_task_details(self):
        task = TaskCandidate(
            title="Follow up with Nscale",
            description="Confirm runtime owner and expected next step.",
            due_date=datetime(2026, 7, 2, tzinfo=ZoneInfo("America/New_York")),
            priority="High",
            sources=[
                SourceRef(SourceKind.SLACK, "Slack thread"),
                SourceRef(SourceKind.OUTLOOK, "Outlook email"),
            ],
        )

        output = format_daily_task_summary(
            "2026-07-01",
            [task],
            unavailable_sources=["Google Doc unavailable"],
        )

        self.assertEqual(
            output,
            "\n".join(
                [
                    "# Daily Task Summary — 2026-07-01",
                    "",
                    "## Tasks",
                    "",
                    "### 1. Follow up with Nscale",
                    "Description: Confirm runtime owner and expected next step.",
                    "Source: Slack / Outlook",
                    "Due date: 07/02/26",
                    "Priority: High",
                    "",
                    "## Unavailable sources",
                    "- Google Doc unavailable",
                ]
            ),
        )

    def test_format_open_tasks_empty_state_is_not_daily_specific(self):
        self.assertEqual(format_open_tasks([]), "No open tasks were identified.")


from tools.work_activity.cli_runner import CLIRunner


class CLIRunnerTests(unittest.TestCase):
    def test_missing_command_returns_unavailable_health(self):
        runner = CLIRunner()
        result = runner.run(["definitely-not-installed-noteai-cli", "--version"])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not found", result.stderr.lower())


class AssistantQueryTests(unittest.TestCase):
    def test_get_open_tasks_filters_range_and_deduplicates(self):
        date_range = day_range("2026-07-01")
        in_range = ActivityItem(
            source=SourceKind.NOTEAI,
            timestamp=datetime(2026, 7, 1, 9, tzinfo=ZoneInfo("America/New_York")),
            title="Follow up with Nscale",
            body="Confirm runtime owner.",
            status="open",
            project="Nscale",
            source_refs=[SourceRef(SourceKind.NOTEAI, "NoteAI task", source_id="task-1")],
        )
        duplicate = ActivityItem(
            source=SourceKind.SLACK,
            timestamp=datetime(2026, 7, 1, 11, tzinfo=ZoneInfo("America/New_York")),
            title="Follow-up with Nscale",
            body="JP needs next step confirmation.",
            status="pending",
            project="Nscale",
            source_refs=[SourceRef(SourceKind.SLACK, "Slack thread", source_id="slack-1")],
            ownership_signals=["JP"],
        )
        out_of_range = ActivityItem(
            source=SourceKind.NOTEAI,
            timestamp=datetime(2026, 7, 2, 9, tzinfo=ZoneInfo("America/New_York")),
            title="Prepare separate brief",
            body="Draft the separate brief.",
            status="open",
            project="Other",
            source_refs=[SourceRef(SourceKind.NOTEAI, "NoteAI task", source_id="task-2")],
        )

        tasks = get_open_tasks(date_range, [in_range, duplicate, out_of_range])

        self.assertEqual(len(tasks), 1)
        self.assertEqual(tasks[0].title, "Follow up with Nscale")
        self.assertEqual({source.source for source in tasks[0].sources}, {SourceKind.NOTEAI, SourceKind.SLACK})

    def test_get_projects_worked_on_returns_unique_projects_in_range(self):
        date_range = day_range("2026-07-01")
        items = [
            ActivityItem(
                source=SourceKind.NOTEAI,
                timestamp=datetime(2026, 7, 1, 9, tzinfo=ZoneInfo("America/New_York")),
                title="Nscale task",
                body="Follow up.",
                project="Nscale",
                source_refs=[SourceRef(SourceKind.NOTEAI, "Task")],
            ),
            ActivityItem(
                source=SourceKind.SLACK,
                timestamp=datetime(2026, 7, 1, 12, tzinfo=ZoneInfo("America/New_York")),
                title="Nscale thread",
                body="Discussed runtime.",
                project="Nscale",
                source_refs=[SourceRef(SourceKind.SLACK, "Thread")],
            ),
            ActivityItem(
                source=SourceKind.OUTLOOK,
                timestamp=datetime(2026, 7, 2, 9, tzinfo=ZoneInfo("America/New_York")),
                title="Future work",
                body="Outside range.",
                project="Future",
                source_refs=[SourceRef(SourceKind.OUTLOOK, "Email")],
            ),
        ]

        self.assertEqual(get_projects_worked_on(date_range, items), ["Nscale"])

    def test_get_daily_task_summary_formats_extracted_tasks(self):
        date_range = day_range("2026-07-01")
        item = ActivityItem(
            source=SourceKind.NOTEAI,
            timestamp=datetime(2026, 7, 1, 9, tzinfo=ZoneInfo("America/New_York")),
            title="Follow up with Nscale",
            body="Confirm runtime owner.",
            status="open",
            source_refs=[SourceRef(SourceKind.NOTEAI, "Task")],
        )

        output = get_daily_task_summary(date_range, [item])

        self.assertIn("# Daily Task Summary — 2026-07-01", output)
        self.assertIn("## Tasks", output)
        self.assertIn("### 1. Follow up with Nscale", output)

    def test_get_daily_task_summary_excludes_out_of_range_items(self):
        date_range = day_range("2026-07-01")
        in_range = ActivityItem(
            source=SourceKind.NOTEAI,
            timestamp=datetime(2026, 7, 1, 9, tzinfo=ZoneInfo("America/New_York")),
            title="Follow up with Nscale",
            body="Confirm runtime owner.",
            status="open",
            source_refs=[SourceRef(SourceKind.NOTEAI, "Task")],
        )
        out_of_range = ActivityItem(
            source=SourceKind.NOTEAI,
            timestamp=datetime(2026, 7, 2, 9, tzinfo=ZoneInfo("America/New_York")),
            title="Prepare future brief",
            body="Draft tomorrow's brief.",
            status="open",
            source_refs=[SourceRef(SourceKind.NOTEAI, "Task")],
        )

        output = get_daily_task_summary(date_range, [in_range, out_of_range])

        self.assertIn("Follow up with Nscale", output)
        self.assertNotIn("Prepare future brief", output)

    def test_get_t5t_ready_tasks_returns_open_task_markdown(self):
        date_range = day_range("2026-07-01")
        item = ActivityItem(
            source=SourceKind.NOTEAI,
            timestamp=datetime(2026, 7, 1, 9, tzinfo=ZoneInfo("America/New_York")),
            title="Confirm runtime owner",
            body="Confirm runtime owner for T5T follow-up.",
            status="open",
            source_refs=[SourceRef(SourceKind.NOTEAI, "Task")],
        )

        output = get_t5t_ready_tasks(date_range, [item])

        self.assertIn("### 1. Confirm runtime owner", output)
        self.assertIn("Source: NoteAI", output)
