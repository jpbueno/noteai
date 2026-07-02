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


def teams_auth_payload(username: str = "jp@example.com") -> dict[str, object]:
    return {"authenticated": True, "username": username}


def teams_members_payload(
    email: str = "jp@example.com", user_id: str = "user-1"
) -> dict[str, object]:
    return {
        "success": True,
        "data": [
            {"email": email, "userId": user_id, "displayName": "JP"},
            {"email": "other@example.com", "userId": "user-2", "displayName": "Other"},
        ],
    }


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
                    args=["slack-cli", "me", "--output", "json"],
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
        self.assertEqual(fake.calls[0][0], ["slack-cli", "me", "--output", "json"])

    def test_slack_auth_required_is_not_reported_as_unavailable(self):
        fake = FakeRunner(
            [
                CLIResult(
                    args=["slack-cli", "me", "--output", "json"],
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

    def test_slack_status_requires_success_true_without_exposing_profile(self):
        profile_secret = "profile-token-metadata"
        fake = FakeRunner(
            [
                cli_result(
                    ["slack-cli", "me", "--output", "json"],
                    payload={
                        "success": True,
                        "data": {
                            "user": {
                                "id": "U123",
                                "email": "jp@example.com",
                                "profile": {"tokenMetadata": profile_secret},
                            }
                        },
                        "error": None,
                    },
                )
            ]
        )

        result = AIPIMHarness(runner=fake).status("slack")

        self.assertTrue(result["success"])
        self.assertEqual(result["status"], "available")
        self.assertTrue(result["data"]["authenticated"])
        serialized = json.dumps(result)
        self.assertNotIn("jp@example.com", serialized)
        self.assertNotIn(profile_secret, serialized)
        self.assertEqual(fake.calls[0][0], ["slack-cli", "me", "--output", "json"])

    def test_slack_status_rejects_success_false_with_zero_exit(self):
        fake = FakeRunner(
            [
                cli_result(
                    [],
                    payload={"success": False, "error": {"message": "raw status failure"}},
                )
            ]
        )

        result = AIPIMHarness(runner=fake).status("slack")

        self.assertFalse(result["success"])
        self.assertEqual(result["status"], "command_error")
        self.assertNotIn("raw status failure", json.dumps(result))

    def test_teams_status_decodes_standalone_authenticated_state(self):
        args = ["teams-cli", "auth", "status", "--json"]
        fake = FakeRunner(
            [
                cli_result(
                    args,
                    payload={"authenticated": True, "username": "jp@example.com"},
                )
            ]
        )

        result = AIPIMHarness(runner=fake).status("teams")

        self.assertTrue(result["success"])
        self.assertEqual(result["status"], "available")
        self.assertTrue(result["data"]["authenticated"])
        self.assertNotIn("jp@example.com", json.dumps(result))

    def test_teams_status_reports_standalone_authenticated_false(self):
        fake = FakeRunner(
            [
                cli_result(
                    ["teams-cli", "auth", "status", "--json"],
                    payload={"authenticated": False, "diagnostics": {"cache": "secret-path"}},
                )
            ]
        )

        result = AIPIMHarness(runner=fake).status("teams")

        self.assertTrue(result["success"])
        self.assertEqual(result["status"], "auth_required")
        self.assertFalse(result["data"]["authenticated"])
        self.assertNotIn("secret-path", json.dumps(result))

    def test_teams_status_rejects_malformed_json(self):
        fake = FakeRunner(
            [
                CLIResult(
                    args=["teams-cli", "auth", "status", "--json"],
                    returncode=0,
                    stdout="not-json",
                    stderr="",
                )
            ]
        )

        result = AIPIMHarness(runner=fake).status("teams")

        self.assertFalse(result["success"])
        self.assertEqual(result["status"], "invalid_response")
        self.assertNotIn("not-json", json.dumps(result))

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

    def test_slack_enforces_limit_after_normalizing_upstream_over_return(self):
        matches = [
            {
                "ts": f"178291620{index}.125000",
                "text": f"Message {index}",
                "channel": {"id": "C123", "name": "noteai"},
            }
            for index in range(3)
        ]
        fake = FakeRunner(
            [
                cli_result(
                    [],
                    payload={
                        "success": True,
                        "data": {
                            "messages": {
                                "total": 3,
                                "matches": matches,
                                "pagination": {"page": 1, "page_count": 1},
                            }
                        },
                    },
                )
            ]
        )

        result = AIPIMHarness(runner=fake).search("slack", make_range(), limit=2)

        self.assertEqual(len(result["data"]["items"]), 2)
        self.assertEqual(result["metadata"]["returnedCount"], 2)
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

    def test_slack_output_cap_is_a_normalized_error_without_raw_output(self):
        fake = FakeRunner(
            [
                CLIResult(
                    args=[],
                    returncode=125,
                    stdout="raw message content must not escape",
                    stderr="Command output exceeded limit",
                )
            ]
        )

        result = AIPIMHarness(runner=fake).search("slack", make_range())

        self.assertFalse(result["success"])
        self.assertEqual(result["status"], "output_limit_exceeded")
        self.assertEqual(result["data"]["items"], [])
        self.assertNotIn("raw message content", json.dumps(result))


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
                {
                    "id": "message-other-user",
                    "createdDateTime": "2026-07-01T16:00:00Z",
                    "from": {"user": {"id": "user-2", "displayName": "Other"}},
                    "body": {"contentType": "text", "content": "Other user NoteAI work"},
                },
            ],
        }
        fake = FakeRunner(
            [
                cli_result([], payload=teams_auth_payload("JP@EXAMPLE.COM")),
                cli_result([], payload=chats_payload),
                cli_result([], payload=teams_members_payload()),
                cli_result([], payload=messages_payload),
            ]
        )

        result = AIPIMHarness(runner=fake).search(
            "teams",
            make_range(),
            query="NoteAI",
            limit=20,
            messages_per_chat=2,
        )

        self.assertEqual(fake.calls[0][0], ["teams-cli", "auth", "status", "--json"])
        self.assertEqual(
            fake.calls[1][0],
            ["teams-cli", "chat", "list", "--limit", "50", "--json"],
        )
        self.assertEqual(
            fake.calls[2][0],
            ["teams-cli", "chat", "members", "chat-1", "--json"],
        )
        self.assertEqual(
            fake.calls[3][0],
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
        results = [
            cli_result([], payload=teams_auth_payload()),
            cli_result([], payload={"success": True, "data": chats}),
        ]
        for _ in chats:
            results.append(cli_result([], payload=teams_members_payload()))
            results.append(cli_result([], payload={"success": True, "data": []}))
        fake = FakeRunner(results)

        result = AIPIMHarness(runner=fake).search("teams", make_range(), messages_per_chat=1)

        self.assertTrue(result["success"])
        self.assertTrue(result["metadata"]["isPartial"])
        self.assertIn("chat_limit_reached", result["metadata"]["partialReasons"])
        self.assertEqual(result["metadata"]["searchedChatCount"], 50)
        member_calls = [call for call in fake.calls if call[0][2:3] == ["members"]]
        self.assertEqual(len(member_calls), 50)

    def test_teams_marks_results_partial_when_in_range_messages_fill_read_limit(self):
        fake = FakeRunner(
            [
                cli_result([], payload=teams_auth_payload()),
                cli_result([], payload={"success": True, "data": [{"id": "chat-1"}]}),
                cli_result([], payload=teams_members_payload()),
                cli_result(
                    [],
                    payload={
                        "success": True,
                        "data": [
                            {
                                "id": "message-1",
                                "createdDateTime": "2026-07-02T15:00:00Z",
                                "from": {"user": {"id": "user-1"}},
                                "body": {"contentType": "text", "content": "First"},
                            },
                            {
                                "id": "message-2",
                                "createdDateTime": "2026-07-01T15:00:00Z",
                                "from": {"user": {"id": "user-1"}},
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
                cli_result([], payload=teams_auth_payload()),
                cli_result([], payload={"success": True, "data": [{"id": "chat-1"}]}),
                cli_result([], payload=teams_members_payload()),
                CLIResult(args=[], returncode=0, stdout="not-json", stderr=""),
            ]
        )

        result = AIPIMHarness(runner=fake).search("teams", make_range())

        self.assertTrue(result["success"])
        self.assertEqual(result["data"]["items"], [])
        self.assertTrue(result["metadata"]["isPartial"])
        self.assertIn("chat_read_failed", result["metadata"]["partialReasons"])

    def test_teams_member_resolution_failure_is_partial_and_returns_no_other_users(self):
        fake = FakeRunner(
            [
                cli_result([], payload=teams_auth_payload()),
                cli_result(
                    [],
                    payload={
                        "success": True,
                        "data": [{"id": "chat-1"}, {"id": "chat-2"}],
                    },
                ),
                cli_result([], payload=teams_members_payload()),
                cli_result(
                    [],
                    payload={
                        "success": True,
                        "data": [
                            {
                                "id": "mine",
                                "createdDateTime": "2026-07-01T15:00:00Z",
                                "from": {"user": {"id": "user-1"}},
                                "body": {"contentType": "text", "content": "My work"},
                            },
                            {
                                "id": "theirs",
                                "createdDateTime": "2026-07-01T16:00:00Z",
                                "from": {"user": {"id": "user-2"}},
                                "body": {"contentType": "text", "content": "Their work"},
                            },
                        ],
                    },
                ),
                cli_result([], payload={"success": True, "data": []}),
            ]
        )

        result = AIPIMHarness(runner=fake).search("teams", make_range())

        self.assertEqual([item["id"] for item in result["data"]["items"]], ["mine"])
        self.assertTrue(result["metadata"]["isPartial"])
        self.assertIn("member_resolution_failed", result["metadata"]["partialReasons"])
        self.assertEqual(
            fake.calls[-1][0],
            ["teams-cli", "chat", "members", "chat-2", "--json"],
        )

    def test_teams_missing_auth_username_is_partial_and_stops_before_chat_enumeration(self):
        fake = FakeRunner(
            [cli_result([], payload={"authenticated": True, "diagnostics": {"cache": "secret"}})]
        )

        result = AIPIMHarness(runner=fake).search("teams", make_range())

        self.assertTrue(result["success"])
        self.assertEqual(result["data"]["items"], [])
        self.assertTrue(result["metadata"]["isPartial"])
        self.assertIn("identity_resolution_failed", result["metadata"]["partialReasons"])
        self.assertEqual(result["metadata"]["requestedLimit"], 50)
        self.assertEqual(result["metadata"]["messagesPerChat"], 50)
        self.assertEqual(len(fake.calls), 1)
        self.assertNotIn("secret", json.dumps(result))


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
