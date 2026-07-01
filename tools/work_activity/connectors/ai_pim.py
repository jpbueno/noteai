from __future__ import annotations

from ..cli_runner import CLIRunner
from ..models import SourceHealth, SourceKind


CLI_SOURCE_MAP = {
    "outlook-cli": SourceKind.OUTLOOK,
    "calendar-cli": SourceKind.CALENDAR,
    "meeting-cli": SourceKind.TEAMS,
    "teams-cli": SourceKind.TEAMS,
    "slack-cli": SourceKind.SLACK,
    "gdrive-cli": SourceKind.GOOGLE_DOC,
}


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
