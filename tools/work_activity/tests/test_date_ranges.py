from datetime import datetime
from zoneinfo import ZoneInfo
import unittest
from unittest.mock import patch

from tools.work_activity.date_ranges import day_range, parse_custom_range, week_range


class DateRangeTests(unittest.TestCase):
    def test_day_range_uses_new_york_boundaries(self):
        result = day_range("2026-07-01", "America/New_York")
        self.assertEqual(result.start.isoformat(), "2026-07-01T00:00:00-04:00")
        self.assertEqual(result.end.isoformat(), "2026-07-02T00:00:00-04:00")
        self.assertEqual(result.label, "2026-07-01")

    def test_day_range_today_uses_requested_timezone(self):
        class FixedDateTime(datetime):
            @classmethod
            def now(cls, tz=None):
                fixed = cls(2026, 7, 1, 2, 0, tzinfo=ZoneInfo("UTC"))
                return fixed.astimezone(tz) if tz else fixed

        with patch("tools.work_activity.date_ranges.datetime", FixedDateTime):
            result = day_range("today", "America/Los_Angeles")

        self.assertEqual(result.start.isoformat(), "2026-06-30T00:00:00-07:00")
        self.assertEqual(result.end.isoformat(), "2026-07-01T00:00:00-07:00")
        self.assertEqual(result.label, "2026-06-30")

    def test_week_range_starts_monday(self):
        now = datetime(2026, 7, 1, 12, 0, tzinfo=ZoneInfo("America/New_York"))
        result = week_range(now, "America/New_York")
        self.assertEqual(result.start.date().isoformat(), "2026-06-29")
        self.assertEqual(result.end.date().isoformat(), "2026-07-06")

    def test_custom_range_is_end_exclusive(self):
        result = parse_custom_range("2026-07-01", "2026-07-03", "America/New_York")
        self.assertEqual(result.start.date().isoformat(), "2026-07-01")
        self.assertEqual(result.end.date().isoformat(), "2026-07-04")
