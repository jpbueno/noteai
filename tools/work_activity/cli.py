from __future__ import annotations

import argparse

from .date_ranges import day_range
from .slack_delivery import SlackDelivery
from .summaries import format_daily_task_summary


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="noteai-work-activity")
    subparsers = parser.add_subparsers(dest="command", required=True)

    daily = subparsers.add_parser("daily-summary", help="Generate a daily task summary")
    daily.add_argument("--date", default="today")
    daily.add_argument("--timezone", default="America/New_York")
    daily.add_argument("--dry-run", action="store_true")
    daily.add_argument("--send-slack", action="store_true")
    daily.add_argument("--slack-user-id")

    subparsers.add_parser("open-tasks", help="List open task candidates")
    subparsers.add_parser("weekly-projects", help="Summarize projects worked on this week")
    subparsers.add_parser("meeting-summary", help="Summarize a meeting")
    subparsers.add_parser("t5t-ready", help="Generate T5T-ready task entries")
    return parser


def _resolve_date(value: str, timezone: str = "America/New_York") -> str:
    return day_range(value, timezone).label


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if args.command == "daily-summary":
        summary_date = _resolve_date(args.date, args.timezone)
        summary = format_daily_task_summary(summary_date, [])
        print(summary)
        if args.dry_run:
            return 0
        if args.send_slack:
            if not args.slack_user_id:
                print("--slack-user-id is required when --send-slack is provided")
                return 1
            result = SlackDelivery().send_direct_message(args.slack_user_id, summary)
            if not result.ok:
                print(f"Slack delivery failed: {result.message}")
                return 1
        return 0
    parser.error(f"{args.command} is assigned to a later task in this implementation plan")
    return 2
