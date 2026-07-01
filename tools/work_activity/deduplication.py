from __future__ import annotations

import re

from .models import SourceRef, TaskCandidate


def _key(title: str) -> str:
    normalized = re.sub(r"[^a-z0-9]+", " ", title.lower())
    tokens = [token for token in normalized.split() if token not in {"the", "a", "an", "with", "to"}]
    tokens = ["follow" if token in {"followup", "follow"} else token for token in tokens]
    return " ".join(tokens[:6])


def _source_identity(source: SourceRef) -> tuple[object, ...]:
    if source.source_id is not None:
        return (source.source, "id", source.source_id)
    return (source.source, "ref", source.label, source.url)


def deduplicate_tasks(tasks: list[TaskCandidate]) -> list[TaskCandidate]:
    merged: dict[str, TaskCandidate] = {}
    for index, task in enumerate(tasks):
        key = _key(task.title) or f"__empty_title_{index}"
        if key not in merged:
            merged[key] = task
            continue
        existing = merged[key]
        source_map = {_source_identity(source): source for source in existing.sources}
        for source in task.sources:
            source_map[_source_identity(source)] = source
        description = existing.description
        if len(task.description) > len(description):
            description = task.description
        merged[key] = TaskCandidate(
            title=existing.title,
            description=description,
            due_date=existing.due_date or task.due_date,
            priority=existing.priority or task.priority,
            status=existing.status,
            project=existing.project or task.project,
            sources=list(source_map.values()),
            confidence=max(existing.confidence, task.confidence),
        )
    return list(merged.values())
