from __future__ import annotations

from dataclasses import dataclass

from .cli_runner import CLIRunner


@dataclass(frozen=True)
class DeliveryResult:
    ok: bool
    message: str


class SlackDelivery:
    def __init__(self, runner: CLIRunner | None = None) -> None:
        self.runner = runner or CLIRunner(timeout_seconds=30)

    def send_direct_message(self, user_id: str, body: str) -> DeliveryResult:
        result = self.runner.run(
            ["slack-cli", "message", "send", "--user-id", user_id, "--body", body]
        )
        if result.returncode == 0:
            return DeliveryResult(ok=True, message=result.stdout.strip() or "Slack message sent")
        return DeliveryResult(
            ok=False,
            message=result.stderr.strip() or f"slack-cli exited with status {result.returncode}",
        )
