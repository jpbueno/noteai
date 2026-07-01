import json
import sqlite3
import tempfile
import unittest
from pathlib import Path

from tools.work_activity.connectors.noteai import NoteAILocalConnector
from tools.work_activity.date_ranges import day_range
from tools.work_activity.models import SourceKind


def create_fixture_db(path: Path) -> None:
    db = sqlite3.connect(path)
    try:
        db.execute(
            "CREATE TABLE meetings ("
            "id TEXT PRIMARY KEY, title TEXT NOT NULL, date REAL NOT NULL, "
            "duration REAL NOT NULL, json_data TEXT NOT NULL)"
        )
        db.execute(
            "CREATE TABLE todos ("
            "id TEXT PRIMARY KEY, title TEXT NOT NULL, created_date REAL NOT NULL, "
            "modified_date REAL NOT NULL, completed INTEGER NOT NULL DEFAULT 0, "
            "due_date REAL, json_data TEXT NOT NULL)"
        )
        db.execute(
            "CREATE TABLE tasks ("
            "id TEXT PRIMARY KEY, title TEXT NOT NULL, created_date REAL NOT NULL, "
            "modified_date REAL NOT NULL, status TEXT NOT NULL DEFAULT 'open', "
            "work_date REAL, completed_date REAL, source_meeting_id TEXT, "
            "source_action_item_id TEXT, source_note_id TEXT, json_data TEXT NOT NULL)"
        )
        work_date = 1782925200
        task_json = {
            "id": "task-1",
            "title": "Follow up with Nscale",
            "description": "Confirm runtime owner from decoded task JSON.",
            "status": "open",
            "workDate": 804517200,
            "completedDate": None,
            "sourceMeetingID": "meeting-1",
            "sourceActionItemID": "action-1",
            "sourceNoteID": "note-1",
            "sourceMetadata": {"account": "Nscale"},
            "owner": "JP",
            "createdDate": 804513600,
            "modifiedDate": 804513900,
        }
        todo_json = {
            "id": "todo-1",
            "title": "Ping Crusoe",
            "description": "Ask about benchmark capacity from decoded todo JSON.",
            "completed": False,
            "dueDate": 804517200,
            "sourceMeetingID": "meeting-1",
            "sourceActionItemID": "action-2",
            "owner": "JP",
            "createdDate": 804513600,
            "modifiedDate": 804513900,
        }
        meeting_json = {
            "id": "meeting-1",
            "title": "Nscale Sync",
            "date": 804517200,
            "duration": 1800,
            "transcript": [
                {"speaker": "JP", "text": "Discussed Dynamo PoC runtime ownership."},
                {"speaker": "Alex", "text": "Nscale will confirm the owner."},
            ],
            "summary": {"decisions": ["Follow up on runtime owner"]},
        }
        db.execute(
            "INSERT INTO tasks VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (
                "task-1",
                "Follow up with Nscale",
                work_date,
                work_date,
                "open",
                work_date,
                None,
                "meeting-1",
                "action-1",
                "note-1",
                json.dumps(task_json),
            ),
        )
        db.execute(
            "INSERT INTO tasks VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (
                "task-2",
                "Earlier task",
                work_date - 3600,
                work_date - 3600,
                "open",
                work_date - 3600,
                None,
                None,
                None,
                None,
                json.dumps({"description": "Earlier deterministic ordering task."}),
            ),
        )
        db.execute(
            "INSERT INTO todos VALUES (?, ?, ?, ?, ?, ?, ?)",
            (
                "todo-1",
                "Ping Crusoe",
                work_date,
                work_date,
                0,
                work_date,
                json.dumps(todo_json),
            ),
        )
        db.execute(
            "INSERT INTO meetings VALUES (?, ?, ?, ?, ?)",
            ("meeting-1", "Nscale Sync", work_date, 1800, json.dumps(meeting_json)),
        )
        db.commit()
    finally:
        db.close()


class NoteAIConnectorTests(unittest.TestCase):
    def test_reads_tasks_todos_and_meetings_as_activity(self):
        with tempfile.TemporaryDirectory() as tmp:
            db_path = Path(tmp) / "meetings.sqlite"
            create_fixture_db(db_path)
            connector = NoteAILocalConnector(db_path)
            result = connector.query(day_range("2026-07-01"))
            self.assertEqual(result.health.status, "available")
            self.assertEqual(result.source, SourceKind.NOTEAI)
            items = {item.title: item for item in result.items}
            self.assertEqual(
                [item.title for item in result.items],
                ["Earlier task", "Follow up with Nscale", "Nscale Sync", "Ping Crusoe"],
            )
            self.assertIn("Follow up with Nscale", items)
            self.assertIn("Ping Crusoe", items)
            self.assertIn("Nscale Sync", items)

            task = items["Follow up with Nscale"]
            self.assertEqual(task.body, "Confirm runtime owner from decoded task JSON.")
            task_refs = {(ref.label, ref.source_id) for ref in task.source_refs}
            self.assertIn(("NoteAI task", "task-1"), task_refs)
            self.assertIn(("NoteAI source meeting", "meeting-1"), task_refs)
            self.assertIn(("NoteAI source action item", "action-1"), task_refs)
            self.assertIn(("NoteAI source note", "note-1"), task_refs)
            self.assertEqual(task.raw_metadata["table"], "tasks")
            self.assertEqual(task.raw_metadata["json_data"]["sourceMetadata"]["account"], "Nscale")

            todo = items["Ping Crusoe"]
            self.assertEqual(todo.body, "Ask about benchmark capacity from decoded todo JSON.")
            self.assertEqual(todo.raw_metadata["table"], "todos")
            self.assertEqual(todo.raw_metadata["json_data"]["sourceMeetingID"], "meeting-1")

            meeting = items["Nscale Sync"]
            self.assertEqual(
                meeting.body,
                "Discussed Dynamo PoC runtime ownership. Nscale will confirm the owner.",
            )
            self.assertEqual(meeting.raw_metadata["table"], "meetings")
            self.assertEqual(meeting.raw_metadata["json_data"]["summary"]["decisions"], ["Follow up on runtime owner"])

    def test_missing_database_reports_unavailable(self):
        connector = NoteAILocalConnector(Path("/tmp/does-not-exist-noteai.sqlite"))
        result = connector.query(day_range("2026-07-01"))
        self.assertEqual(result.health.status, "unavailable")
        self.assertEqual(result.items, [])
