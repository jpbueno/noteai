from __future__ import annotations

import argparse
import json
from pathlib import Path
from zoneinfo import ZoneInfoNotFoundError

from .connectors.ai_pim import AIPIMHarness
from .connectors.noteai import DEFAULT_NOTEAI_DB, NoteAILocalConnector
from .date_ranges import day_range, parse_custom_range
from .deduplication import deduplicate_tasks
from .extraction import extract_task_candidates
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
    daily.add_argument("--noteai-db", default=str(DEFAULT_NOTEAI_DB))

    subparsers.add_parser("open-tasks", help="List open task candidates")
    subparsers.add_parser("weekly-projects", help="Summarize projects worked on this week")
    subparsers.add_parser("meeting-summary", help="Summarize a meeting")
    subparsers.add_parser("t5t-ready", help="Generate T5T-ready task entries")

    source_status = subparsers.add_parser(
        "source-status", help="Report Slack or Teams installation and authentication status as JSON"
    )
    source_status.add_argument("--source", required=True, choices=("slack", "teams"))

    source_auth = subparsers.add_parser(
        "source-auth", help="Check or launch Slack or Teams authentication"
    )
    source_auth.add_argument("--source", required=True, choices=("slack", "teams"))
    source_auth.add_argument("--action", required=True, choices=("status", "login"))

    source_search = subparsers.add_parser(
        "source-search", help="Search bounded Slack or Teams work activity as JSON"
    )
    source_search.add_argument("--source", required=True, choices=("slack", "teams"))
    source_search.add_argument("--from", dest="start_date", required=True)
    source_search.add_argument("--to", dest="end_date", required=True)
    source_search.add_argument("--timezone", default="America/New_York")
    source_search.add_argument("--query", default="")
    source_search.add_argument("--limit", type=int, default=50)
    source_search.add_argument("--messages-per-chat", type=int, default=50)
    return parser


def _resolve_date(value: str, timezone: str = "America/New_York") -> str:
    return day_range(value, timezone).label


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if args.command == "daily-summary":
        summary_date = _resolve_date(args.date, args.timezone)
        date_range = day_range(summary_date, args.timezone)
        noteai_result = NoteAILocalConnector(Path(args.noteai_db)).query(date_range)
        tasks = deduplicate_tasks(extract_task_candidates(noteai_result.items))
        unavailable = []
        if noteai_result.health.status != "available":
            unavailable.append(noteai_result.health.message)
        summary = format_daily_task_summary(summary_date, tasks, unavailable)
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
    if args.command == "source-status":
        return _print_json_result(AIPIMHarness().status(args.source))
    if args.command == "source-auth":
        harness = AIPIMHarness()
        result = harness.status(args.source) if args.action == "status" else harness.login(args.source)
        return _print_json_result(result)
    if args.command == "source-search":
        try:
            date_range = parse_custom_range(args.start_date, args.end_date, args.timezone)
            if date_range.start >= date_range.end:
                raise ValueError("range start must not follow range end")
        except (OverflowError, ValueError, ZoneInfoNotFoundError):
            return _print_json_result(_source_search_validation_error(args.source))
        result = AIPIMHarness().search(
            args.source,
            date_range,
            query=args.query,
            limit=args.limit,
            messages_per_chat=args.messages_per_chat,
        )
        return _print_json_result(result)
    parser.error(f"{args.command} is assigned to a later task in this implementation plan")
    return 2


def _print_json_result(result: dict[str, object]) -> int:
    print(json.dumps(result, separators=(",", ":"), sort_keys=True))
    return 0 if result.get("success") is True else 1


def _source_search_validation_error(source: str) -> dict[str, object]:
    return {
        "schemaVersion": 1,
        "success": False,
        "source": source,
        "action": "search",
        "status": "validation_error",
        "message": "Source search date range is invalid.",
        "data": {
            "installed": True,
            "authenticated": False,
            "items": [],
        },
        "metadata": {
            "isPartial": False,
            "partialReasons": [],
        },
    }
