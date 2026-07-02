import contextlib
import io
import json
import sys
import unittest
from datetime import datetime
from unittest.mock import patch
from zoneinfo import ZoneInfo

from tools.work_activity import cli as work_activity_cli
from tools.work_activity.cli_runner import CLIResult, CLIRunner
from tools.work_activity.connectors.ai_pim import AIPIMHarness
from tools.work_activity.models import DateRange


def make_range() -> DateRange:
    timezone = "America/New_York"
    return DateRange(
        start=datetime(2026, 7, 1, tzinfo=ZoneInfo(timezone)),
        end=datetime(2026, 7, 3, tzinfo=ZoneInfo(timezone)),
        timezone=timezone,
        label="2026-07-01 to 2026-07-02",
    )


def cli_result(args: list[str], returncode: int = 0, payload: object | None = None) -> CLIResult:
    return CLIResult(
        args=args,
        returncode=returncode,
        stdout="" if payload is None else json.dumps(payload),
        stderr="",
    )


class FakeRunner:
    def __init__(self, results: list[CLIResult]) -> None:
        self.results = list(results)
        self.calls: list[tuple[list[str], int | None, int | None]] = []

    def run(
        self,
        args: list[str],
        *,
        timeout_seconds: int | None = None,
        max_output_bytes: int | None = None,
    ) -> CLIResult:
        self.calls.append((args, timeout_seconds, max_output_bytes))
        if not self.results:
            raise AssertionError(f"Unexpected command: {args}")
        return self.results.pop(0)


class AIPIMHarnessStatusTests(unittest.TestCase):
    def test_missing_slack_cli_reports_stable_unavailable_status(self):
        fake = FakeRunner(
            [
                CLIResult(
                    args=["slack-cli", "auth", "status"],
                    returncode=127,
                    stdout="",
                    stderr="Command not found: slack-cli",
                )
            ]
        )

        result = AIPIMHarness(runner=fake).status("slack")

        self.assertEqual(result["schemaVersion"], 1)
        self.assertTrue(result["success"])
        self.assertEqual(result["source"], "slack")
        self.assertEqual(result["action"], "status")
        self.assertEqual(result["status"], "unavailable")
        self.assertEqual(result["data"], {"installed": False, "authenticated": False, "items": []})
        self.assertNotIn("Command not found", json.dumps(result))
        self.assertEqual(fake.calls[0][0], ["slack-cli", "auth", "status"])

    def test_slack_auth_required_is_not_reported_as_unavailable(self):
        fake = FakeRunner(
            [
                CLIResult(
                    args=["slack-cli", "auth", "status"],
                    returncode=2,
                    stdout="",
                    stderr="authentication required",
                )
            ]
        )

        result = AIPIMHarness(runner=fake).status("slack")

        self.assertTrue(result["success"])
        self.assertEqual(result["status"], "auth_required")
        self.assertTrue(result["data"]["installed"])
        self.assertFalse(result["data"]["authenticated"])

    def test_teams_status_requires_success_true(self):
        args = ["teams-cli", "auth", "status", "--json"]
        fake = FakeRunner(
            [
                cli_result(
                    args,
                    payload={
                        "success": False,
                        "error": {"code": "AUTH_REQUIRED", "message": "secret detail"},
                    },
                )
            ]
        )

        result = AIPIMHarness(runner=fake).status("teams")

        self.assertFalse(result["success"])
        self.assertEqual(result["status"], "auth_required")
        self.assertNotIn("secret detail", json.dumps(result))

    def test_teams_status_decodes_authenticated_state(self):
        args = ["teams-cli", "auth", "status", "--json"]
        fake = FakeRunner(
            [
                cli_result(
                    args,
                    payload={
                        "success": True,
                        "data": {"authenticated": True, "username": "jp@example.com"},
                    },
                )
            ]
        )

        result = AIPIMHarness(runner=fake).status("teams")

        self.assertTrue(result["success"])
        self.assertEqual(result["status"], "available")
        self.assertTrue(result["data"]["authenticated"])
        self.assertNotIn("jp@example.com", json.dumps(result))

    def test_login_uses_exact_command_and_does_not_forward_auth_output(self):
        sentinel = "callback-with-secret-code"
        fake = FakeRunner(
            [
                CLIResult(
                    args=["slack-cli", "auth", "login"],
                    returncode=0,
                    stdout=sentinel,
                    stderr="",
                )
            ]
        )

        result = AIPIMHarness(runner=fake).login("slack")

        self.assertTrue(result["success"])
        self.assertEqual(result["status"], "available")
        self.assertEqual(fake.calls[0][0], ["slack-cli", "auth", "login"])
        self.assertNotIn(sentinel, json.dumps(result))


class AIPIMHarnessSlackTests(unittest.TestCase):
    def test_slack_search_is_date_user_and_result_bounded(self):
        payload = {
            "success": True,
            "data": {
                "query": "must not be returned",
                "messages": {
                    "total": 1,
                    "matches": [
                        {
                            "ts": "1782916200.125000",
                            "user": "U123",
                            "username": "JP",
                            "text": "Shipped the source adapter.",
                            "permalink": "https://example.slack.com/archives/C123/p1782916200125000",
                            "channel": {"id": "C123", "name": "noteai"},
                            "access_token": "must-never-escape",
                        }
                    ],
                    "pagination": {"page": 1, "page_count": 1},
                },
            },
        }
        fake = FakeRunner([cli_result([], payload=payload)])

        result = AIPIMHarness(runner=fake).search(
            "slack",
            make_range(),
            query="NoteAI adapter",
            limit=25,
        )

        self.assertTrue(result["success"])
        self.assertEqual(
            fake.calls[0][0],
            [
                "slack-cli",
                "message",
                "search",
                "--query",
                "NoteAI adapter from:me after:2026-07-01 before:2026-07-03",
                "--limit",
                "25",
                "--page",
                "1",
                "--output",
                "json",
            ],
        )
        self.assertEqual(result["data"]["items"][0]["body"], "Shipped the source adapter.")
        self.assertEqual(result["data"]["items"][0]["context"]["name"], "noteai")
        self.assertEqual(result["metadata"]["filtering"], "server_side")
        self.assertFalse(result["metadata"]["isPartial"])
        serialized = json.dumps(result)
        self.assertNotIn("must-never-escape", serialized)
        self.assertNotIn("must not be returned", serialized)

    def test_slack_marks_page_one_partial_when_more_matches_exist(self):
        payload = {
            "success": True,
            "data": {
                "messages": {
                    "total": 40,
                    "matches": [],
                    "pagination": {"page": 1, "page_count": 2},
                }
            },
        }
        fake = FakeRunner([cli_result([], payload=payload)])

        result = AIPIMHarness(runner=fake).search("slack", make_range(), limit=20)

        self.assertTrue(result["metadata"]["isPartial"])
        self.assertIn("result_limit_reached", result["metadata"]["partialReasons"])

    def test_slack_rejects_success_false_even_with_zero_exit_status(self):
        fake = FakeRunner(
            [
                cli_result(
                    [],
                    payload={"success": False, "error": {"message": "raw MCP failure"}},
                )
            ]
        )

        result = AIPIMHarness(runner=fake).search("slack", make_range())

        self.assertFalse(result["success"])
        self.assertEqual(result["status"], "command_error")
        self.assertEqual(result["data"]["items"], [])
        self.assertNotIn("raw MCP failure", json.dumps(result))

    def test_slack_malformed_json_is_a_normalized_error(self):
        fake = FakeRunner(
            [
                CLIResult(
                    args=[],
                    returncode=0,
                    stdout="not-json and not safe to return",
                    stderr="",
                )
            ]
        )

        result = AIPIMHarness(runner=fake).search("slack", make_range())

        self.assertFalse(result["success"])
        self.assertEqual(result["status"], "invalid_response")
        self.assertNotIn("not-json", json.dumps(result))

    def test_slack_timeout_is_a_normalized_error(self):
        fake = FakeRunner(
            [CLIResult(args=[], returncode=124, stdout="", stderr="Command timed out: slack-cli")]
        )

        result = AIPIMHarness(runner=fake).search("slack", make_range())

        self.assertFalse(result["success"])
        self.assertEqual(result["status"], "timed_out")


class AIPIMHarnessTeamsTests(unittest.TestCase):
    def test_teams_search_enumerates_chats_filters_dates_and_normalizes_html(self):
        chats_payload = {
            "success": True,
            "data": [{"id": "chat-1", "topic": "NoteAI", "chatType": "group"}],
        }
        messages_payload = {
            "success": True,
            "data": [
                {
                    "id": "message-1",
                    "createdDateTime": "2026-07-01T15:00:00Z",
                    "from": {"user": {"id": "user-1", "displayName": "JP"}},
                    "body": {
                        "contentType": "html",
                        "content": "<p>Shipped <b>NoteAI</b>&nbsp;adapter.</p><p>Next step ready.</p>",
                    },
                    "webUrl": "https://teams.example/messages/1",
                    "refresh_token": "must-never-escape",
                },
                {
                    "id": "message-old",
                    "createdDateTime": "2026-06-30T20:00:00Z",
                    "from": {"user": {"id": "user-1", "displayName": "JP"}},
                    "body": {"contentType": "text", "content": "Outside the range"},
                },
            ],
        }
        fake = FakeRunner(
            [cli_result([], payload=chats_payload), cli_result([], payload=messages_payload)]
        )

        result = AIPIMHarness(runner=fake).search(
            "teams",
            make_range(),
            query="NoteAI",
            limit=20,
            messages_per_chat=2,
        )

        self.assertEqual(fake.calls[0][0], ["teams-cli", "chat", "list", "--limit", "50", "--json"])
        self.assertEqual(
            fake.calls[1][0],
            ["teams-cli", "chat", "read", "chat-1", "--limit", "2", "--json"],
        )
        self.assertTrue(result["success"])
        self.assertEqual(len(result["data"]["items"]), 1)
        item = result["data"]["items"][0]
        self.assertEqual(item["body"], "Shipped NoteAI adapter.\nNext step ready.")
        self.assertEqual(item["context"], {"id": "chat-1", "name": "NoteAI", "type": "group"})
        self.assertEqual(result["metadata"]["filtering"], "client_side")
        self.assertEqual(result["metadata"]["searchedChatCount"], 1)
        self.assertFalse(result["metadata"]["isPartial"])
        self.assertNotIn("must-never-escape", json.dumps(result))

    def test_teams_marks_results_partial_when_chat_limit_is_reached(self):
        chats = [{"id": f"chat-{index}"} for index in range(50)]
        results = [cli_result([], payload={"success": True, "data": chats})]
        results.extend(cli_result([], payload={"success": True, "data": []}) for _ in chats)
        fake = FakeRunner(results)

        result = AIPIMHarness(runner=fake).search("teams", make_range(), messages_per_chat=1)

        self.assertTrue(result["success"])
        self.assertTrue(result["metadata"]["isPartial"])
        self.assertIn("chat_limit_reached", result["metadata"]["partialReasons"])
        self.assertEqual(result["metadata"]["searchedChatCount"], 50)

    def test_teams_marks_results_partial_when_in_range_messages_fill_read_limit(self):
        fake = FakeRunner(
            [
                cli_result([], payload={"success": True, "data": [{"id": "chat-1"}]}),
                cli_result(
                    [],
                    payload={
                        "success": True,
                        "data": [
                            {
                                "id": "message-1",
                                "createdDateTime": "2026-07-02T15:00:00Z",
                                "body": {"contentType": "text", "content": "First"},
                            },
                            {
                                "id": "message-2",
                                "createdDateTime": "2026-07-01T15:00:00Z",
                                "body": {"contentType": "text", "content": "Second"},
                            },
                        ],
                    },
                ),
            ]
        )

        result = AIPIMHarness(runner=fake).search("teams", make_range(), messages_per_chat=2)

        self.assertTrue(result["metadata"]["isPartial"])
        self.assertIn("message_limit_reached", result["metadata"]["partialReasons"])

    def test_teams_rejects_malformed_chat_read_json_and_marks_partial(self):
        fake = FakeRunner(
            [
                cli_result([], payload={"success": True, "data": [{"id": "chat-1"}]}),
                CLIResult(args=[], returncode=0, stdout="not-json", stderr=""),
            ]
        )

        result = AIPIMHarness(runner=fake).search("teams", make_range())

        self.assertTrue(result["success"])
        self.assertEqual(result["data"]["items"], [])
        self.assertTrue(result["metadata"]["isPartial"])
        self.assertIn("chat_read_failed", result["metadata"]["partialReasons"])


class WorkActivitySourceCLITests(unittest.TestCase):
    def test_source_auth_status_prints_only_json_envelope(self):
        envelope = {
            "schemaVersion": 1,
            "success": True,
            "source": "slack",
            "action": "status",
            "status": "available",
            "message": "Slack is authenticated.",
            "data": {"installed": True, "authenticated": True, "items": []},
            "metadata": {"isPartial": False, "partialReasons": []},
        }
        harness = unittest.mock.Mock()
        harness.status.return_value = envelope
        stdout = io.StringIO()

        with patch.object(work_activity_cli, "AIPIMHarness", return_value=harness):
            with contextlib.redirect_stdout(stdout):
                exit_code = work_activity_cli.main(
                    ["source-auth", "--source", "slack", "--action", "status"]
                )

        self.assertEqual(exit_code, 0)
        self.assertEqual(json.loads(stdout.getvalue()), envelope)
        harness.status.assert_called_once_with("slack")

    def test_source_search_builds_requested_range(self):
        envelope = {
            "schemaVersion": 1,
            "success": True,
            "source": "teams",
            "action": "search",
            "status": "available",
            "message": "Teams search completed.",
            "data": {"installed": True, "authenticated": True, "items": []},
            "metadata": {"isPartial": False, "partialReasons": []},
        }
        harness = unittest.mock.Mock()
        harness.search.return_value = envelope

        with patch.object(work_activity_cli, "AIPIMHarness", return_value=harness):
            with contextlib.redirect_stdout(io.StringIO()):
                exit_code = work_activity_cli.main(
                    [
                        "source-search",
                        "--source",
                        "teams",
                        "--from",
                        "2026-07-01",
                        "--to",
                        "2026-07-02",
                        "--timezone",
                        "America/New_York",
                        "--query",
                        "NoteAI",
                        "--limit",
                        "20",
                        "--messages-per-chat",
                        "40",
                    ]
                )

        self.assertEqual(exit_code, 0)
        args = harness.search.call_args.args
        kwargs = harness.search.call_args.kwargs
        self.assertEqual(args[0], "teams")
        self.assertEqual(args[1].start.isoformat(), "2026-07-01T00:00:00-04:00")
        self.assertEqual(args[1].end.isoformat(), "2026-07-03T00:00:00-04:00")
        self.assertEqual(kwargs, {"query": "NoteAI", "limit": 20, "messages_per_chat": 40})


class BoundedCLIRunnerTests(unittest.TestCase):
    def test_output_cap_terminates_command_without_returning_output(self):
        runner = CLIRunner(timeout_seconds=5, max_output_bytes=64)

        result = runner.run([sys.executable, "-c", "print('x' * 4096)"])

        self.assertEqual(result.returncode, 125)
        self.assertEqual(result.stdout, "")
        self.assertEqual(result.stderr, "Command output exceeded limit")

    def test_timeout_terminates_command(self):
        runner = CLIRunner(timeout_seconds=1, max_output_bytes=1024)

        result = runner.run([sys.executable, "-c", "import time; time.sleep(5)"])

        self.assertEqual(result.returncode, 124)
        self.assertEqual(result.stdout, "")
        self.assertEqual(result.stderr, "Command timed out")


if __name__ == "__main__":
    unittest.main()
