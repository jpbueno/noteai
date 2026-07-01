from __future__ import annotations

from .models import ActivityItem, TaskCandidate


OPEN_STATUSES = {"open", "pending", "todo", "in_progress"}
TASK_TABLES = {"tasks", "todos"}
TASK_HINT_TOKENS = ("task", "todo", "to-do", "action item")


def _has_remaining_followup(text: str) -> bool:
    lowered = text.lower()
    if "no remaining follow-up" in lowered or "no remaining follow up" in lowered:
        return False
    return any(
        token in lowered
        for token in (
            "follow up",
            "follow-up",
            "next step",
            "needs follow-up",
            "needs follow up",
            "blocker",
            "todo",
            "to-do",
            "action item",
        )
    )


def _jp_owned(item: ActivityItem) -> bool:
    signals = " ".join(item.ownership_signals + [item.title, item.body]).lower()
    if item.source.value == "NoteAI":
        return True
    return any(token in signals for token in ("jp", "jbuenosantan", "jp santana", "i will", "i need to", "my task"))


def _has_task_like_hint(item: ActivityItem) -> bool:
    table = item.raw_metadata.get("table")
    if isinstance(table, str) and table.lower() in TASK_TABLES:
        return True

    ref_labels = " ".join(source.label for source in item.source_refs).lower()
    return any(token in ref_labels for token in TASK_HINT_TOKENS)


def _is_missing_status_task_like(item: ActivityItem) -> bool:
    return _has_remaining_followup(f"{item.title} {item.body}") or _has_task_like_hint(item)


def extract_task_candidates(items: list[ActivityItem]) -> list[TaskCandidate]:
    candidates: list[TaskCandidate] = []
    for item in items:
        status = item.status.strip().lower() if isinstance(item.status, str) else item.status
        if status is None:
            if not _is_missing_status_task_like(item):
                continue
        elif status not in OPEN_STATUSES and not _has_remaining_followup(item.body):
            continue
        if not _jp_owned(item):
            continue
        description = item.body.strip() or item.title
        candidates.append(
            TaskCandidate(
                title=item.title.strip(),
                description=description,
                due_date=item.due_date,
                priority=item.priority,
                status="open" if status is None or status in OPEN_STATUSES else str(status),
                project=item.project,
                sources=item.source_refs,
                confidence=0.8 if item.source.value == "NoteAI" else 0.6,
            )
        )
    return candidates
