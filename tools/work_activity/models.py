from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime
from enum import Enum
from typing import Any


class SourceKind(str, Enum):
    SLACK = "Slack"
    OUTLOOK = "Outlook"
    TEAMS = "Teams"
    CALENDAR = "Calendar"
    NOTEAI = "NoteAI"
    GOOGLE_DOC = "Google Doc"


@dataclass(frozen=True)
class DateRange:
    start: datetime
    end: datetime
    timezone: str
    label: str


@dataclass(frozen=True)
class SourceRef:
    source: SourceKind
    label: str
    url: str | None = None
    source_id: str | None = None


@dataclass(frozen=True)
class Person:
    name: str
    email: str | None = None


@dataclass(frozen=True)
class ActivityItem:
    source: SourceKind
    timestamp: datetime | None
    title: str
    body: str
    source_refs: list[SourceRef]
    participants: list[Person] = field(default_factory=list)
    ownership_signals: list[str] = field(default_factory=list)
    due_date: datetime | None = None
    priority: str | None = None
    status: str | None = None
    project: str | None = None
    raw_metadata: dict[str, Any] = field(default_factory=dict)


@dataclass(frozen=True)
class TaskCandidate:
    title: str
    description: str
    sources: list[SourceRef]
    due_date: datetime | None = None
    priority: str | None = None
    status: str = "open"
    project: str | None = None
    confidence: float = 0.5


@dataclass(frozen=True)
class SourceHealth:
    source: SourceKind
    status: str
    message: str


@dataclass(frozen=True)
class SourceQueryResult:
    source: SourceKind
    items: list[ActivityItem]
    health: SourceHealth
