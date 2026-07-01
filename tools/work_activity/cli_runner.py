from __future__ import annotations

import subprocess
from dataclasses import dataclass


@dataclass(frozen=True)
class CLIResult:
    args: list[str]
    returncode: int
    stdout: str
    stderr: str


class CLIRunner:
    def __init__(self, timeout_seconds: int = 30) -> None:
        self.timeout_seconds = timeout_seconds

    def run(self, args: list[str]) -> CLIResult:
        try:
            completed = subprocess.run(
                args,
                text=True,
                capture_output=True,
                timeout=self.timeout_seconds,
                check=False,
            )
            return CLIResult(
                args=args,
                returncode=completed.returncode,
                stdout=completed.stdout,
                stderr=completed.stderr,
            )
        except FileNotFoundError:
            return CLIResult(args=args, returncode=127, stdout="", stderr=f"Command not found: {args[0]}")
        except subprocess.TimeoutExpired:
            return CLIResult(args=args, returncode=124, stdout="", stderr=f"Command timed out: {args[0]}")
