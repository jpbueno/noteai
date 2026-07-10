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
from contextlib import ExitStack, closing, contextmanager
from datetime import date, datetime, timedelta, timezone
from decimal import Decimal, InvalidOperation
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
JP_SLACK_USER_ID = "U09BXNGD81L"
SLACK_TIMESTAMP = re.compile(r"^[0-9]+\.[0-9]{6}$")
SLACK_DM_CONVERSATION_ID = re.compile(r"^D[A-Z0-9]+$")
APPLY_PHASE_BACKUP_READY = "backup_ready"
APPLY_PHASE_TRANSACTION_STARTED = "transaction_started"
APPLY_PHASE_COMMITTED = "committed"
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


def _candidate_identity(task: dict[str, object]) -> str:
    identity_fields = {
        "title": task["title"],
        "description": task["description"],
        "dueDate": task["dueDate"],
        "priority": task["priority"],
    }
    return json.dumps(
        identity_fields, sort_keys=True, separators=(",", ":"), ensure_ascii=True
    )


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
        if due_date is not None:
            raise ApprovalError(f"tasks[{index}].dueDate must be null")
        if priority is not None:
            raise ApprovalError(f"tasks[{index}].priority must be null")
        canonical = {
            "title": title,
            "description": description,
            "sources": clean_sources,
            "dueDate": due_date,
            "priority": priority,
        }
        identity = _candidate_identity(canonical)
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


def _generated_candidate_id(task: dict[str, object]) -> str:
    identity = f"candidate:{_candidate_identity(task)}"
    return str(uuid.uuid5(IMPORT_NAMESPACE, identity)).upper()


def _assign_candidate_ids(
    tasks: list[dict[str, object]],
    previous_tasks: object,
) -> list[dict[str, object]]:
    assigned = [dict(task) for task in tasks]
    previous = (
        [
            task
            for task in previous_tasks
            if isinstance(task, dict) and isinstance(task.get("candidateID"), str)
        ]
        if isinstance(previous_tasks, list)
        else []
    )
    used_ids: set[str] = set()

    previous_by_identity = {_candidate_identity(task): task for task in previous}
    for task in assigned:
        match = previous_by_identity.get(_candidate_identity(task))
        if match is not None and match["candidateID"] not in used_ids:
            task["candidateID"] = match["candidateID"]
            used_ids.add(str(match["candidateID"]))

    unmatched_by_title: dict[str, list[dict[str, object]]] = {}
    for task in assigned:
        if "candidateID" not in task:
            title_core = _normalized_title_core(str(task["title"]))
            unmatched_by_title.setdefault(title_core, []).append(task)
    for title_core, unmatched in unmatched_by_title.items():
        prior = [
            task
            for task in previous
            if task["candidateID"] not in used_ids
            and _normalized_title_core(str(task["title"])) == title_core
        ]
        if len(unmatched) == 1 and len(prior) == 1:
            unmatched[0]["candidateID"] = prior[0]["candidateID"]
            used_ids.add(str(prior[0]["candidateID"]))

    for task in assigned:
        if "candidateID" not in task:
            task["candidateID"] = _generated_candidate_id(task)
    candidate_ids = [str(task["candidateID"]) for task in assigned]
    if len(candidate_ids) != len(set(candidate_ids)):
        raise ApprovalError("candidate tasks produce duplicate candidate IDs")
    return assigned


def _state_path(day: str, state_dir: Path) -> Path:
    return state_dir / f"{day}.json"


@contextmanager
def _exclusive_file_lock(lock_path: Path) -> Iterator[None]:
    descriptor = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o600)
    try:
        os.fchmod(descriptor, 0o600)
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        yield
    finally:
        fcntl.flock(descriptor, fcntl.LOCK_UN)
        os.close(descriptor)


@contextmanager
def _state_lock(day: str, state_dir: Path) -> Iterator[None]:
    state_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(state_dir, 0o700)
    with _exclusive_file_lock(state_dir / f".{day}.lock"):
        yield


@contextmanager
def _decision_evidence_lock(state_dir: Path) -> Iterator[None]:
    state_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(state_dir, 0o700)
    with _exclusive_file_lock(state_dir / ".decision-evidence.lock"):
        yield


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
        previous_tasks = current.get("tasks") if current is not None else None
        staged_tasks = _assign_candidate_ids(payload["tasks"], previous_tasks)
        if current is not None and current.get("contentHash") == digest:
            if current.get("tasks") != staged_tasks:
                current["tasks"] = staged_tasks
                current["updatedAt"] = datetime.now(timezone.utc).isoformat()
                _write_state_unlocked(day, state_dir, state)
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
            "tasks": staged_tasks,
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


def _validated_slack_timestamp(value: object, field: str) -> tuple[str, Decimal]:
    cleaned = _clean_text(value, field)
    if not SLACK_TIMESTAMP.fullmatch(cleaned):
        raise ApprovalError(f"{field} must be a valid Slack timestamp")
    try:
        parsed = Decimal(cleaned)
    except InvalidOperation as exc:  # pragma: no cover - regex excludes invalid decimals.
        raise ApprovalError(f"{field} must be a valid Slack timestamp") from exc
    if not parsed.is_finite() or parsed <= 0:
        raise ApprovalError(f"{field} must be a valid Slack timestamp")
    return cleaned, parsed


def _validated_slack_dm_conversation_id(value: object, field: str) -> str:
    if not isinstance(value, str) or not SLACK_DM_CONVERSATION_ID.fullmatch(value):
        raise ApprovalError(f"{field} must be a Slack private DM conversation ID")
    return value


def _command_hash(command_text: str) -> str:
    return hashlib.sha256(command_text.encode("utf-8")).hexdigest()


def _validated_decision_command(
    day: str,
    revision: int,
    decision: str,
    command_text: object,
) -> dict[str, str]:
    if not isinstance(command_text, str) or command_text != command_text.strip():
        raise ApprovalError("decision requires the exact Slack command text")
    if decision == "approved":
        command_type = "APPROVE"
        valid = command_text == f"APPROVE {day} R{revision}"
    elif decision == "rejected":
        command_type = "REJECT"
        valid = command_text == f"REJECT {day} R{revision}"
    else:
        command_type = "EDIT"
        prefix = f"EDIT {day} R{revision}: "
        requested_changes = command_text[len(prefix) :] if command_text.startswith(prefix) else ""
        valid = bool(requested_changes and requested_changes == requested_changes.strip())
    if not valid:
        raise ApprovalError("decision requires the exact Slack command text")
    return {
        "commandType": command_type,
        "commandHash": _command_hash(command_text),
    }


def _validated_approval_evidence(
    delivery: object,
    evidence: object,
    command_evidence: dict[str, str],
) -> dict[str, str]:
    if not isinstance(delivery, dict):
        raise ApprovalError("Slack delivery reference is missing or malformed")
    delivery_channel = _validated_slack_dm_conversation_id(
        delivery.get("channelID"), "delivery channel ID"
    )
    _, delivery_timestamp = _validated_slack_timestamp(
        delivery.get("messageTS"), "delivery Slack timestamp"
    )
    if not isinstance(evidence, dict) or set(evidence) != {
        "actorUserID",
        "channelID",
        "messageTS",
        "commandType",
        "commandHash",
    }:
        raise ApprovalError("approved revision has no valid Slack approval evidence")
    actor_user_id = evidence.get("actorUserID")
    if actor_user_id != JP_SLACK_USER_ID:
        raise ApprovalError("approval actor is not the authorized Slack user")
    channel_id = evidence.get("channelID")
    if channel_id != delivery_channel:
        raise ApprovalError("approval channel does not match recorded delivery")
    approval_message_ts, approval_timestamp = _validated_slack_timestamp(
        evidence.get("messageTS"), "approval Slack timestamp"
    )
    if approval_timestamp <= delivery_timestamp:
        raise ApprovalError("approval message timestamp must be newer than delivery")
    if evidence.get("commandType") != command_evidence["commandType"]:
        raise ApprovalError("approval evidence has the wrong Slack command type")
    if evidence.get("commandHash") != command_evidence["commandHash"]:
        raise ApprovalError("approval evidence has the wrong Slack command hash")
    return {
        "actorUserID": actor_user_id,
        "channelID": channel_id,
        "messageTS": approval_message_ts,
        "commandType": command_evidence["commandType"],
        "commandHash": command_evidence["commandHash"],
    }


def _assert_decision_evidence_unused(
    state_dir: Path,
    day: str,
    revision: int,
    channel_id: str,
    message_ts: str,
) -> None:
    for state_path in sorted(state_dir.glob("*.json")):
        other_day = state_path.stem
        other_state = _require_state_unlocked(other_day, state_dir)
        revisions = other_state.get("revisions")
        if not isinstance(revisions, list):
            raise ApprovalError(f"approval state is malformed for {other_day}")
        for other_revision in revisions:
            if not isinstance(other_revision, dict):
                raise ApprovalError(f"approval state is malformed for {other_day}")
            if other_day == day and other_revision.get("revision") == revision:
                continue
            evidence = other_revision.get("approvalEvidence")
            if (
                isinstance(evidence, dict)
                and evidence.get("channelID") == channel_id
                and evidence.get("messageTS") == message_ts
            ):
                raise ApprovalError(
                    "Slack decision evidence is already used by another date or revision"
                )


def record_delivery(
    day: str,
    revision: int,
    channel_id: str,
    message_ts: str,
    state_dir: Path,
) -> dict[str, object]:
    day = _validated_date(day)
    state_dir = Path(state_dir)
    channel_id = _validated_slack_dm_conversation_id(channel_id, "channel ID")
    message_ts, _ = _validated_slack_timestamp(message_ts, "delivery Slack timestamp")
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
    actor_user_id: str,
    channel_id: str,
    approval_message_ts: str,
    command_text: str,
    state_dir: Path,
) -> dict[str, object]:
    day = _validated_date(day)
    state_dir = Path(state_dir)
    if decision not in {"approved", "rejected", "needs_revision"}:
        raise ApprovalError(f"unsupported decision: {decision}")
    command_evidence = _validated_decision_command(day, revision, decision, command_text)
    with _decision_evidence_lock(state_dir):
        with _state_lock(day, state_dir):
            state = _require_state_unlocked(day, state_dir)
            current = _require_active_number(state, revision)
            if current.get("status") != "pending":
                raise ApprovalError(
                    f"illegal transition from {current.get('status')} to {decision}"
                )
            if not isinstance(current.get("delivery"), dict):
                raise ApprovalError("cannot decide before Slack delivery is recorded")
            evidence = _validated_approval_evidence(
                current["delivery"],
                {
                    "actorUserID": actor_user_id,
                    "channelID": channel_id,
                    "messageTS": approval_message_ts,
                    **command_evidence,
                },
                command_evidence,
            )
            _assert_decision_evidence_unused(
                state_dir,
                day,
                revision,
                evidence["channelID"],
                evidence["messageTS"],
            )
            now = datetime.now(timezone.utc).isoformat()
            current["status"] = decision
            current["approvalEvidence"] = evidence
            current["decidedAt"] = now
            current["updatedAt"] = now
            _write_state_unlocked(day, state_dir, state)
            return state


def _normalized_title_core(title: str) -> str:
    without_date = DATE_PREFIX.sub("", " ".join(title.split()))
    return " ".join(re.sub(r"[^a-z0-9]+", " ", without_date.lower()).split())


def _import_key(day: str, candidate_id: str) -> str:
    try:
        parsed = uuid.UUID(candidate_id)
    except (ValueError, AttributeError) as exc:
        raise ApprovalError("staged task has an invalid candidate ID") from exc
    if str(parsed).upper() != candidate_id:
        raise ApprovalError("staged task has an invalid candidate ID")
    digest = hashlib.sha256(candidate_id.encode("utf-8")).hexdigest()[:32]
    return f"codex-daily-task-summary:{day}:{digest}"


def _noon_timestamps(day: str) -> tuple[float, float]:
    parsed = date.fromisoformat(day)
    noon = datetime(parsed.year, parsed.month, parsed.day, 12, tzinfo=NEW_YORK)
    unix_value = noon.timestamp()
    return unix_value, unix_value - APPLE_REFERENCE_UNIX


@contextmanager
def _database_lock(database: Path) -> Iterator[None]:
    resolved_database = database.resolve()
    lock_path = resolved_database.parent / f".{resolved_database.name}.daily-task-approval.lock"
    with _exclusive_file_lock(lock_path):
        yield


def _planned_backup_path(
    backup_dir: Path,
    day: str,
    revision: int,
) -> Path:
    backup_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(backup_dir, 0o700)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    return backup_dir.resolve() / f"meetings-before-{day}-r{revision}-{stamp}.sqlite"


def _backup_database(backup_path: Path, db: sqlite3.Connection) -> None:
    descriptor, temp_name = tempfile.mkstemp(
        prefix=f".{backup_path.name}.", suffix=".tmp", dir=backup_path.parent
    )
    os.close(descriptor)
    try:
        with closing(sqlite3.connect(temp_name)) as backup:
            db.backup(backup)
        os.chmod(temp_name, 0o600)
        os.replace(temp_name, backup_path)
    except Exception:
        try:
            os.unlink(temp_name)
        except FileNotFoundError:
            pass
        raise
    os.chmod(backup_path, 0o600)


def _validate_persisted_backup(backup_path: Path, backup_dir: Path) -> None:
    if backup_path.parent != backup_dir.resolve():
        raise ApprovalError("persisted backup path does not match the configured backup directory")
    if not backup_path.is_file():
        raise ApprovalError("persisted pre-import backup is missing")
    try:
        with closing(sqlite3.connect(f"{backup_path.as_uri()}?mode=ro", uri=True)) as backup:
            result = backup.execute("PRAGMA quick_check").fetchone()
    except sqlite3.Error as exc:
        raise ApprovalError("persisted pre-import backup is unreadable") from exc
    if result is None or result[0] != "ok":
        raise ApprovalError("persisted pre-import backup failed integrity validation")


def _expected_task(
    day: str,
    task: dict[str, object],
    delivery: dict[str, object],
    now_unix: float,
) -> dict[str, object]:
    import_key = _import_key(day, str(task.get("candidateID", "")))
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
        and row["source_action_item_id"] == expected["importKey"]
        and isinstance(task_json, dict)
        and task_json.get("id") == expected["id"]
        and task_json.get("sourceActionItemID") == expected["importKey"]
        and isinstance(metadata, dict)
        and metadata.get("kind") == expected_metadata["kind"]
        and metadata.get("provider") == expected_metadata["provider"]
        and metadata.get("threadID") == expected_metadata["threadID"]
        and metadata.get("messageID") == expected_metadata["messageID"]
        and metadata.get("subject") == expected_metadata["subject"]
    )
    if not matches:
        raise ApprovalError(f"import key conflict for {expected['importKey']}")


def _validated_apply_attempt_phase(
    revision: dict[str, object],
    status: object,
) -> str | None:
    phase = revision.get("applyAttemptPhase")
    if status == "applied":
        valid_phases = {APPLY_PHASE_COMMITTED}
    else:
        valid_phases = {
            APPLY_PHASE_BACKUP_READY,
            APPLY_PHASE_TRANSACTION_STARTED,
        }
    if phase is None:
        if status == "applied" or "backupCreatedAt" in revision:
            raise ApprovalError("revision has a missing apply attempt phase")
        return None
    if not isinstance(phase, str) or phase not in valid_phases:
        raise ApprovalError("revision has an invalid apply attempt phase")
    if not isinstance(revision.get("backupPath"), str) or not isinstance(
        revision.get("backupCreatedAt"), str
    ):
        raise ApprovalError("revision apply attempt phase has incomplete backup state")
    return str(phase)


def _row_is_same_day_task(
    row: sqlite3.Row,
    day: str,
    title: str,
    description: str,
) -> bool:
    timestamp = row["work_date"] or row["completed_date"] or row["created_date"]
    if timestamp is None:
        return False
    try:
        row_day = datetime.fromtimestamp(float(timestamp), tz=NEW_YORK).date().isoformat()
    except (OSError, OverflowError, TypeError, ValueError):
        return False
    if row_day != day or _normalized_title_core(str(row["title"])) != _normalized_title_core(title):
        return False
    try:
        task_json = json.loads(str(row["json_data"]))
    except json.JSONDecodeError:
        return False
    if not isinstance(task_json, dict) or not isinstance(task_json.get("description"), str):
        return False
    return " ".join(task_json["description"].split()) == " ".join(description.split())


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
    with ExitStack() as locks:
        locks.enter_context(_state_lock(day, state_dir))
        state = _require_state_unlocked(day, state_dir)
        current = _require_active_number(state, revision)
        status = current.get("status")
        if status not in {"approved", "applied"}:
            raise ApprovalError("revision must be approved before apply")
        attempt_phase = _validated_apply_attempt_phase(current, status)
        delivery = current.get("delivery")
        if not isinstance(delivery, dict):
            raise ApprovalError("approved revision has no bound Slack delivery")
        approved_command_evidence = _validated_decision_command(
            day,
            revision,
            "approved",
            f"APPROVE {day} R{revision}",
        )
        _validated_approval_evidence(
            delivery,
            current.get("approvalEvidence"),
            approved_command_evidence,
        )
        if status == "applied":
            result = current.get("applyResult")
            if not isinstance(result, dict):
                raise ApprovalError("applied revision is missing its result")
            return result
        if not database.is_file():
            raise ApprovalError(f"NoteAI database does not exist: {database}")
        locks.enter_context(_database_lock(database))
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
            existing_import_keys = {
                str(row[0])
                for row in db.execute(
                    "SELECT source_action_item_id FROM tasks "
                    "WHERE source_action_item_id IS NOT NULL"
                ).fetchall()
            }
            deterministic_key_exists = bool(existing_import_keys.intersection(import_keys))
            if (
                attempt_phase == APPLY_PHASE_TRANSACTION_STARTED
                and not deterministic_key_exists
            ):
                raise ApprovalError(
                    "transaction-started attempt has no deterministic import evidence"
                )
            persisted_backup = current.get("backupPath")
            backup_created_at = current.get("backupCreatedAt")
            if persisted_backup is None:
                backup_path = _planned_backup_path(backup_dir, day, revision)
                current["backupPath"] = str(backup_path)
                current["updatedAt"] = datetime.now(timezone.utc).isoformat()
                _write_state_unlocked(day, state_dir, state)
            elif isinstance(persisted_backup, str) and persisted_backup:
                backup_path = Path(persisted_backup)
            else:
                raise ApprovalError("approved revision has an invalid backup path")

            if backup_created_at is None:
                _backup_database(backup_path, db)
                _validate_persisted_backup(backup_path, backup_dir)
                now = datetime.now(timezone.utc).isoformat()
                current["backupCreatedAt"] = now
                current["applyAttemptPhase"] = APPLY_PHASE_BACKUP_READY
                current["updatedAt"] = now
                _write_state_unlocked(day, state_dir, state)
                attempt_phase = APPLY_PHASE_BACKUP_READY
            elif not isinstance(backup_created_at, str):
                raise ApprovalError("approved revision has an invalid backup creation timestamp")
            else:
                if (
                    attempt_phase == APPLY_PHASE_BACKUP_READY
                    and not deterministic_key_exists
                ):
                    _backup_database(backup_path, db)
                    _validate_persisted_backup(backup_path, backup_dir)
                    now = datetime.now(timezone.utc).isoformat()
                    current["backupCreatedAt"] = now
                    current["updatedAt"] = now
                    _write_state_unlocked(day, state_dir, state)
                else:
                    _validate_persisted_backup(backup_path, backup_dir)
            try:
                db.execute("BEGIN IMMEDIATE")
                now = datetime.now(timezone.utc).isoformat()
                current["applyAttemptPhase"] = APPLY_PHASE_TRANSACTION_STARTED
                current["updatedAt"] = now
                _write_state_unlocked(day, state_dir, state)
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
                        if _row_is_same_day_task(
                            row,
                            day,
                            str(expected["title"]),
                            str(expected["description"]),
                        )
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
        current["applyAttemptPhase"] = APPLY_PHASE_COMMITTED
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
    for key in (
        "delivery",
        "approvalEvidence",
        "applyAttemptPhase",
        "backupPath",
        "backupCreatedAt",
        "createdAt",
        "updatedAt",
        "decidedAt",
        "expiredAt",
        "appliedAt",
        "applyResult",
    ):
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
    decide_parser.add_argument("--actor-user-id", required=True)
    decide_parser.add_argument("--channel-id", required=True)
    decide_parser.add_argument("--approval-message-ts", required=True)
    decide_parser.add_argument("--command-text", required=True)

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
                decide(
                    args.date,
                    args.revision,
                    args.decision,
                    args.actor_user_id,
                    args.channel_id,
                    args.approval_message_ts,
                    args.command_text,
                    args.state_dir,
                )
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
