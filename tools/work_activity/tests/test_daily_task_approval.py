import hashlib
import json
import multiprocessing
import os
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest
from contextlib import closing
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest.mock import patch
from zoneinfo import ZoneInfo

from tools.work_activity import daily_task_approval


JP_SLACK_USER_ID = "U09BXNGD81L"
SLACK_CHANNEL_ID = "D123"
DELIVERY_MESSAGE_TS = "1720000000.000100"
APPROVAL_MESSAGE_TS = "1720000000.000200"


def approval_command(day: str, revision: int = 1) -> str:
    return f"APPROVE {day} R{revision}"


def candidate_payload(title: str = "Delivered NoteAI approval workflow") -> dict[str, object]:
    return {
        "tasks": [
            {
                "title": title,
                "description": "Implemented an approval-gated import that prevents duplicate tasks.",
                "sources": ["Slack", "Outlook", "Slack"],
                "dueDate": None,
                "priority": None,
            },
            {
                "title": f"  {title}  ",
                "description": "Implemented   an approval-gated import that prevents duplicate tasks.",
                "sources": ["Outlook", "Slack"],
                "dueDate": None,
                "priority": None,
            },
        ],
        "sourceHealth": {"Slack": "available", "Outlook": "available"},
    }


TASK_COLUMNS_SQL = (
    "id TEXT PRIMARY KEY, title TEXT NOT NULL, created_date REAL NOT NULL, "
    "modified_date REAL NOT NULL, status TEXT NOT NULL DEFAULT 'open', "
    "work_date REAL, completed_date REAL, source_meeting_id TEXT, "
    "source_action_item_id TEXT, source_note_id TEXT, json_data TEXT NOT NULL"
)


def create_noteai_db(path: Path, *, unexpected_column: bool = False) -> None:
    with closing(sqlite3.connect(path)) as db:
        suffix = ", unexpected TEXT" if unexpected_column else ""
        db.execute(f"CREATE TABLE tasks ({TASK_COLUMNS_SQL}{suffix})")
        db.execute("CREATE TABLE todos (id TEXT PRIMARY KEY, title TEXT NOT NULL)")
        db.execute("INSERT INTO todos VALUES ('todo-1', 'Preserve this todo')")
        db.commit()


def stage_and_approve(
    root: Path,
    title: str = "Delivered NoteAI approval workflow",
    *,
    day: str = "2026-07-09",
    delivery_message_ts: str = DELIVERY_MESSAGE_TS,
    approval_message_ts: str = APPROVAL_MESSAGE_TS,
) -> None:
    tasks_file = root / f"tasks-{day}.json"
    tasks_file.write_text(json.dumps(candidate_payload(title)), encoding="utf-8")
    daily_task_approval.stage(day, tasks_file, root / "state")
    daily_task_approval.record_delivery(
        day, 1, SLACK_CHANNEL_ID, delivery_message_ts, root / "state"
    )
    daily_task_approval.decide(
        day,
        1,
        "approved",
        JP_SLACK_USER_ID,
        SLACK_CHANNEL_ID,
        approval_message_ts,
        approval_command(day),
        root / "state",
    )


def concurrent_decide_worker(
    state_dir: str,
    day: str,
    start_event: object,
    result_queue: object,
) -> None:
    start_event.wait()
    try:
        daily_task_approval.decide(
            day,
            1,
            "approved",
            JP_SLACK_USER_ID,
            SLACK_CHANNEL_ID,
            APPROVAL_MESSAGE_TS,
            approval_command(day),
            Path(state_dir),
        )
        result_queue.put("approved")
    except daily_task_approval.ApprovalError as exc:
        result_queue.put(f"error:{exc}")


def concurrent_apply_worker(
    root: str,
    day: str,
    start_event: object,
    result_queue: object,
) -> None:
    root_path = Path(root)
    original_backup = daily_task_approval._backup_database

    def delayed_backup(backup_path: Path, db: sqlite3.Connection) -> None:
        time.sleep(0.3)
        original_backup(backup_path, db)

    start_event.wait()
    try:
        with patch.object(daily_task_approval, "_backup_database", side_effect=delayed_backup):
            result = daily_task_approval.apply(
                day,
                1,
                root_path / "meetings.sqlite",
                root_path / "state",
                root_path / "backups",
            )
        result_queue.put({"status": "applied", "result": result})
    except Exception as exc:
        result_queue.put({"status": "error", "error": repr(exc)})


class DailyTaskApprovalStateTests(unittest.TestCase):
    def test_stage_is_idempotent_and_revises_changed_pending_content(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            tasks_file = root / "tasks.json"
            tasks_file.write_text(json.dumps(candidate_payload()), encoding="utf-8")

            first = daily_task_approval.stage("2026-07-09", tasks_file, root / "state")
            repeated = daily_task_approval.stage("2026-07-09", tasks_file, root / "state")

            self.assertEqual(first["activeRevision"], 1)
            self.assertEqual(repeated, first)
            self.assertEqual(len(first["revisions"]), 1)
            self.assertEqual(len(first["revisions"][0]["tasks"]), 1)
            self.assertEqual(first["revisions"][0]["tasks"][0]["sources"], ["Outlook", "Slack"])

            tasks_file.write_text(json.dumps(candidate_payload("Delivered revised workflow")), encoding="utf-8")
            revised = daily_task_approval.stage("2026-07-09", tasks_file, root / "state")

            self.assertEqual(revised["activeRevision"], 2)
            self.assertEqual(len(revised["revisions"]), 2)
            self.assertEqual(revised["revisions"][1]["status"], "pending")

    def test_stage_rejects_missing_and_unexpected_candidate_columns(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            tasks_file = root / "tasks.json"
            payload = candidate_payload()
            del payload["tasks"][0]["description"]
            tasks_file.write_text(json.dumps(payload), encoding="utf-8")

            with self.assertRaisesRegex(daily_task_approval.ApprovalError, "task columns"):
                daily_task_approval.stage("2026-07-09", tasks_file, root / "state")

    def test_stage_rejects_non_null_unsupported_task_fields(self):
        for field, value in (("dueDate", "2026-07-10"), ("priority", "high")):
            with self.subTest(field=field), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                tasks_file = root / "tasks.json"
                payload = candidate_payload()
                payload["tasks"][0][field] = value
                tasks_file.write_text(json.dumps(payload), encoding="utf-8")

                with self.assertRaisesRegex(
                    daily_task_approval.ApprovalError,
                    f"tasks\\[0\\].{field} must be null",
                ):
                    daily_task_approval.stage("2026-07-09", tasks_file, root / "state")

    def test_stage_merges_sources_for_the_same_canonical_task(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            tasks_file = root / "tasks.json"
            payload = candidate_payload()
            payload["tasks"][0]["sources"] = ["Slack"]
            payload["tasks"][1]["sources"] = ["Outlook"]
            tasks_file.write_text(json.dumps(payload), encoding="utf-8")

            state = daily_task_approval.stage("2026-07-09", tasks_file, root / "state")

            tasks = state["revisions"][0]["tasks"]
            self.assertEqual(len(tasks), 1)
            self.assertEqual(tasks[0]["sources"], ["Outlook", "Slack"])

            payload = candidate_payload()
            payload["tasks"][0]["rawEvidence"] = "must not be stored"
            tasks_file.write_text(json.dumps(payload), encoding="utf-8")

            with self.assertRaisesRegex(daily_task_approval.ApprovalError, "task columns"):
                daily_task_approval.stage("2026-07-09", tasks_file, root / "state")

    def test_stage_assigns_distinct_candidate_ids_to_same_title_different_descriptions(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            tasks_file = root / "tasks.json"
            payload = candidate_payload()
            payload["tasks"] = [payload["tasks"][0], dict(payload["tasks"][0])]
            payload["tasks"][1]["description"] = "Documented the approval recovery contract."
            tasks_file.write_text(json.dumps(payload), encoding="utf-8")

            state = daily_task_approval.stage("2026-07-09", tasks_file, root / "state")

            tasks = state["revisions"][0]["tasks"]
            self.assertEqual(len(tasks), 2)
            self.assertEqual(len({task["candidateID"] for task in tasks}), 2)

    def test_stage_preserves_candidate_id_for_unambiguous_description_revision(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            tasks_file = root / "tasks.json"
            tasks_file.write_text(json.dumps(candidate_payload()), encoding="utf-8")
            first = daily_task_approval.stage("2026-07-09", tasks_file, root / "state")

            payload = candidate_payload()
            for task in payload["tasks"]:
                task["description"] = "Hardened the approval workflow after review."
            tasks_file.write_text(json.dumps(payload), encoding="utf-8")
            revised = daily_task_approval.stage("2026-07-09", tasks_file, root / "state")

            self.assertEqual(
                revised["revisions"][1]["tasks"][0]["candidateID"],
                first["revisions"][0]["tasks"][0]["candidateID"],
            )

    def test_state_file_is_owner_only(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            tasks_file = root / "tasks.json"
            tasks_file.write_text(json.dumps(candidate_payload()), encoding="utf-8")

            daily_task_approval.stage("2026-07-09", tasks_file, root / "state")

            state_path = root / "state" / "2026-07-09.json"
            self.assertEqual(state_path.stat().st_mode & 0o777, 0o600)


class DailyTaskApprovalDecisionTests(unittest.TestCase):
    def _stage(self, root: Path, title: str = "Delivered NoteAI approval workflow") -> Path:
        tasks_file = root / "tasks.json"
        tasks_file.write_text(json.dumps(candidate_payload(title)), encoding="utf-8")
        daily_task_approval.stage("2026-07-09", tasks_file, root / "state")
        return tasks_file

    def test_render_includes_slack_ready_tasks_and_exact_instructions(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self._stage(root)

            rendered = daily_task_approval.render("2026-07-09", root / "state")

            self.assertIn("Daily task summary - 2026-07-09 (R1)", rendered)
            self.assertIn("1. Delivered NoteAI approval workflow", rendered)
            self.assertIn("Sources: Outlook, Slack", rendered)
            self.assertIn("APPROVE 2026-07-09 R1", rendered)
            self.assertIn("REJECT 2026-07-09 R1", rendered)
            self.assertIn("EDIT 2026-07-09 R1: <requested changes>", rendered)

    def test_delivery_and_decision_reject_stale_revisions_and_illegal_transitions(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            tasks_file = self._stage(root)
            tasks_file.write_text(json.dumps(candidate_payload("Delivered revision two")), encoding="utf-8")
            daily_task_approval.stage("2026-07-09", tasks_file, root / "state")

            with self.assertRaisesRegex(daily_task_approval.ApprovalError, "stale revision"):
                daily_task_approval.record_delivery(
                    "2026-07-09", 1, "D123", "1720000000.000100", root / "state"
                )
            with self.assertRaisesRegex(daily_task_approval.ApprovalError, "stale revision"):
                daily_task_approval.decide(
                    "2026-07-09",
                    1,
                    "approved",
                    JP_SLACK_USER_ID,
                    SLACK_CHANNEL_ID,
                    "1720000000.000300",
                    "APPROVE 2026-07-09 R1",
                    root / "state",
                )

            delivered = daily_task_approval.record_delivery(
                "2026-07-09", 2, "D123", "1720000000.000200", root / "state"
            )
            self.assertEqual(delivered["revisions"][1]["delivery"]["channelID"], "D123")
            approved = daily_task_approval.decide(
                "2026-07-09",
                2,
                "approved",
                JP_SLACK_USER_ID,
                SLACK_CHANNEL_ID,
                "1720000000.000300",
                "APPROVE 2026-07-09 R2",
                root / "state",
            )
            self.assertEqual(approved["revisions"][1]["status"], "approved")

            with self.assertRaisesRegex(daily_task_approval.ApprovalError, "illegal transition"):
                daily_task_approval.decide(
                    "2026-07-09",
                    2,
                    "rejected",
                    JP_SLACK_USER_ID,
                    SLACK_CHANNEL_ID,
                    "1720000000.000400",
                    "REJECT 2026-07-09 R2",
                    root / "state",
                )
            with self.assertRaisesRegex(daily_task_approval.ApprovalError, "cannot revise approved"):
                tasks_file.write_text(json.dumps(candidate_payload("Revision three")), encoding="utf-8")
                daily_task_approval.stage("2026-07-09", tasks_file, root / "state")

    def test_record_delivery_rejects_invalid_slack_timestamp(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self._stage(root)

            with self.assertRaisesRegex(daily_task_approval.ApprovalError, "Slack timestamp"):
                daily_task_approval.record_delivery(
                    "2026-07-09", 1, SLACK_CHANNEL_ID, "not-a-timestamp", root / "state"
                )

    def test_record_delivery_accepts_only_private_dm_conversation_ids(self):
        for channel_id in ("C123", "G123", "U123", "D", " D123", "D123 "):
            with self.subTest(channel_id=channel_id), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                self._stage(root)

                with self.assertRaisesRegex(daily_task_approval.ApprovalError, "private DM"):
                    daily_task_approval.record_delivery(
                        "2026-07-09", 1, channel_id, DELIVERY_MESSAGE_TS, root / "state"
                    )

    def test_decide_requires_exact_command_and_persists_only_hash_and_type(self):
        cases = (
            (
                "approved",
                approval_command("2026-07-09"),
                ("approve 2026-07-09 R1", "APPROVE 2026-07-09 R1 now", " APPROVE 2026-07-09 R1"),
                "APPROVE",
            ),
            (
                "rejected",
                "REJECT 2026-07-09 R1",
                ("REJECT 2026-07-09 R2", "REJECT 2026-07-09 R1 ", "REJECT 2026-07-09"),
                "REJECT",
            ),
            (
                "needs_revision",
                "EDIT 2026-07-09 R1: Add customer impact",
                ("EDIT 2026-07-09 R1:", "EDIT 2026-07-09 R1:   ", "EDIT 2026-07-09 R1 Add customer impact"),
                "EDIT",
            ),
        )
        for decision, valid_command, invalid_commands, command_type in cases:
            for invalid_command in invalid_commands:
                with (
                    self.subTest(decision=decision, command=invalid_command),
                    tempfile.TemporaryDirectory() as tmp,
                ):
                    root = Path(tmp)
                    self._stage(root)
                    daily_task_approval.record_delivery(
                        "2026-07-09", 1, SLACK_CHANNEL_ID, DELIVERY_MESSAGE_TS, root / "state"
                    )

                    with self.assertRaisesRegex(daily_task_approval.ApprovalError, "exact Slack command"):
                        daily_task_approval.decide(
                            "2026-07-09",
                            1,
                            decision,
                            JP_SLACK_USER_ID,
                            SLACK_CHANNEL_ID,
                            APPROVAL_MESSAGE_TS,
                            invalid_command,
                            root / "state",
                        )

            with self.subTest(decision=decision), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                self._stage(root)
                daily_task_approval.record_delivery(
                    "2026-07-09", 1, SLACK_CHANNEL_ID, DELIVERY_MESSAGE_TS, root / "state"
                )

                decided = daily_task_approval.decide(
                    "2026-07-09",
                    1,
                    decision,
                    JP_SLACK_USER_ID,
                    SLACK_CHANNEL_ID,
                    APPROVAL_MESSAGE_TS,
                    valid_command,
                    root / "state",
                )

                evidence = decided["revisions"][0]["approvalEvidence"]
                self.assertEqual(evidence["commandType"], command_type)
                self.assertEqual(
                    evidence["commandHash"],
                    hashlib.sha256(valid_command.encode("utf-8")).hexdigest(),
                )
                self.assertNotIn("commandText", evidence)
                if decision == "needs_revision":
                    self.assertNotIn("Add customer impact", json.dumps(decided))

    def test_decision_evidence_cannot_be_reused_across_dates_concurrently(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for day in ("2026-07-09", "2026-07-10"):
                tasks_file = root / f"tasks-{day}.json"
                tasks_file.write_text(json.dumps(candidate_payload(day)), encoding="utf-8")
                daily_task_approval.stage(day, tasks_file, root / "state")
                daily_task_approval.record_delivery(
                    day, 1, SLACK_CHANNEL_ID, DELIVERY_MESSAGE_TS, root / "state"
                )

            context = multiprocessing.get_context("spawn")
            start_event = context.Event()
            result_queue = context.Queue()
            processes = [
                context.Process(
                    target=concurrent_decide_worker,
                    args=(str(root / "state"), day, start_event, result_queue),
                )
                for day in ("2026-07-09", "2026-07-10")
            ]
            for process in processes:
                process.start()
            start_event.set()
            results = [result_queue.get(timeout=10) for _ in processes]
            for process in processes:
                process.join(timeout=10)
                self.assertEqual(process.exitcode, 0)

            self.assertEqual(results.count("approved"), 1)
            self.assertEqual(sum(result.startswith("error:") for result in results), 1)
            self.assertTrue(any("already used" in result for result in results))
            lock_path = root / "state" / ".decision-evidence.lock"
            self.assertEqual(lock_path.stat().st_mode & 0o777, 0o600)

    def test_decide_enforces_and_persists_slack_approval_evidence(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self._stage(root)
            daily_task_approval.record_delivery(
                "2026-07-09", 1, SLACK_CHANNEL_ID, DELIVERY_MESSAGE_TS, root / "state"
            )

            invalid_cases = (
                (
                    "U0000000000",
                    SLACK_CHANNEL_ID,
                    APPROVAL_MESSAGE_TS,
                    "authorized Slack user",
                ),
                (
                    JP_SLACK_USER_ID,
                    "D999",
                    APPROVAL_MESSAGE_TS,
                    "channel does not match",
                ),
                (
                    JP_SLACK_USER_ID,
                    SLACK_CHANNEL_ID,
                    DELIVERY_MESSAGE_TS,
                    "newer than delivery",
                ),
                (
                    f" {JP_SLACK_USER_ID} ",
                    SLACK_CHANNEL_ID,
                    APPROVAL_MESSAGE_TS,
                    "authorized Slack user",
                ),
                (
                    JP_SLACK_USER_ID,
                    f"{SLACK_CHANNEL_ID} ",
                    APPROVAL_MESSAGE_TS,
                    "channel does not match",
                ),
            )
            for actor_user_id, channel_id, approval_message_ts, error in invalid_cases:
                with self.subTest(error=error):
                    with self.assertRaisesRegex(daily_task_approval.ApprovalError, error):
                        daily_task_approval.decide(
                            "2026-07-09",
                            1,
                            "approved",
                            actor_user_id,
                            channel_id,
                            approval_message_ts,
                            approval_command("2026-07-09"),
                            root / "state",
                        )

            approved = daily_task_approval.decide(
                "2026-07-09",
                1,
                "approved",
                JP_SLACK_USER_ID,
                SLACK_CHANNEL_ID,
                APPROVAL_MESSAGE_TS,
                approval_command("2026-07-09"),
                root / "state",
            )

            self.assertEqual(
                approved["revisions"][0]["approvalEvidence"],
                {
                    "actorUserID": JP_SLACK_USER_ID,
                    "channelID": SLACK_CHANNEL_ID,
                    "messageTS": APPROVAL_MESSAGE_TS,
                    "commandType": "APPROVE",
                    "commandHash": hashlib.sha256(
                        approval_command("2026-07-09").encode("utf-8")
                    ).hexdigest(),
                },
            )

    def test_show_returns_active_state_without_exposing_lock_details(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self._stage(root)

            state = daily_task_approval.show("2026-07-09", root / "state")

            self.assertEqual(state["activeRevision"], 1)
            self.assertNotIn("lock", state)


class DailyTaskApprovalApplyTests(unittest.TestCase):
    def test_apply_requires_approval_and_rejects_unexpected_task_schema(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            db_path = root / "meetings.sqlite"
            create_noteai_db(db_path)
            tasks_file = root / "tasks.json"
            tasks_file.write_text(json.dumps(candidate_payload()), encoding="utf-8")
            daily_task_approval.stage("2026-07-09", tasks_file, root / "state")

            with self.assertRaisesRegex(daily_task_approval.ApprovalError, "must be approved"):
                daily_task_approval.apply(
                    "2026-07-09", 1, db_path, root / "state", root / "backups"
                )

            db_path.unlink()
            create_noteai_db(db_path, unexpected_column=True)
            daily_task_approval.record_delivery(
                "2026-07-09", 1, "D123", "1720000000.000100", root / "state"
            )
            daily_task_approval.decide(
                "2026-07-09",
                1,
                "approved",
                JP_SLACK_USER_ID,
                SLACK_CHANNEL_ID,
                APPROVAL_MESSAGE_TS,
                approval_command("2026-07-09"),
                root / "state",
            )
            with self.assertRaisesRegex(daily_task_approval.ApprovalError, "tasks schema"):
                daily_task_approval.apply(
                    "2026-07-09", 1, db_path, root / "state", root / "backups"
                )

    def test_apply_rejects_approved_state_without_valid_slack_evidence(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            db_path = root / "meetings.sqlite"
            create_noteai_db(db_path)
            tasks_file = root / "tasks.json"
            tasks_file.write_text(json.dumps(candidate_payload()), encoding="utf-8")
            daily_task_approval.stage("2026-07-09", tasks_file, root / "state")
            daily_task_approval.record_delivery(
                "2026-07-09", 1, SLACK_CHANNEL_ID, DELIVERY_MESSAGE_TS, root / "state"
            )
            state_path = root / "state" / "2026-07-09.json"
            state = json.loads(state_path.read_text(encoding="utf-8"))
            revision = state["revisions"][0]
            revision["status"] = "approved"
            state_path.write_text(json.dumps(state), encoding="utf-8")
            os.chmod(state_path, 0o600)

            with self.assertRaisesRegex(daily_task_approval.ApprovalError, "approval evidence"):
                daily_task_approval.apply(
                    "2026-07-09", 1, db_path, root / "state", root / "backups"
                )

            revision["approvalEvidence"] = {
                "actorUserID": "U0000000000",
                "channelID": SLACK_CHANNEL_ID,
                "messageTS": APPROVAL_MESSAGE_TS,
                "commandType": "APPROVE",
                "commandHash": hashlib.sha256(
                    approval_command("2026-07-09").encode("utf-8")
                ).hexdigest(),
            }
            state_path.write_text(json.dumps(state), encoding="utf-8")
            os.chmod(state_path, 0o600)
            with self.assertRaisesRegex(daily_task_approval.ApprovalError, "authorized Slack user"):
                daily_task_approval.apply(
                    "2026-07-09", 1, db_path, root / "state", root / "backups"
                )
            self.assertFalse((root / "backups").exists())

    def test_apply_inserts_completed_tasks_only_with_noon_dates_and_backup(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            db_path = root / "meetings.sqlite"
            create_noteai_db(db_path)
            stage_and_approve(root)

            result = daily_task_approval.apply(
                "2026-07-09", 1, db_path, root / "state", root / "backups"
            )

            self.assertEqual(len(result["insertedIDs"]), 1)
            self.assertEqual(result["skippedExistingIDs"], [])
            backup_path = Path(result["backupPath"])
            self.assertTrue(backup_path.is_file())
            self.assertEqual(backup_path.stat().st_mode & 0o777, 0o600)

            expected_unix = datetime(
                2026, 7, 9, 12, 0, tzinfo=ZoneInfo("America/New_York")
            ).timestamp()
            with closing(sqlite3.connect(db_path)) as db:
                row = db.execute("SELECT * FROM tasks").fetchone()
                todo_count = db.execute("SELECT COUNT(*) FROM todos").fetchone()[0]
            self.assertEqual(todo_count, 1)
            self.assertEqual(row[4], "completed")
            self.assertEqual(row[5], expected_unix)
            self.assertEqual(row[6], expected_unix)
            self.assertIsNone(row[7])
            self.assertTrue(row[8].startswith("codex-daily-task-summary:2026-07-09:"))
            task_json = json.loads(row[10])
            self.assertEqual(task_json["sourceActionItemID"], row[8])
            self.assertEqual(task_json["workDate"], expected_unix - 978307200)
            self.assertEqual(task_json["completedDate"], expected_unix - 978307200)
            self.assertEqual(task_json["owner"], "JP")
            self.assertEqual(task_json["sourceMetadata"]["provider"], "Codex Daily Task Summary")
            self.assertEqual(task_json["sourceMetadata"]["threadID"], "D123")
            self.assertEqual(task_json["sourceMetadata"]["messageID"], "1720000000.000100")

    def test_apply_is_deterministic_and_recovers_after_commit_before_state_update(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            db_path = root / "meetings.sqlite"
            create_noteai_db(db_path)
            stage_and_approve(root)
            first = daily_task_approval.apply(
                "2026-07-09", 1, db_path, root / "state", root / "backups"
            )

            state_path = root / "state" / "2026-07-09.json"
            state = json.loads(state_path.read_text(encoding="utf-8"))
            revision = state["revisions"][0]
            revision["status"] = "approved"
            revision.pop("applyResult")
            revision.pop("appliedAt")
            state_path.write_text(json.dumps(state), encoding="utf-8")
            os.chmod(state_path, 0o600)

            recovered = daily_task_approval.apply(
                "2026-07-09", 1, db_path, root / "state", root / "backups"
            )
            repeated = daily_task_approval.apply(
                "2026-07-09", 1, db_path, root / "state", root / "backups"
            )

            self.assertEqual(recovered["insertedIDs"], [])
            self.assertEqual(recovered["skippedExistingIDs"], first["insertedIDs"])
            self.assertEqual(repeated, recovered)
            with closing(sqlite3.connect(db_path)) as db:
                self.assertEqual(db.execute("SELECT COUNT(*) FROM tasks").fetchone()[0], 1)

    def test_apply_reuses_persisted_pre_import_backup_after_final_state_write_crash(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            db_path = root / "meetings.sqlite"
            create_noteai_db(db_path)
            stage_and_approve(root)
            original_write = daily_task_approval._write_state_unlocked

            def fail_final_state_write(day, state_dir, state):
                current = daily_task_approval._active_revision(state)
                if current.get("status") == "applied":
                    raise OSError("simulated final state write crash")
                original_write(day, state_dir, state)

            with patch.object(
                daily_task_approval,
                "_write_state_unlocked",
                side_effect=fail_final_state_write,
            ):
                with self.assertRaisesRegex(OSError, "simulated final state write crash"):
                    daily_task_approval.apply(
                        "2026-07-09", 1, db_path, root / "state", root / "backups"
                    )

            state_path = root / "state" / "2026-07-09.json"
            state = json.loads(state_path.read_text(encoding="utf-8"))
            revision = state["revisions"][0]
            backup_path = Path(revision["backupPath"])
            self.assertEqual(revision["status"], "approved")
            self.assertEqual(
                [path.resolve() for path in (root / "backups").glob("*.sqlite")],
                [backup_path.resolve()],
            )
            with closing(sqlite3.connect(backup_path)) as backup:
                self.assertEqual(backup.execute("SELECT COUNT(*) FROM tasks").fetchone()[0], 0)
            with closing(sqlite3.connect(db_path)) as db:
                self.assertEqual(db.execute("SELECT COUNT(*) FROM tasks").fetchone()[0], 1)

            recovered = daily_task_approval.apply(
                "2026-07-09", 1, db_path, root / "state", root / "backups"
            )

            self.assertEqual(recovered["backupPath"], str(backup_path))
            self.assertEqual(
                [path.resolve() for path in (root / "backups").glob("*.sqlite")],
                [backup_path.resolve()],
            )
            with closing(sqlite3.connect(db_path)) as db:
                self.assertEqual(db.execute("SELECT COUNT(*) FROM tasks").fetchone()[0], 1)

    def test_apply_revalidates_slack_evidence_on_applied_replay(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            db_path = root / "meetings.sqlite"
            create_noteai_db(db_path)
            stage_and_approve(root)
            daily_task_approval.apply(
                "2026-07-09", 1, db_path, root / "state", root / "backups"
            )
            state_path = root / "state" / "2026-07-09.json"
            state = json.loads(state_path.read_text(encoding="utf-8"))
            state["revisions"][0]["approvalEvidence"]["actorUserID"] = "U0000000000"
            state_path.write_text(json.dumps(state), encoding="utf-8")
            os.chmod(state_path, 0o600)

            with self.assertRaisesRegex(daily_task_approval.ApprovalError, "authorized Slack user"):
                daily_task_approval.apply(
                    "2026-07-09", 1, db_path, root / "state", root / "backups"
                )

    def test_apply_revalidates_exact_approved_command_hash(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            db_path = root / "meetings.sqlite"
            create_noteai_db(db_path)
            stage_and_approve(root)
            daily_task_approval.apply(
                "2026-07-09", 1, db_path, root / "state", root / "backups"
            )
            state_path = root / "state" / "2026-07-09.json"
            state = json.loads(state_path.read_text(encoding="utf-8"))
            state["revisions"][0]["approvalEvidence"]["commandHash"] = "0" * 64
            state_path.write_text(json.dumps(state), encoding="utf-8")
            os.chmod(state_path, 0o600)

            with self.assertRaisesRegex(daily_task_approval.ApprovalError, "command hash"):
                daily_task_approval.apply(
                    "2026-07-09", 1, db_path, root / "state", root / "backups"
                )

    def test_apply_revalidates_approval_before_database_access(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            stage_and_approve(root)
            state_path = root / "state" / "2026-07-09.json"
            state = json.loads(state_path.read_text(encoding="utf-8"))
            state["revisions"][0]["approvalEvidence"]["commandHash"] = "0" * 64
            state_path.write_text(json.dumps(state), encoding="utf-8")
            os.chmod(state_path, 0o600)

            with self.assertRaisesRegex(daily_task_approval.ApprovalError, "command hash"):
                daily_task_approval.apply(
                    "2026-07-09",
                    1,
                    root / "missing.sqlite",
                    root / "state",
                    root / "backups",
                )

    def test_apply_retry_accepts_normalized_or_user_edited_presentation_fields(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            db_path = root / "meetings.sqlite"
            create_noteai_db(db_path)
            stage_and_approve(root)
            first = daily_task_approval.apply(
                "2026-07-09", 1, db_path, root / "state", root / "backups"
            )

            state_path = root / "state" / "2026-07-09.json"
            state = json.loads(state_path.read_text(encoding="utf-8"))
            revision = state["revisions"][0]
            revision["status"] = "approved"
            revision.pop("applyResult")
            revision.pop("appliedAt")
            state_path.write_text(json.dumps(state), encoding="utf-8")
            os.chmod(state_path, 0o600)
            with closing(sqlite3.connect(db_path)) as db:
                row = db.execute("SELECT id, json_data FROM tasks").fetchone()
                edited = json.loads(row[1])
                edited["title"] = "07/09/26 - User-renamed task"
                edited["description"] = "User-curated description"
                edited["status"] = "open"
                db.execute(
                    "UPDATE tasks SET title = ?, status = ?, json_data = ? WHERE id = ?",
                    (edited["title"], edited["status"], json.dumps(edited), row[0]),
                )
                db.commit()

            recovered = daily_task_approval.apply(
                "2026-07-09", 1, db_path, root / "state", root / "backups"
            )

            self.assertEqual(recovered["insertedIDs"], [])
            self.assertEqual(recovered["skippedExistingIDs"], first["insertedIDs"])
            with closing(sqlite3.connect(db_path)) as db:
                self.assertEqual(db.execute("SELECT COUNT(*) FROM tasks").fetchone()[0], 1)

    def test_concurrent_cross_date_import_backups_form_a_safe_sequence(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            db_path = root / "meetings.sqlite"
            create_noteai_db(db_path)
            stage_and_approve(root, "Imported first date", day="2026-07-09")
            stage_and_approve(
                root,
                "Imported second date",
                day="2026-07-10",
                delivery_message_ts="1720000000.000300",
                approval_message_ts="1720000000.000400",
            )

            context = multiprocessing.get_context("spawn")
            start_event = context.Event()
            result_queue = context.Queue()
            processes = [
                context.Process(
                    target=concurrent_apply_worker,
                    args=(str(root), day, start_event, result_queue),
                )
                for day in ("2026-07-09", "2026-07-10")
            ]
            for process in processes:
                process.start()
            start_event.set()
            results = [result_queue.get(timeout=15) for _ in processes]
            for process in processes:
                process.join(timeout=15)
                self.assertEqual(process.exitcode, 0)

            self.assertEqual([result["status"] for result in results], ["applied", "applied"])
            backup_counts = []
            for backup_path in (root / "backups").glob("*.sqlite"):
                with closing(sqlite3.connect(backup_path)) as backup:
                    backup_counts.append(
                        backup.execute("SELECT COUNT(*) FROM tasks").fetchone()[0]
                    )
            self.assertEqual(sorted(backup_counts), [0, 1])
            with closing(sqlite3.connect(db_path)) as db:
                self.assertEqual(db.execute("SELECT COUNT(*) FROM tasks").fetchone()[0], 2)
            lock_path = root / ".meetings.sqlite.daily-task-approval.lock"
            self.assertEqual(lock_path.stat().st_mode & 0o777, 0o600)

    def test_apply_imports_same_title_tasks_with_different_descriptions_idempotently(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            db_path = root / "meetings.sqlite"
            create_noteai_db(db_path)
            payload = candidate_payload()
            payload["tasks"] = [payload["tasks"][0], dict(payload["tasks"][0])]
            payload["tasks"][1]["description"] = "Documented the approval recovery contract."
            tasks_file = root / "tasks.json"
            tasks_file.write_text(json.dumps(payload), encoding="utf-8")
            daily_task_approval.stage("2026-07-09", tasks_file, root / "state")
            daily_task_approval.record_delivery(
                "2026-07-09", 1, "D123", "1720000000.000100", root / "state"
            )
            daily_task_approval.decide(
                "2026-07-09",
                1,
                "approved",
                JP_SLACK_USER_ID,
                SLACK_CHANNEL_ID,
                APPROVAL_MESSAGE_TS,
                approval_command("2026-07-09"),
                root / "state",
            )

            first = daily_task_approval.apply(
                "2026-07-09", 1, db_path, root / "state", root / "backups"
            )
            repeated = daily_task_approval.apply(
                "2026-07-09", 1, db_path, root / "state", root / "backups"
            )

            self.assertEqual(len(first["insertedIDs"]), 2)
            self.assertEqual(repeated, first)
            with closing(sqlite3.connect(db_path)) as db:
                rows = db.execute(
                    "SELECT source_action_item_id, json_data FROM tasks ORDER BY id"
                ).fetchall()
            self.assertEqual(len(rows), 2)
            self.assertEqual(len({row[0] for row in rows}), 2)
            self.assertEqual(
                {json.loads(row[1])["description"] for row in rows},
                {
                    "Implemented an approval-gated import that prevents duplicate tasks.",
                    "Documented the approval recovery contract.",
                },
            )

    def test_apply_deduplicates_existing_same_day_date_prefixed_title(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            db_path = root / "meetings.sqlite"
            create_noteai_db(db_path)
            noon = datetime(2026, 7, 9, 12, tzinfo=ZoneInfo("America/New_York")).timestamp()
            existing_json = {
                "id": "existing-task",
                "title": "July 9, 2026 - Delivered NoteAI approval workflow",
                "description": "Implemented an approval-gated import that prevents duplicate tasks.",
                "status": "completed",
                "workDate": noon - 978307200,
                "completedDate": noon - 978307200,
                "createdDate": noon - 978307200,
                "modifiedDate": noon - 978307200,
            }
            with closing(sqlite3.connect(db_path)) as db:
                db.execute(
                    "INSERT INTO tasks VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                    (
                        "existing-task",
                        existing_json["title"],
                        noon,
                        noon,
                        "completed",
                        noon,
                        noon,
                        None,
                        None,
                        None,
                        json.dumps(existing_json),
                    ),
                )
                db.commit()
            stage_and_approve(root)

            result = daily_task_approval.apply(
                "2026-07-09", 1, db_path, root / "state", root / "backups"
            )

            self.assertEqual(result["insertedIDs"], [])
            self.assertEqual(result["skippedExistingIDs"], ["existing-task"])
            with closing(sqlite3.connect(db_path)) as db:
                self.assertEqual(db.execute("SELECT COUNT(*) FROM tasks").fetchone()[0], 1)

    def test_apply_imports_changed_description_despite_legacy_same_day_title(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            db_path = root / "meetings.sqlite"
            create_noteai_db(db_path)
            noon = datetime(2026, 7, 9, 12, tzinfo=ZoneInfo("America/New_York")).timestamp()
            existing_json = {
                "id": "short-date-task",
                "title": "07/09/26 - Delivered NoteAI approval workflow",
                "description": "Existing manually curated detail.",
                "status": "completed",
                "workDate": noon - 978307200,
                "completedDate": noon - 978307200,
                "createdDate": noon - 978307200,
                "modifiedDate": noon - 978307200,
            }
            with closing(sqlite3.connect(db_path)) as db:
                db.execute(
                    "INSERT INTO tasks VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                    (
                        "short-date-task",
                        existing_json["title"],
                        noon,
                        noon,
                        "completed",
                        noon,
                        noon,
                        None,
                        None,
                        None,
                        json.dumps(existing_json),
                    ),
                )
                db.commit()
            stage_and_approve(root)

            result = daily_task_approval.apply(
                "2026-07-09", 1, db_path, root / "state", root / "backups"
            )

            self.assertEqual(len(result["insertedIDs"]), 1)
            self.assertEqual(result["skippedExistingIDs"], [])
            with closing(sqlite3.connect(db_path)) as db:
                self.assertEqual(db.execute("SELECT COUNT(*) FROM tasks").fetchone()[0], 2)

    def test_apply_fails_closed_when_import_key_provenance_conflicts(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            db_path = root / "meetings.sqlite"
            create_noteai_db(db_path)
            stage_and_approve(root)
            daily_task_approval.apply(
                "2026-07-09", 1, db_path, root / "state", root / "backups"
            )

            state_path = root / "state" / "2026-07-09.json"
            state = json.loads(state_path.read_text(encoding="utf-8"))
            revision = state["revisions"][0]
            revision["status"] = "approved"
            revision.pop("applyResult")
            revision.pop("appliedAt")
            state_path.write_text(json.dumps(state), encoding="utf-8")
            os.chmod(state_path, 0o600)
            with closing(sqlite3.connect(db_path)) as db:
                row = db.execute("SELECT id, json_data FROM tasks").fetchone()
                altered = json.loads(row[1])
                altered["sourceMetadata"]["messageID"] = "1720000000.999999"
                db.execute(
                    "UPDATE tasks SET json_data = ? WHERE id = ?",
                    (json.dumps(altered), row[0]),
                )
                db.commit()

            with self.assertRaisesRegex(daily_task_approval.ApprovalError, "import key conflict"):
                daily_task_approval.apply(
                    "2026-07-09", 1, db_path, root / "state", root / "backups"
                )


class DailyTaskApprovalExpirationAndCLITests(unittest.TestCase):
    def test_expire_marks_only_old_pending_revision_and_never_writes_noteai(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            db_path = root / "meetings.sqlite"
            create_noteai_db(db_path)
            tasks_file = root / "tasks.json"
            tasks_file.write_text(json.dumps(candidate_payload()), encoding="utf-8")
            daily_task_approval.stage("2026-07-09", tasks_file, root / "state")
            state_path = root / "state" / "2026-07-09.json"
            state = json.loads(state_path.read_text(encoding="utf-8"))
            state["revisions"][0]["createdAt"] = (
                datetime.now(timezone.utc) - timedelta(hours=49)
            ).isoformat()
            state_path.write_text(json.dumps(state), encoding="utf-8")
            os.chmod(state_path, 0o600)

            expired = daily_task_approval.expire(
                "2026-07-09", 1, 48, root / "state"
            )

            self.assertEqual(expired["revisions"][0]["status"], "expired")
            with closing(sqlite3.connect(db_path)) as db:
                self.assertEqual(db.execute("SELECT COUNT(*) FROM tasks").fetchone()[0], 0)
                self.assertEqual(db.execute("SELECT COUNT(*) FROM todos").fetchone()[0], 1)

    def test_expire_leaves_approved_and_not_yet_due_revisions_unchanged(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            stage_and_approve(root)

            approved = daily_task_approval.expire(
                "2026-07-09", 1, 48, root / "state"
            )

            self.assertEqual(approved["revisions"][0]["status"], "approved")

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            tasks_file = root / "tasks.json"
            tasks_file.write_text(json.dumps(candidate_payload()), encoding="utf-8")
            daily_task_approval.stage("2026-07-09", tasks_file, root / "state")

            pending = daily_task_approval.expire(
                "2026-07-09", 1, 48, root / "state"
            )

            self.assertEqual(pending["revisions"][0]["status"], "pending")

    def test_module_cli_stages_shows_and_renders_state(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            tasks_file = root / "tasks.json"
            state_dir = root / "state"
            tasks_file.write_text(json.dumps(candidate_payload()), encoding="utf-8")
            base = [sys.executable, "-m", "tools.work_activity.daily_task_approval"]

            staged = subprocess.run(
                base
                + [
                    "stage",
                    "--date",
                    "2026-07-09",
                    "--tasks-file",
                    str(tasks_file),
                    "--state-dir",
                    str(state_dir),
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            shown = subprocess.run(
                base + ["show", "--date", "2026-07-09", "--state-dir", str(state_dir)],
                check=False,
                capture_output=True,
                text=True,
            )
            rendered = subprocess.run(
                base + ["render", "--date", "2026-07-09", "--state-dir", str(state_dir)],
                check=False,
                capture_output=True,
                text=True,
            )

            self.assertEqual(staged.returncode, 0, staged.stderr)
            self.assertEqual(json.loads(staged.stdout)["activeRevision"], 1)
            self.assertEqual(shown.returncode, 0, shown.stderr)
            self.assertEqual(json.loads(shown.stdout)["date"], "2026-07-09")
            self.assertEqual(rendered.returncode, 0, rendered.stderr)
            self.assertIn("APPROVE 2026-07-09 R1", rendered.stdout)

    def test_decide_cli_requires_and_persists_slack_approval_evidence(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            tasks_file = root / "tasks.json"
            state_dir = root / "state"
            tasks_file.write_text(json.dumps(candidate_payload()), encoding="utf-8")
            daily_task_approval.stage("2026-07-09", tasks_file, state_dir)
            daily_task_approval.record_delivery(
                "2026-07-09", 1, SLACK_CHANNEL_ID, DELIVERY_MESSAGE_TS, state_dir
            )
            base = [sys.executable, "-m", "tools.work_activity.daily_task_approval"]
            decide_args = [
                "decide",
                "--date",
                "2026-07-09",
                "--revision",
                "1",
                "--decision",
                "approved",
                "--state-dir",
                str(state_dir),
            ]

            missing = subprocess.run(
                base + decide_args,
                check=False,
                capture_output=True,
                text=True,
            )
            valid = subprocess.run(
                base
                + decide_args
                + [
                    "--actor-user-id",
                    JP_SLACK_USER_ID,
                    "--channel-id",
                    SLACK_CHANNEL_ID,
                    "--approval-message-ts",
                    APPROVAL_MESSAGE_TS,
                    "--command-text",
                    approval_command("2026-07-09"),
                ],
                check=False,
                capture_output=True,
                text=True,
            )

            self.assertEqual(missing.returncode, 2)
            self.assertIn("--actor-user-id", missing.stderr)
            self.assertIn("--channel-id", missing.stderr)
            self.assertIn("--approval-message-ts", missing.stderr)
            self.assertIn("--command-text", missing.stderr)
            self.assertEqual(valid.returncode, 0, valid.stderr)
            self.assertEqual(
                json.loads(valid.stdout)["approvalEvidence"]["actorUserID"],
                JP_SLACK_USER_ID,
            )


if __name__ == "__main__":
    unittest.main()
