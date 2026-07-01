import subprocess
import sys
import unittest


class WorkActivityCLITests(unittest.TestCase):
    def run_cli(self, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, "-m", "tools.work_activity", *args],
            cwd=str(__import__("pathlib").Path(__file__).resolve().parents[3]),
            text=True,
            capture_output=True,
            check=False,
        )

    def test_help_lists_daily_summary_command(self):
        result = self.run_cli("--help")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("daily-summary", result.stdout)

    def test_daily_summary_dry_run_outputs_markdown(self):
        result = self.run_cli("daily-summary", "--date", "2026-07-01", "--dry-run")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("# Daily Task Summary — 2026-07-01", result.stdout)
        self.assertIn("No open tasks were identified for the day.", result.stdout)
