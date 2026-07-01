from __future__ import annotations

from datetime import datetime

from .models import SourceRef, TaskCandidate


def _format_date(value: datetime | None) -> str:
    if value is None:
        return "Not specified"
    return value.strftime("%m/%d/%y")


def _format_sources(sources: list[SourceRef]) -> str:
    labels: list[str] = []
    seen: set[str] = set()
    for source in sources:
        label = source.source.value
        if label in seen:
            continue
        labels.append(label)
        seen.add(label)
    if not labels:
        return "Not specified"
    return " / ".join(labels)


def format_open_tasks(tasks: list[TaskCandidate]) -> str:
    if not tasks:
        return "No open tasks were identified."

    sections: list[str] = []
    for index, task in enumerate(tasks, start=1):
        sections.append(
            "\n".join(
                [
                    f"### {index}. {task.title}",
                    f"Description: {task.description}",
                    f"Source: {_format_sources(task.sources)}",
                    f"Due date: {_format_date(task.due_date)}",
                    f"Priority: {task.priority or 'Not specified'}",
                ]
            )
        )
    return "\n\n".join(sections)


def format_daily_task_summary(
    date_label: str,
    tasks: list[TaskCandidate],
    unavailable_sources: list[str] | None = None,
) -> str:
    task_summary = format_open_tasks(tasks) if tasks else "No open tasks were identified for the day."
    parts = [f"# Daily Task Summary — {date_label}", "## Tasks", task_summary]
    if unavailable_sources:
        source_lines = "\n".join(f"- {source}" for source in unavailable_sources)
        parts.append(f"## Unavailable sources\n{source_lines}")
    return "\n\n".join(parts)
