from __future__ import annotations

import json
import re
import time
from datetime import UTC, datetime
from html.parser import HTMLParser
from typing import Any

from ..cli_runner import CLIRunner
from ..models import DateRange, SourceHealth, SourceKind


CLI_SOURCE_MAP = {
    "outlook-cli": SourceKind.OUTLOOK,
    "calendar-cli": SourceKind.CALENDAR,
    "meeting-cli": SourceKind.TEAMS,
    "teams-cli": SourceKind.TEAMS,
    "slack-cli": SourceKind.SLACK,
    "gdrive-cli": SourceKind.GOOGLE_DOC,
}

SOURCE_CLI_MAP = {
    "slack": "slack-cli",
    "teams": "teams-cli",
}

COMMAND_TIMEOUT_SECONDS = 30
AUTH_TIMEOUT_SECONDS = 120
COMMAND_OUTPUT_LIMIT_BYTES = 1_048_576
MAX_SLACK_RESULTS = 100
TEAMS_CHAT_LIMIT = 50
MAX_TEAMS_MESSAGES_PER_CHAT = 200
MAX_NORMALIZED_RESULTS = 100
TEAMS_COMMAND_TIMEOUT_SECONDS = 10
TEAMS_SEARCH_TIMEOUT_SECONDS = 60
MAX_ITEM_BODY_CHARACTERS = 8_000


class _HTMLTextParser(HTMLParser):
    _block_tags = {"blockquote", "br", "div", "li", "p", "table", "td", "th", "tr"}
    _ignored_tags = {"script", "style"}

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.parts: list[str] = []
        self.ignored_depth = 0

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        if tag in self._ignored_tags:
            self.ignored_depth += 1
        elif tag == "br" and self.ignored_depth == 0:
            self.parts.append("\n")

    def handle_endtag(self, tag: str) -> None:
        if tag in self._ignored_tags and self.ignored_depth:
            self.ignored_depth -= 1
        elif tag in self._block_tags and tag != "br" and self.ignored_depth == 0:
            self.parts.append("\n")

    def handle_data(self, data: str) -> None:
        if self.ignored_depth == 0:
            self.parts.append(data)

    def text(self) -> str:
        lines = []
        for line in "".join(self.parts).replace("\xa0", " ").splitlines():
            normalized = re.sub(r"[ \t\r\f\v]+", " ", line).strip()
            if normalized:
                lines.append(normalized)
        return "\n".join(lines)


def _html_to_text(value: str) -> str:
    parser = _HTMLTextParser()
    try:
        parser.feed(value)
        parser.close()
    except (ValueError, AssertionError):
        return ""
    return parser.text()


def _parse_timestamp(value: Any) -> datetime | None:
    if not isinstance(value, str):
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.tzinfo is None:
        return parsed.replace(tzinfo=UTC)
    return parsed


def _envelope(
    source: str,
    action: str,
    *,
    success: bool,
    status: str,
    message: str,
    installed: bool,
    authenticated: bool,
    items: list[dict[str, Any]] | None = None,
    metadata: dict[str, Any] | None = None,
) -> dict[str, Any]:
    result_metadata = {"isPartial": False, "partialReasons": []}
    if metadata:
        result_metadata.update(metadata)
    return {
        "schemaVersion": 1,
        "success": success,
        "source": source,
        "action": action,
        "status": status,
        "message": message,
        "data": {
            "installed": installed,
            "authenticated": authenticated,
            "items": items or [],
        },
        "metadata": result_metadata,
    }


def _decode_json(stdout: str) -> dict[str, Any] | None:
    try:
        payload = json.loads(stdout)
    except (json.JSONDecodeError, TypeError):
        return None
    return payload if isinstance(payload, dict) else None


class AIPIMHarness:
    def __init__(self, runner: CLIRunner | None = None) -> None:
        self.runner = runner or CLIRunner(
            timeout_seconds=COMMAND_TIMEOUT_SECONDS,
            max_output_bytes=COMMAND_OUTPUT_LIMIT_BYTES,
        )

    def status(self, source: str) -> dict[str, Any]:
        cli_name = self._cli_name(source)
        args = [cli_name, "auth", "status"]
        if source == "teams":
            args.append("--json")
        result = self.runner.run(
            args,
            timeout_seconds=COMMAND_TIMEOUT_SECONDS,
            max_output_bytes=COMMAND_OUTPUT_LIMIT_BYTES,
        )

        if result.returncode == 127:
            return _envelope(
                source,
                "status",
                success=True,
                status="unavailable",
                message=f"{self._display_name(source)} CLI is not installed.",
                installed=False,
                authenticated=False,
            )
        if result.returncode == 2:
            return self._auth_required(source, action="status", success=True)
        if result.returncode == 124:
            return self._failure(source, "status", "timed_out", "Source status check timed out.")
        if result.returncode == 125:
            return self._failure(source, "status", "output_limit_exceeded", "Source status output exceeded the limit.")
        if result.returncode != 0:
            return self._failure(source, "status", "command_error", "Source status check failed.")

        if source == "slack":
            lowered = result.stdout.casefold()
            if "not authenticated" in lowered or "authentication required" in lowered:
                return self._auth_required(source, action="status", success=True)
            return _envelope(
                source,
                "status",
                success=True,
                status="available",
                message="Slack is authenticated.",
                installed=True,
                authenticated=True,
            )

        payload = _decode_json(result.stdout)
        if payload is None:
            return self._failure(source, "status", "invalid_response", "Source status returned invalid JSON.")
        if payload.get("success") is not True:
            error = payload.get("error")
            code = error.get("code", "") if isinstance(error, dict) else ""
            if "AUTH" in str(code).upper():
                return self._auth_required(source, action="status", success=False)
            return self._failure(source, "status", "command_error", "Source status check failed.")
        data = payload.get("data")
        authenticated = data.get("authenticated") is True if isinstance(data, dict) else False
        if not authenticated:
            return self._auth_required(source, action="status", success=True)
        return _envelope(
            source,
            "status",
            success=True,
            status="available",
            message="Teams is authenticated.",
            installed=True,
            authenticated=True,
        )

    def login(self, source: str) -> dict[str, Any]:
        cli_name = self._cli_name(source)
        result = self.runner.run(
            [cli_name, "auth", "login"],
            timeout_seconds=AUTH_TIMEOUT_SECONDS,
            max_output_bytes=COMMAND_OUTPUT_LIMIT_BYTES,
        )
        if result.returncode == 0:
            return _envelope(
                source,
                "login",
                success=True,
                status="available",
                message=f"{self._display_name(source)} authentication completed.",
                installed=True,
                authenticated=True,
            )
        if result.returncode == 127:
            return _envelope(
                source,
                "login",
                success=False,
                status="unavailable",
                message=f"{self._display_name(source)} CLI is not installed.",
                installed=False,
                authenticated=False,
            )
        if result.returncode == 124:
            return self._failure(source, "login", "timed_out", "Authentication timed out.")
        if result.returncode == 125:
            return self._failure(source, "login", "output_limit_exceeded", "Authentication output exceeded the limit.")
        return self._failure(source, "login", "command_error", "Authentication failed.")

    def search(
        self,
        source: str,
        date_range: DateRange,
        *,
        query: str = "",
        limit: int = 50,
        messages_per_chat: int = 50,
    ) -> dict[str, Any]:
        self._cli_name(source)
        if source == "slack":
            return self._search_slack(date_range, query=query, limit=limit)
        return self._search_teams(
            date_range,
            query=query,
            limit=limit,
            messages_per_chat=messages_per_chat,
        )

    def _search_slack(self, date_range: DateRange, *, query: str, limit: int) -> dict[str, Any]:
        if limit < 1 or limit > MAX_SLACK_RESULTS:
            return self._failure(
                "slack",
                "search",
                "validation_error",
                f"Slack limit must be between 1 and {MAX_SLACK_RESULTS}.",
            )
        filters = (
            f"from:me after:{date_range.start.date().isoformat()} "
            f"before:{date_range.end.date().isoformat()}"
        )
        bounded_query = f"{query.strip()} {filters}".strip()
        result = self.runner.run(
            [
                "slack-cli",
                "message",
                "search",
                "--query",
                bounded_query,
                "--limit",
                str(limit),
                "--page",
                "1",
                "--output",
                "json",
            ],
            timeout_seconds=COMMAND_TIMEOUT_SECONDS,
            max_output_bytes=COMMAND_OUTPUT_LIMIT_BYTES,
        )
        failure = self._search_command_failure("slack", result.returncode)
        if failure:
            return failure

        payload = _decode_json(result.stdout)
        if payload is None:
            return self._failure(
                "slack", "search", "invalid_response", "Slack returned invalid JSON."
            )
        if payload.get("success") is not True:
            return self._failure("slack", "search", "command_error", "Slack search failed.")
        data = payload.get("data")
        messages = data.get("messages") if isinstance(data, dict) else None
        matches = messages.get("matches") if isinstance(messages, dict) else None
        if not isinstance(matches, list):
            return self._failure(
                "slack", "search", "invalid_response", "Slack returned an unexpected response."
            )

        items = [item for match in matches if (item := self._normalize_slack_match(match))]
        total = messages.get("total")
        pagination = messages.get("pagination")
        page_count = pagination.get("page_count") if isinstance(pagination, dict) else None
        partial = (isinstance(total, int) and total > len(matches)) or (
            isinstance(page_count, int) and page_count > 1
        )
        reasons = ["result_limit_reached"] if partial else []
        return _envelope(
            "slack",
            "search",
            success=True,
            status="available",
            message="Slack search completed.",
            installed=True,
            authenticated=True,
            items=items,
            metadata={
                "isPartial": partial,
                "partialReasons": reasons,
                "requestedLimit": limit,
                "returnedCount": len(items),
                "filtering": "server_side",
            },
        )

    def _search_teams(
        self,
        date_range: DateRange,
        *,
        query: str,
        limit: int,
        messages_per_chat: int,
    ) -> dict[str, Any]:
        if limit < 1 or limit > MAX_NORMALIZED_RESULTS:
            return self._failure(
                "teams",
                "search",
                "validation_error",
                f"Teams result limit must be between 1 and {MAX_NORMALIZED_RESULTS}.",
            )
        if messages_per_chat < 1 or messages_per_chat > MAX_TEAMS_MESSAGES_PER_CHAT:
            return self._failure(
                "teams",
                "search",
                "validation_error",
                f"Teams message limit must be between 1 and {MAX_TEAMS_MESSAGES_PER_CHAT}.",
            )

        deadline = time.monotonic() + TEAMS_SEARCH_TIMEOUT_SECONDS
        list_result = self.runner.run(
            ["teams-cli", "chat", "list", "--limit", str(TEAMS_CHAT_LIMIT), "--json"],
            timeout_seconds=TEAMS_COMMAND_TIMEOUT_SECONDS,
            max_output_bytes=COMMAND_OUTPUT_LIMIT_BYTES,
        )
        failure = self._search_command_failure("teams", list_result.returncode)
        if failure:
            return failure
        payload = _decode_json(list_result.stdout)
        chats = self._successful_data_list(payload, nested_key="chats")
        if chats is None:
            return self._failure(
                "teams", "search", "invalid_response", "Teams returned an unexpected chat list."
            )

        partial_reasons: list[str] = []
        if len(chats) >= TEAMS_CHAT_LIMIT:
            partial_reasons.append("chat_limit_reached")
        items: list[dict[str, Any]] = []
        searched_chat_count = 0
        query_text = query.strip().casefold()

        for chat in chats:
            if len(items) >= limit:
                partial_reasons.append("result_limit_reached")
                break
            if time.monotonic() >= deadline:
                partial_reasons.append("time_limit_reached")
                break
            if not isinstance(chat, dict) or not isinstance(chat.get("id"), str):
                partial_reasons.append("chat_read_failed")
                continue

            chat_id = chat["id"]
            remaining_seconds = max(1, int(deadline - time.monotonic()))
            read_result = self.runner.run(
                [
                    "teams-cli",
                    "chat",
                    "read",
                    chat_id,
                    "--limit",
                    str(messages_per_chat),
                    "--json",
                ],
                timeout_seconds=min(TEAMS_COMMAND_TIMEOUT_SECONDS, remaining_seconds),
                max_output_bytes=COMMAND_OUTPUT_LIMIT_BYTES,
            )
            searched_chat_count += 1
            if read_result.returncode != 0:
                partial_reasons.append("chat_read_failed")
                continue
            read_payload = _decode_json(read_result.stdout)
            messages = self._successful_data_list(read_payload, nested_key="messages")
            if messages is None:
                partial_reasons.append("chat_read_failed")
                continue
            if len(messages) >= messages_per_chat and self._messages_can_omit_range(
                messages, date_range
            ):
                partial_reasons.append("message_limit_reached")

            for message in messages:
                item = self._normalize_teams_message(message, chat, date_range, query_text)
                if item is None:
                    continue
                if len(items) >= limit:
                    partial_reasons.append("result_limit_reached")
                    break
                items.append(item)

        reasons = list(dict.fromkeys(partial_reasons))
        return _envelope(
            "teams",
            "search",
            success=True,
            status="available",
            message="Teams search completed.",
            installed=True,
            authenticated=True,
            items=items,
            metadata={
                "isPartial": bool(reasons),
                "partialReasons": reasons,
                "requestedLimit": limit,
                "returnedCount": len(items),
                "filtering": "client_side",
                "chatLimit": TEAMS_CHAT_LIMIT,
                "messagesPerChat": messages_per_chat,
                "searchedChatCount": searched_chat_count,
            },
        )

    @staticmethod
    def _successful_data_list(
        payload: dict[str, Any] | None, *, nested_key: str
    ) -> list[Any] | None:
        if payload is None or payload.get("success") is not True:
            return None
        data = payload.get("data")
        if isinstance(data, list):
            return data
        if isinstance(data, dict) and isinstance(data.get(nested_key), list):
            return data[nested_key]
        return None

    @staticmethod
    def _messages_can_omit_range(messages: list[Any], date_range: DateRange) -> bool:
        timestamps = [
            timestamp
            for message in messages
            if isinstance(message, dict)
            if (timestamp := _parse_timestamp(message.get("createdDateTime"))) is not None
        ]
        if len(timestamps) != len(messages):
            return True
        return min(timestamps) >= date_range.start

    @staticmethod
    def _normalize_teams_message(
        message: Any,
        chat: dict[str, Any],
        date_range: DateRange,
        query_text: str,
    ) -> dict[str, Any] | None:
        if not isinstance(message, dict):
            return None
        timestamp = _parse_timestamp(message.get("createdDateTime"))
        if timestamp is None or not (date_range.start <= timestamp < date_range.end):
            return None
        body_data = message.get("body")
        body_data = body_data if isinstance(body_data, dict) else {}
        content = body_data.get("content") if isinstance(body_data.get("content"), str) else ""
        content_type = str(body_data.get("contentType", "")).casefold()
        body = _html_to_text(content) if content_type == "html" else content.strip()
        subject = message.get("subject") if isinstance(message.get("subject"), str) else ""
        topic = chat.get("topic") if isinstance(chat.get("topic"), str) else ""
        if query_text and query_text not in " ".join((subject, topic, body)).casefold():
            return None
        sender = message.get("from")
        sender = sender.get("user") if isinstance(sender, dict) else None
        sender = sender if isinstance(sender, dict) else {}
        display_name = (
            sender.get("displayName") if isinstance(sender.get("displayName"), str) else None
        )
        chat_type = chat.get("chatType") if isinstance(chat.get("chatType"), str) else None
        return {
            "id": str(message.get("id") or ""),
            "source": "teams",
            "timestamp": timestamp.astimezone(UTC).isoformat().replace("+00:00", "Z"),
            "title": subject or topic or display_name or "Teams message",
            "body": body[:MAX_ITEM_BODY_CHARACTERS],
            "url": message.get("webUrl") if isinstance(message.get("webUrl"), str) else None,
            "author": {
                "id": sender.get("id") if isinstance(sender.get("id"), str) else None,
                "displayName": display_name,
            },
            "context": {
                "id": chat.get("id"),
                "name": topic or None,
                "type": chat_type,
            },
        }

    @staticmethod
    def _normalize_slack_match(match: Any) -> dict[str, Any] | None:
        if not isinstance(match, dict):
            return None
        timestamp_value = match.get("ts")
        timestamp = None
        if isinstance(timestamp_value, (str, int, float)):
            try:
                timestamp = datetime.fromtimestamp(float(timestamp_value), tz=UTC).isoformat().replace(
                    "+00:00", "Z"
                )
            except (ValueError, OverflowError):
                timestamp = None
        channel = match.get("channel")
        channel = channel if isinstance(channel, dict) else {}
        channel_name = channel.get("name") if isinstance(channel.get("name"), str) else None
        username = match.get("username") if isinstance(match.get("username"), str) else None
        body = match.get("text") if isinstance(match.get("text"), str) else ""
        return {
            "id": str(match.get("ts") or match.get("id") or ""),
            "source": "slack",
            "timestamp": timestamp,
            "title": f"#{channel_name}" if channel_name else (username or "Slack message"),
            "body": body[:MAX_ITEM_BODY_CHARACTERS],
            "url": match.get("permalink") if isinstance(match.get("permalink"), str) else None,
            "author": {
                "id": match.get("user") if isinstance(match.get("user"), str) else None,
                "displayName": username,
            },
            "context": {
                "id": channel.get("id") if isinstance(channel.get("id"), str) else None,
                "name": channel_name,
                "type": "chat" if channel.get("is_im") is True else "channel",
            },
        }

    def _search_command_failure(self, source: str, returncode: int) -> dict[str, Any] | None:
        if returncode == 0:
            return None
        if returncode == 127:
            return _envelope(
                source,
                "search",
                success=False,
                status="unavailable",
                message=f"{self._display_name(source)} CLI is not installed.",
                installed=False,
                authenticated=False,
            )
        if returncode == 2:
            return self._auth_required(source, action="search", success=False)
        if returncode == 124:
            return self._failure(source, "search", "timed_out", "Source search timed out.")
        if returncode == 125:
            return self._failure(
                source, "search", "output_limit_exceeded", "Source search output exceeded the limit."
            )
        return self._failure(source, "search", "command_error", "Source search failed.")

    @staticmethod
    def _cli_name(source: str) -> str:
        try:
            return SOURCE_CLI_MAP[source]
        except KeyError as exc:
            raise ValueError(f"Unsupported source: {source}") from exc

    @staticmethod
    def _display_name(source: str) -> str:
        return "Slack" if source == "slack" else "Teams"

    def _auth_required(self, source: str, *, action: str, success: bool) -> dict[str, Any]:
        return _envelope(
            source,
            action,
            success=success,
            status="auth_required",
            message=f"{self._display_name(source)} authentication is required.",
            installed=True,
            authenticated=False,
        )

    def _failure(self, source: str, action: str, status: str, message: str) -> dict[str, Any]:
        return _envelope(
            source,
            action,
            success=False,
            status=status,
            message=message,
            installed=True,
            authenticated=False,
        )


class AIPIMHealthChecker:
    def __init__(self, runner: CLIRunner | None = None) -> None:
        self.runner = runner or CLIRunner(timeout_seconds=10)

    def check(self, cli_name: str) -> SourceHealth:
        source = CLI_SOURCE_MAP.get(cli_name, SourceKind.OUTLOOK)
        result = self.runner.run([cli_name, "--version"])
        if result.returncode == 0:
            return SourceHealth(source, "available", result.stdout.strip() or f"{cli_name} available")
        if result.returncode == 127:
            return SourceHealth(source, "unavailable", f"{cli_name} is not installed or not on PATH")
        if result.returncode == 124:
            return SourceHealth(source, "timed_out", f"{cli_name} health check timed out")
        return SourceHealth(source, "unavailable", result.stderr.strip() or f"{cli_name} failed")
