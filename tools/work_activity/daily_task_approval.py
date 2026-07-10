from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
import re
import sqlite3
import sys
import tempfile
import uuid
from contextlib import closing, contextmanager
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from typing import Iterator
from zoneinfo import ZoneInfo


SCHEMA_VERSION = 1
INPUT_COLUMNS = {"tasks", "sourceHealth"}
TASK_COLUMNS = {"title", "description", "sources", "dueDate", "priority"}
NOTEAI_TASK_COLUMNS = {
    "id",
    "title",
    "created_date",
    "modified_date",
    "status",
    "work_date",
    "completed_date",
    "source_meeting_id",
    "source_action_item_id",
    "source_note_id",
    "json_data",
}
APPLE_REFERENCE_UNIX = 978307200.0
NEW_YORK = ZoneInfo("America/New_York")
IMPORT_NAMESPACE = uuid.UUID("22d8ead8-19a2-4e76-9ae4-303deaaad377")
DATE_PREFIX = re.compile(
    r"^(?:(?:January|February|March|April|May|June|July|August|September|October|November|December)"
    r"\s+\d{1,2},\s+\d{4}|\d{1,2}/\d{1,2}/(?:\d{2}|\d{4})|\d{4}-\d{2}-\d{2})"
    r"\s*[-\u2013\u2014:]\s*",
    re.IGNORECASE,
)


class ApprovalError(RuntimeError):
    """Raised when approval state or imported data violates the workflow contract."""


def _validated_date(value: str) -> str:
    try:
        parsed = date.fromisoformat(value)
    except ValueError as exc:
        raise ApprovalError(f"invalid date: {value}") from exc
    if parsed.isoformat() != value:
        raise ApprovalError(f"date must use YYYY-MM-DD: {value}")
    return value


def _clean_text(value: object, field: str) -> str:
    if not isinstance(value, str):
        raise ApprovalError(f"{field} must be a string")
    cleaned = " ".join(value.split())
    if not cleaned:
        raise ApprovalError(f"{field} must not be empty")
    return cleaned


def _canonical_payload(raw: object) -> dict[str, object]:
    if not isinstance(raw, dict) or set(raw) != INPUT_COLUMNS:
        raise ApprovalError(f"input columns must be exactly {sorted(INPUT_COLUMNS)}")
    tasks = raw["tasks"]
    source_health = raw["sourceHealth"]
    if not isinstance(tasks, list):
        raise ApprovalError("tasks must be a list")
    if not isinstance(source_health, dict) or not all(
        isinstance(key, str) and isinstance(value, str) for key, value in source_health.items()
    ):
        raise ApprovalError("sourceHealth must map source names to status strings")

    canonical_by_identity: dict[str, dict[str, object]] = {}
    for index, task in enumerate(tasks):
        if not isinstance(task, dict) or set(task) != TASK_COLUMNS:
            raise ApprovalError(
                f"task columns at index {index} must be exactly {sorted(TASK_COLUMNS)}"
            )
        title = _clean_text(task["title"], f"tasks[{index}].title")
        description = _clean_text(task["description"], f"tasks[{index}].description")
        sources = task["sources"]
        if not isinstance(sources, list) or not all(isinstance(source, str) for source in sources):
            raise ApprovalError(f"tasks[{index}].sources must be a list of strings")
        clean_sources = sorted({_clean_text(source, f"tasks[{index}].sources") for source in sources})
        due_date = task["dueDate"]
        priority = task["priority"]
        if due_date is not None and not isinstance(due_date, str):
            raise ApprovalError(f"tasks[{index}].dueDate must be a string or null")
        if priority is not None and not isinstance(priority, (str, int, float)):
            raise ApprovalError(f"tasks[{index}].priority must be a scalar or null")
        canonical = {
            "title": title,
            "description": description,
            "sources": clean_sources,
            "dueDate": due_date,
            "priority": priority,
        }
        identity_fields = {
            "title": title,
            "description": description,
            "dueDate": due_date,
            "priority": priority,
        }
        identity = json.dumps(
            identity_fields, sort_keys=True, separators=(",", ":"), ensure_ascii=True
        )
        existing = canonical_by_identity.get(identity)
        if existing is not None:
            existing["sources"] = sorted(set(existing["sources"]) | set(clean_sources))
            continue
        canonical_by_identity[identity] = canonical

    canonical_tasks = list(canonical_by_identity.values())
    if not canonical_tasks:
        raise ApprovalError("at least one task is required")
    return {
        "tasks": canonical_tasks,
        "sourceHealth": {key: source_health[key] for key in sorted(source_health)},
    }


def _content_hash(payload: dict[str, object]) -> str:
    encoded = json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode()
    return hashlib.sha256(encoded).hexdigest()


def _state_path(day: str, state_dir: Path) -> Path:
    return state_dir / f"{day}.json"


@contextmanager
def _state_lock(day: str, state_dir: Path) -> Iterator[None]:
    state_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(state_dir, 0o700)
    lock_path = state_dir / f".{day}.lock"
    descriptor = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o600)
    try:
        os.fchmod(descriptor, 0o600)
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        yield
    finally:
        fcntl.flock(descriptor, fcntl.LOCK_UN)
        os.close(descriptor)


def _read_state_unlocked(day: str, state_dir: Path) -> dict[str, object] | None:
    path = _state_path(day, state_dir)
    if not path.exists():
        return None
    try:
        state = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ApprovalError(f"cannot read approval state for {day}") from exc
    if not isinstance(state, dict) or state.get("schemaVersion") != SCHEMA_VERSION:
        raise ApprovalError(f"unsupported approval state schema for {day}")
    return state


def _write_state_unlocked(day: str, state_dir: Path, state: dict[str, object]) -> None:
    state_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    path = _state_path(day, state_dir)
    descriptor, temp_name = tempfile.mkstemp(prefix=f".{day}.", suffix=".tmp", dir=state_dir)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump(state, stream, indent=2, sort_keys=True, ensure_ascii=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temp_name, path)
        os.chmod(path, 0o600)
    except Exception:
        try:
            os.unlink(temp_name)
        except FileNotFoundError:
            pass
        raise


def _active_revision(state: dict[str, object]) -> dict[str, object]:
    active = state["activeRevision"]
    revisions = state["revisions"]
    if not isinstance(active, int) or not isinstance(revisions, list):
        raise ApprovalError("approval state is malformed")
    for revision in revisions:
        if isinstance(revision, dict) and revision.get("revision") == active:
            return revision
    raise ApprovalError("active approval revision is missing")


def _require_state_unlocked(day: str, state_dir: Path) -> dict[str, object]:
    state = _read_state_unlocked(day, state_dir)
    if state is None:
        raise ApprovalError(f"approval state does not exist for {day}")
    if state.get("date") != day:
        raise ApprovalError("approval state date does not match its file name")
    return state


def _require_active_number(state: dict[str, object], revision: int) -> dict[str, object]:
    if not isinstance(revision, int) or revision < 1:
        raise ApprovalError("revision must be a positive integer")
    if state.get("activeRevision") != revision:
        raise ApprovalError(
            f"stale revision R{revision}; active revision is R{state.get('activeRevision')}"
        )
    return _active_revision(state)


def stage(day: str, tasks_file: Path, state_dir: Path) -> dict[str, object]:
    day = _validated_date(day)
    tasks_file = Path(tasks_file)
    state_dir = Path(state_dir)
    try:
        raw = json.loads(tasks_file.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ApprovalError("candidate tasks file is not valid JSON") from exc
    payload = _canonical_payload(raw)
    digest = _content_hash(payload)

    with _state_lock(day, state_dir):
        state = _read_state_unlocked(day, state_dir)
        if state is None:
            state = {
                "schemaVersion": SCHEMA_VERSION,
                "date": day,
                "activeRevision": 0,
                "revisions": [],
            }
        elif state.get("date") != day:
            raise ApprovalError("approval state date does not match its file name")

        current = _active_revision(state) if state["activeRevision"] else None
        if current is not None and current.get("contentHash") == digest:
            return state
        if current is not None and current.get("status") not in {
            "pending",
            "rejected",
            "needs_revision",
        }:
            raise ApprovalError(f"cannot revise {current.get('status')} approval state")

        now = datetime.now(timezone.utc).isoformat()
        revision_number = int(state["activeRevision"]) + 1
        revision = {
            "revision": revision_number,
            "status": "pending",
            "contentHash": digest,
            "tasks": payload["tasks"],
            "sourceHealth": payload["sourceHealth"],
            "createdAt": now,
            "updatedAt": now,
        }
        state["activeRevision"] = revision_number
        state["revisions"].append(revision)
        _write_state_unlocked(day, state_dir, state)
        return state


def show(day: str, state_dir: Path) -> dict[str, object]:
    day = _validated_date(day)
    state_dir = Path(state_dir)
    with _state_lock(day, state_dir):
        return _require_state_unlocked(day, state_dir)


def render(day: str, state_dir: Path) -> str:
    state = show(day, state_dir)
    revision = _active_revision(state)
    revision_number = revision["revision"]
    lines = [f"Daily task summary - {day} (R{revision_number})", ""]
    for index, task in enumerate(revision["tasks"], start=1):
        lines.append(f"{index}. {task['title']}")
        lines.append(f"   {task['description']}")
        if task["sources"]:
            lines.append(f"   Sources: {', '.join(task['sources'])}")
        lines.append("")
    lines.extend(
        [
            f"APPROVE {day} R{revision_number}",
            f"REJECT {day} R{revision_number}",
            f"EDIT {day} R{revision_number}: <requested changes>",
        ]
    )
    return "\n".join(lines)


def record_delivery(
    day: str,
    revision: int,
    channel_id: str,
    message_ts: str,
    state_dir: Path,
) -> dict[str, object]:
    day = _validated_date(day)
    state_dir = Path(state_dir)
    channel_id = _clean_text(channel_id, "channel ID")
    message_ts = _clean_text(message_ts, "message timestamp")
    delivery = {"channelID": channel_id, "messageTS": message_ts}
    with _state_lock(day, state_dir):
        state = _require_state_unlocked(day, state_dir)
        current = _require_active_number(state, revision)
        existing = current.get("delivery")
        if existing is not None and existing != delivery:
            raise ApprovalError("delivery reference is already bound to a different Slack message")
        if existing == delivery:
            return state
        if current.get("status") != "pending":
            raise ApprovalError(f"cannot record delivery for {current.get('status')} revision")
        current["delivery"] = delivery
        current["updatedAt"] = datetime.now(timezone.utc).isoformat()
        _write_state_unlocked(day, state_dir, state)
        return state


def decide(
    day: str,
    revision: int,
    decision: str,
    state_dir: Path,
) -> dict[str, object]:
    day = _validated_date(day)
    state_dir = Path(state_dir)
    if decision not in {"approved", "rejected", "needs_revision"}:
        raise ApprovalError(f"unsupported decision: {decision}")
    with _state_lock(day, state_dir):
        state = _require_state_unlocked(day, state_dir)
        current = _require_active_number(state, revision)
        if current.get("status") != "pending":
            raise ApprovalError(
                f"illegal transition from {current.get('status')} to {decision}"
            )
        if not isinstance(current.get("delivery"), dict):
            raise ApprovalError("cannot decide before Slack delivery is recorded")
        now = datetime.now(timezone.utc).isoformat()
        current["status"] = decision
        current["decidedAt"] = now
        current["updatedAt"] = now
        _write_state_unlocked(day, state_dir, state)
        return state


def _normalized_title_core(title: str) -> str:
    without_date = DATE_PREFIX.sub("", " ".join(title.split()))
    return " ".join(re.sub(r"[^a-z0-9]+", " ", without_date.lower()).split())


def _import_key(day: str, title: str) -> str:
    core = _normalized_title_core(title)
    if not core:
        raise ApprovalError("task title has no usable import identity")
    digest = hashlib.sha256(core.encode("utf-8")).hexdigest()[:32]
    return f"codex-daily-task-summary:{day}:{digest}"


def _noon_timestamps(day: str) -> tuple[float, float]:
    parsed = date.fromisoformat(day)
    noon = datetime(parsed.year, parsed.month, parsed.day, 12, tzinfo=NEW_YORK)
    unix_value = noon.timestamp()
    return unix_value, unix_value - APPLE_REFERENCE_UNIX


def _backup_database(
    backup_dir: Path,
    day: str,
    revision: int,
    db: sqlite3.Connection,
) -> Path:
    backup_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(backup_dir, 0o700)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    backup_path = backup_dir / f"meetings-before-{day}-r{revision}-{stamp}.sqlite"
    with closing(sqlite3.connect(backup_path)) as backup:
        db.backup(backup)
    os.chmod(backup_path, 0o600)
    return backup_path


def _expected_task(
    day: str,
    task: dict[str, object],
    delivery: dict[str, object],
    now_unix: float,
) -> dict[str, object]:
    import_key = _import_key(day, str(task["title"]))
    task_id = str(uuid.uuid5(IMPORT_NAMESPACE, import_key)).upper()
    noon_unix, noon_apple = _noon_timestamps(day)
    now_apple = now_unix - APPLE_REFERENCE_UNIX
    task_json = {
        "id": task_id,
        "title": task["title"],
        "description": task["description"],
        "status": "completed",
        "workDate": noon_apple,
        "completedDate": noon_apple,
        "sourceActionItemID": import_key,
        "sourceMetadata": {
            "kind": "unknown",
            "provider": "Codex Daily Task Summary",
            "threadID": delivery["channelID"],
            "messageID": delivery["messageTS"],
            "subject": f"Daily Task Summary {day}",
        },
        "owner": "JP",
        "createdDate": now_apple,
        "modifiedDate": now_apple,
    }
    return {
        "id": task_id,
        "title": task["title"],
        "description": task["description"],
        "status": "completed",
        "workDateUnix": noon_unix,
        "completedDateUnix": noon_unix,
        "importKey": import_key,
        "json": task_json,
        "createdUnix": now_unix,
        "modifiedUnix": now_unix,
    }


def _float_matches(value: object, expected: float) -> bool:
    try:
        return abs(float(value) - expected) < 0.001
    except (TypeError, ValueError):
        return False


def _assert_import_row_matches(row: sqlite3.Row, expected: dict[str, object]) -> None:
    try:
        task_json = json.loads(str(row["json_data"]))
    except json.JSONDecodeError as exc:
        raise ApprovalError(f"import key conflict for {expected['importKey']}") from exc
    metadata = task_json.get("sourceMetadata") if isinstance(task_json, dict) else None
    expected_json = expected["json"]
    expected_metadata = expected_json["sourceMetadata"]
    matches = (
        row["id"] == expected["id"]
        and row["title"] == expected["title"]
        and row["status"] == "completed"
        and _float_matches(row["work_date"], float(expected["workDateUnix"]))
        and _float_matches(row["completed_date"], float(expected["completedDateUnix"]))
        and row["source_action_item_id"] == expected["importKey"]
        and isinstance(task_json, dict)
        and task_json.get("id") == expected["id"]
        and task_json.get("title") == expected["title"]
        and task_json.get("description") == expected["description"]
        and task_json.get("status") == "completed"
        and _float_matches(task_json.get("workDate"), float(expected["json"]["workDate"]))
        and _float_matches(task_json.get("completedDate"), float(expected["json"]["completedDate"]))
        and task_json.get("sourceActionItemID") == expected["importKey"]
        and task_json.get("owner") == "JP"
        and isinstance(metadata, dict)
        and metadata.get("provider") == expected_metadata["provider"]
        and metadata.get("threadID") == expected_metadata["threadID"]
        and metadata.get("messageID") == expected_metadata["messageID"]
        and metadata.get("subject") == expected_metadata["subject"]
    )
    if not matches:
        raise ApprovalError(f"import key conflict for {expected['importKey']}")


def _row_is_same_day_title(row: sqlite3.Row, day: str, title: str) -> bool:
    timestamp = row["work_date"] or row["completed_date"] or row["created_date"]
    if timestamp is None:
        return False
    try:
        row_day = datetime.fromtimestamp(float(timestamp), tz=NEW_YORK).date().isoformat()
    except (OSError, OverflowError, TypeError, ValueError):
        return False
    return row_day == day and _normalized_title_core(str(row["title"])) == _normalized_title_core(title)


def apply(
    day: str,
    revision: int,
    database: Path,
    state_dir: Path,
    backup_dir: Path,
) -> dict[str, object]:
    day = _validated_date(day)
    database = Path(database)
    state_dir = Path(state_dir)
    backup_dir = Path(backup_dir)
    with _state_lock(day, state_dir):
        state = _require_state_unlocked(day, state_dir)
        current = _require_active_number(state, revision)
        if current.get("status") == "applied":
            result = current.get("applyResult")
            if not isinstance(result, dict):
                raise ApprovalError("applied revision is missing its result")
            return result
        if current.get("status") != "approved":
            raise ApprovalError("revision must be approved before apply")
        delivery = current.get("delivery")
        if not isinstance(delivery, dict):
            raise ApprovalError("approved revision has no bound Slack delivery")
        if not database.is_file():
            raise ApprovalError(f"NoteAI database does not exist: {database}")

        inserted_ids: list[str] = []
        skipped_ids: list[str] = []
        now_unix = datetime.now(timezone.utc).timestamp()
        expected_tasks = [
            _expected_task(day, task, delivery, now_unix) for task in current["tasks"]
        ]
        import_keys = [str(task["importKey"]) for task in expected_tasks]
        if len(import_keys) != len(set(import_keys)):
            raise ApprovalError("candidate tasks produce duplicate deterministic import keys")

        with closing(sqlite3.connect(database)) as db:
            db.row_factory = sqlite3.Row
            schema = {row[1] for row in db.execute("PRAGMA table_info(tasks)").fetchall()}
            if schema != NOTEAI_TASK_COLUMNS:
                raise ApprovalError(
                    f"unexpected tasks schema: expected {sorted(NOTEAI_TASK_COLUMNS)}, got {sorted(schema)}"
                )
            backup_path = _backup_database(backup_dir, day, revision, db)
            try:
                db.execute("BEGIN IMMEDIATE")
                existing_rows = db.execute("SELECT * FROM tasks").fetchall()
                for expected in expected_tasks:
                    keyed = [
                        row
                        for row in existing_rows
                        if row["source_action_item_id"] == expected["importKey"]
                    ]
                    if len(keyed) > 1:
                        raise ApprovalError(f"import key conflict for {expected['importKey']}")
                    if keyed:
                        _assert_import_row_matches(keyed[0], expected)
                        skipped_ids.append(str(keyed[0]["id"]))
                        continue
                    same_day = [
                        row
                        for row in existing_rows
                        if _row_is_same_day_title(row, day, str(expected["title"]))
                    ]
                    if len(same_day) > 1:
                        raise ApprovalError(
                            f"multiple same-day tasks match title: {expected['title']}"
                        )
                    if same_day:
                        skipped_ids.append(str(same_day[0]["id"]))
                        continue
                    db.execute(
                        "INSERT INTO tasks (id, title, created_date, modified_date, status, "
                        "work_date, completed_date, source_meeting_id, source_action_item_id, "
                        "source_note_id, json_data) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                        (
                            expected["id"],
                            expected["title"],
                            expected["createdUnix"],
                            expected["modifiedUnix"],
                            "completed",
                            expected["workDateUnix"],
                            expected["completedDateUnix"],
                            None,
                            expected["importKey"],
                            None,
                            json.dumps(expected["json"], sort_keys=True, separators=(",", ":")),
                        ),
                    )
                    inserted_ids.append(str(expected["id"]))
                    existing_rows.append(
                        db.execute("SELECT * FROM tasks WHERE id = ?", (expected["id"],)).fetchone()
                    )
                db.commit()
            except Exception:
                db.rollback()
                raise

        result = {
            "date": day,
            "revision": revision,
            "insertedIDs": inserted_ids,
            "skippedExistingIDs": skipped_ids,
            "backupPath": str(backup_path),
        }
        now = datetime.now(timezone.utc).isoformat()
        current["status"] = "applied"
        current["appliedAt"] = now
        current["updatedAt"] = now
        current["applyResult"] = result
        _write_state_unlocked(day, state_dir, state)
        return result


def expire(
    day: str,
    revision: int,
    after_hours: int,
    state_dir: Path,
) -> dict[str, object]:
    day = _validated_date(day)
    if not isinstance(after_hours, int) or after_hours < 0:
        raise ApprovalError("after-hours must be a nonnegative integer")
    state_dir = Path(state_dir)
    with _state_lock(day, state_dir):
        state = _require_state_unlocked(day, state_dir)
        current = _require_active_number(state, revision)
        if current.get("status") != "pending":
            return state
        try:
            created_at = datetime.fromisoformat(str(current["createdAt"]))
        except (KeyError, ValueError) as exc:
            raise ApprovalError("pending revision has an invalid creation timestamp") from exc
        if created_at.tzinfo is None:
            raise ApprovalError("pending revision creation timestamp must include a timezone")
        now = datetime.now(timezone.utc)
        if now < created_at.astimezone(timezone.utc) + timedelta(hours=after_hours):
            return state
        now_text = now.isoformat()
        current["status"] = "expired"
        current["expiredAt"] = now_text
        current["updatedAt"] = now_text
        _write_state_unlocked(day, state_dir, state)
        return state


def _sanitized_state(state: dict[str, object]) -> dict[str, object]:
    current = _active_revision(state)
    result: dict[str, object] = {
        "schemaVersion": state["schemaVersion"],
        "date": state["date"],
        "activeRevision": state["activeRevision"],
        "status": current["status"],
        "taskCount": len(current["tasks"]),
        "sourceHealth": current["sourceHealth"],
    }
    for key in ("delivery", "createdAt", "updatedAt", "decidedAt", "expiredAt", "appliedAt", "applyResult"):
        if key in current:
            result[key] = current[key]
    return result


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Approval-gated NoteAI daily task import")
    commands = parser.add_subparsers(dest="command", required=True)

    def common(command: argparse.ArgumentParser) -> None:
        command.add_argument("--date", required=True)
        command.add_argument("--state-dir", type=Path, required=True)

    stage_parser = commands.add_parser("stage")
    common(stage_parser)
    stage_parser.add_argument("--tasks-file", type=Path, required=True)

    common(commands.add_parser("show"))
    common(commands.add_parser("render"))

    delivery_parser = commands.add_parser("record-delivery")
    common(delivery_parser)
    delivery_parser.add_argument("--revision", type=int, required=True)
    delivery_parser.add_argument("--channel-id", required=True)
    delivery_parser.add_argument("--message-ts", required=True)

    decide_parser = commands.add_parser("decide")
    common(decide_parser)
    decide_parser.add_argument("--revision", type=int, required=True)
    decide_parser.add_argument(
        "--decision", choices=("approved", "rejected", "needs_revision"), required=True
    )

    apply_parser = commands.add_parser("apply")
    common(apply_parser)
    apply_parser.add_argument("--revision", type=int, required=True)
    apply_parser.add_argument("--database", type=Path, required=True)
    apply_parser.add_argument("--backup-dir", type=Path, required=True)

    expire_parser = commands.add_parser("expire")
    common(expire_parser)
    expire_parser.add_argument("--revision", type=int, required=True)
    expire_parser.add_argument("--after-hours", type=int, required=True)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        if args.command == "stage":
            output: object = _sanitized_state(stage(args.date, args.tasks_file, args.state_dir))
        elif args.command == "show":
            output = _sanitized_state(show(args.date, args.state_dir))
        elif args.command == "render":
            print(render(args.date, args.state_dir))
            return 0
        elif args.command == "record-delivery":
            output = _sanitized_state(
                record_delivery(
                    args.date,
                    args.revision,
                    args.channel_id,
                    args.message_ts,
                    args.state_dir,
                )
            )
        elif args.command == "decide":
            output = _sanitized_state(
                decide(args.date, args.revision, args.decision, args.state_dir)
            )
        elif args.command == "apply":
            output = apply(
                args.date,
                args.revision,
                args.database,
                args.state_dir,
                args.backup_dir,
            )
        elif args.command == "expire":
            output = _sanitized_state(
                expire(args.date, args.revision, args.after_hours, args.state_dir)
            )
        else:  # pragma: no cover - argparse enforces the command set.
            raise ApprovalError(f"unsupported command: {args.command}")
    except ApprovalError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    print(json.dumps(output, sort_keys=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
