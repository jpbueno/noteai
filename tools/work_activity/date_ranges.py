from __future__ import annotations

from datetime import date, datetime, time, timedelta
from zoneinfo import ZoneInfo

from .models import DateRange


def _parse_date(value: str, tz: ZoneInfo) -> date:
    if value == "today":
        return datetime.now(tz).date()
    return date.fromisoformat(value)


def day_range(value: str, timezone: str = "America/New_York") -> DateRange:
    tz = ZoneInfo(timezone)
    day = _parse_date(value, tz)
    start = datetime.combine(day, time.min, tzinfo=tz)
    end = start + timedelta(days=1)
    return DateRange(start=start, end=end, timezone=timezone, label=day.isoformat())


def week_range(now: datetime | None = None, timezone: str = "America/New_York") -> DateRange:
    tz = ZoneInfo(timezone)
    local_now = now.astimezone(tz) if now else datetime.now(tz)
    monday = local_now.date() - timedelta(days=local_now.weekday())
    start = datetime.combine(monday, time.min, tzinfo=tz)
    end = start + timedelta(days=7)
    return DateRange(start=start, end=end, timezone=timezone, label=f"{monday.isoformat()} week")


def parse_custom_range(start_date: str, end_date: str, timezone: str = "America/New_York") -> DateRange:
    tz = ZoneInfo(timezone)
    start_day = date.fromisoformat(start_date)
    end_day = date.fromisoformat(end_date)
    start = datetime.combine(start_day, time.min, tzinfo=tz)
    end = datetime.combine(end_day + timedelta(days=1), time.min, tzinfo=tz)
    return DateRange(start=start, end=end, timezone=timezone, label=f"{start_date} to {end_date}")
