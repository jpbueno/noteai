from __future__ import annotations

from typing import Protocol

from ..models import DateRange, SourceQueryResult


class SourceConnector(Protocol):
    def query(self, date_range: DateRange, query: str | None = None) -> SourceQueryResult:
        ...
