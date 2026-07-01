from __future__ import annotations

import json
import sqlite3
from datetime import datetime
from pathlib import Path

from ..models import ActivityItem, DateRange, SourceHealth, SourceKind, SourceQueryResult, SourceRef

DEFAULT_NOTEAI_DB = Path.home() / "Library/Application Support/NoteAI/meetings.sqlite"


class NoteAILocalConnector:
    def __init__(self, db_path: Path = DEFAULT_NOTEAI_DB) -> None:
        self.db_path = Path(db_path)

    def query(self, date_range: DateRange, query: str | None = None) -> SourceQueryResult:
        if not self.db_path.exists():
            return SourceQueryResult(
                source=SourceKind.NOTEAI,
                items=[],
                health=SourceHealth(SourceKind.NOTEAI, "unavailable", f"Database not found: {self.db_path}"),
            )
        try:
            uri = f"{self.db_path.resolve().as_uri()}?mode=ro"
            with sqlite3.connect(uri, uri=True) as db:
                db.row_factory = sqlite3.Row
                items = []
                items.extend(self._read_tasks(db, date_range))
                items.extend(self._read_todos(db, date_range))
                items.extend(self._read_meetings(db, date_range))
                items.sort(key=lambda item: (item.timestamp or date_range.start, item.title.lower()))
            return SourceQueryResult(
                source=SourceKind.NOTEAI,
                items=items,
                health=SourceHealth(SourceKind.NOTEAI, "available", f"Read {len(items)} NoteAI records"),
            )
        except sqlite3.Error as exc:
            return SourceQueryResult(
                source=SourceKind.NOTEAI,
                items=[],
                health=SourceHealth(SourceKind.NOTEAI, "unavailable", str(exc)),
            )

    def _epoch(self, value: float | int | None, date_range: DateRange) -> datetime | None:
        if value is None:
            return None
        return datetime.fromtimestamp(float(value), tz=date_range.start.tzinfo)

    def _in_range(self, dt: datetime | None, date_range: DateRange) -> bool:
        return dt is not None and date_range.start <= dt < date_range.end

    def _row_value(self, row: sqlite3.Row, column: str) -> object | None:
        if column not in row.keys():
            return None
        return row[column]

    def _decode_json_data(self, row: sqlite3.Row) -> dict[str, object]:
        raw = self._row_value(row, "json_data")
        if not raw:
            return {}
        try:
            decoded = json.loads(str(raw))
        except json.JSONDecodeError:
            return {}
        return decoded if isinstance(decoded, dict) else {}

    def _metadata(self, table: str, data: dict[str, object]) -> dict[str, object]:
        return {"table": table, "json_data": data}

    def _source_refs(
        self,
        primary_label: str,
        primary_id: object | None,
        row: sqlite3.Row,
        data: dict[str, object],
    ) -> list[SourceRef]:
        refs = [SourceRef(SourceKind.NOTEAI, primary_label, source_id=str(primary_id) if primary_id else None)]
        source_refs = [
            ("source_meeting_id", "sourceMeetingID", "NoteAI source meeting"),
            ("source_action_item_id", "sourceActionItemID", "NoteAI source action item"),
            ("source_note_id", "sourceNoteID", "NoteAI source note"),
        ]
        seen = {(refs[0].label, refs[0].source_id)}
        for column, json_key, label in source_refs:
            source_id = self._row_value(row, column) or data.get(json_key)
            if not source_id:
                continue
            ref = SourceRef(SourceKind.NOTEAI, label, source_id=str(source_id))
            identity = (ref.label, ref.source_id)
            if identity not in seen:
                refs.append(ref)
                seen.add(identity)
        return refs

    def _transcript_body(self, data: dict[str, object]) -> str:
        transcript = data.get("transcript")
        if isinstance(transcript, str):
            return transcript
        if not isinstance(transcript, list):
            return ""
        parts = []
        for segment in transcript:
            if isinstance(segment, dict):
                text = segment.get("text")
                if text:
                    parts.append(str(text))
            elif isinstance(segment, str):
                parts.append(segment)
        return " ".join(parts)

    def _read_tasks(self, db: sqlite3.Connection, date_range: DateRange) -> list[ActivityItem]:
        rows = db.execute(
            "SELECT * FROM tasks "
            "ORDER BY COALESCE(work_date, completed_date, created_date), title, id"
        ).fetchall()
        items = []
        for row in rows:
            data = self._decode_json_data(row)
            timestamp = self._epoch(
                self._row_value(row, "work_date")
                or self._row_value(row, "completed_date")
                or self._row_value(row, "created_date"),
                date_range,
            )
            if not self._in_range(timestamp, date_range):
                continue
            items.append(
                ActivityItem(
                    source=SourceKind.NOTEAI,
                    timestamp=timestamp,
                    title=str(self._row_value(row, "title") or data.get("title") or "Untitled task"),
                    body=str(data.get("description") or ""),
                    status=str(self._row_value(row, "status") or data.get("status") or "") or None,
                    source_refs=self._source_refs("NoteAI task", self._row_value(row, "id"), row, data),
                    raw_metadata=self._metadata("tasks", data),
                )
            )
        return items

    def _read_todos(self, db: sqlite3.Connection, date_range: DateRange) -> list[ActivityItem]:
        rows = db.execute(
            "SELECT * FROM todos ORDER BY COALESCE(due_date, created_date), title, id"
        ).fetchall()
        items = []
        for row in rows:
            data = self._decode_json_data(row)
            due = self._epoch(self._row_value(row, "due_date"), date_range)
            timestamp = due or self._epoch(self._row_value(row, "created_date"), date_range)
            if not self._in_range(timestamp, date_range):
                continue
            status = "completed" if int(row["completed"] or 0) else "open"
            items.append(
                ActivityItem(
                    source=SourceKind.NOTEAI,
                    timestamp=timestamp,
                    title=str(self._row_value(row, "title") or data.get("title") or "Untitled todo"),
                    body=str(data.get("description") or ""),
                    status=status,
                    due_date=due,
                    source_refs=self._source_refs("NoteAI todo", self._row_value(row, "id"), row, data),
                    raw_metadata=self._metadata("todos", data),
                )
            )
        return items

    def _read_meetings(self, db: sqlite3.Connection, date_range: DateRange) -> list[ActivityItem]:
        rows = db.execute(
            "SELECT * FROM meetings ORDER BY date, title, id"
        ).fetchall()
        items = []
        for row in rows:
            data = self._decode_json_data(row)
            timestamp = self._epoch(self._row_value(row, "date"), date_range)
            if not self._in_range(timestamp, date_range):
                continue
            items.append(
                ActivityItem(
                    source=SourceKind.NOTEAI,
                    timestamp=timestamp,
                    title=str(self._row_value(row, "title") or data.get("title") or "Untitled meeting"),
                    body=self._transcript_body(data),
                    source_refs=self._source_refs("NoteAI meeting", self._row_value(row, "id"), row, data),
                    raw_metadata=self._metadata("meetings", data),
                )
            )
        return items
