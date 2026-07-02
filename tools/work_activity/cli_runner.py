from __future__ import annotations

import os
import selectors
import subprocess
import time
from dataclasses import dataclass


@dataclass(frozen=True)
class CLIResult:
    args: list[str]
    returncode: int
    stdout: str
    stderr: str


class CLIRunner:
    def __init__(self, timeout_seconds: int = 30, max_output_bytes: int = 1_048_576) -> None:
        self.timeout_seconds = timeout_seconds
        self.max_output_bytes = max_output_bytes

    def run(
        self,
        args: list[str],
        *,
        timeout_seconds: int | None = None,
        max_output_bytes: int | None = None,
    ) -> CLIResult:
        timeout = timeout_seconds if timeout_seconds is not None else self.timeout_seconds
        output_limit = max_output_bytes if max_output_bytes is not None else self.max_output_bytes
        try:
            process = subprocess.Popen(
                args,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                shell=False,
            )
        except FileNotFoundError:
            return CLIResult(args=args, returncode=127, stdout="", stderr=f"Command not found: {args[0]}")
        except OSError:
            return CLIResult(args=args, returncode=126, stdout="", stderr="Command could not be started")

        assert process.stdout is not None
        assert process.stderr is not None
        selector = selectors.DefaultSelector()
        selector.register(process.stdout, selectors.EVENT_READ, "stdout")
        selector.register(process.stderr, selectors.EVENT_READ, "stderr")
        captured = {"stdout": bytearray(), "stderr": bytearray()}
        captured_bytes = 0
        deadline = time.monotonic() + timeout

        try:
            while selector.get_map():
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    process.kill()
                    process.wait()
                    return CLIResult(args=args, returncode=124, stdout="", stderr="Command timed out")

                for key, _ in selector.select(timeout=min(remaining, 0.1)):
                    chunk = os.read(key.fileobj.fileno(), 65_536)
                    if not chunk:
                        selector.unregister(key.fileobj)
                        key.fileobj.close()
                        continue
                    captured_bytes += len(chunk)
                    if captured_bytes > output_limit:
                        process.kill()
                        process.wait()
                        return CLIResult(
                            args=args,
                            returncode=125,
                            stdout="",
                            stderr="Command output exceeded limit",
                        )
                    captured[key.data].extend(chunk)

            returncode = process.wait(timeout=max(0.0, deadline - time.monotonic()))
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
            return CLIResult(args=args, returncode=124, stdout="", stderr="Command timed out")
        finally:
            selector.close()
            if not process.stdout.closed:
                process.stdout.close()
            if not process.stderr.closed:
                process.stderr.close()

        return CLIResult(
            args=args,
            returncode=returncode,
            stdout=captured["stdout"].decode("utf-8", errors="replace"),
            stderr=captured["stderr"].decode("utf-8", errors="replace"),
        )
