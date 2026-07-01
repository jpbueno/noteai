from __future__ import annotations

from datetime import datetime

from .deduplication import deduplicate_tasks
from .extraction import extract_task_candidates
from .models import ActivityItem, DateRange, TaskCandidate
from .summaries import format_daily_task_summary, format_open_tasks


def _in_range(timestamp: datetime | None, date_range: DateRange) -> bool:
    if timestamp is None:
        return False
    if timestamp.tzinfo is None and date_range.start.tzinfo is not None:
        timestamp = timestamp.replace(tzinfo=date_range.start.tzinfo)
    elif timestamp.tzinfo is not None and date_range.start.tzinfo is not None:
        timestamp = timestamp.astimezone(date_range.start.tzinfo)
    return date_range.start <= timestamp < date_range.end


def _items_in_range(date_range: DateRange, activity_items: list) -> list[ActivityItem]:
    return [
        item
        for item in activity_items
        if isinstance(item, ActivityItem) and _in_range(item.timestamp, date_range)
    ]


def get_open_tasks(date_range: DateRange, activity_items: list) -> list[TaskCandidate]:
    return deduplicate_tasks(extract_task_candidates(_items_in_range(date_range, activity_items)))


def get_daily_task_summary(
    date_range: DateRange,
    activity_items: list,
    unavailable_sources: list[str] | None = None,
) -> str:
    tasks = get_open_tasks(date_range, activity_items)
    return format_daily_task_summary(date_range.label, tasks, unavailable_sources=unavailable_sources)


def get_t5t_ready_tasks(date_range: DateRange, activity_items: list) -> str:
    return format_open_tasks(get_open_tasks(date_range, activity_items))


def get_projects_worked_on(date_range: DateRange, activity_items: list) -> list[str]:
    projects: list[str] = []
    seen: set[str] = set()
    for item in _items_in_range(date_range, activity_items):
        if not item.project:
            continue
        project = item.project.strip()
        if not project or project in seen:
            continue
        projects.append(project)
        seen.add(project)
    return projects
