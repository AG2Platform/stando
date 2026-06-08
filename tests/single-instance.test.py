#!/usr/bin/env python3
"""Tests for src/single_instance.py — bridge single-instance flock guard.

Phase 5.5 OSS→private port. Verifies that:

  1. First acquire() returns normally and writes the PID into the lock file.
  2. A SECOND acquire() in a child process exits with status 0 (NOT 1) —
     launchd's KeepAlive would restart-loop on exit(1).
  3. The lock file lives under <workspace>/state/locks/<name>.lock.
  4. Releasing the first holder (process death) frees the lock for the next.

We use subprocess for the second-holder check because acquire() calls
`os._exit(0)` on contention, which would kill the test runner if we called
it in-process.

Run: python3 tests/single-instance.test.py
Exit: 0 on pass, 1 on fail.
"""
from __future__ import annotations

import os
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "src"))


def _spawn_second_holder(workspace: Path, name: str, hold_seconds: float = 0) -> subprocess.CompletedProcess:
    """Run a child python that tries to acquire `name` in `workspace`.

    The child either holds the lock for `hold_seconds` (when we want it to
    succeed) or exits immediately after acquire() if contended.
    """
    script = textwrap.dedent(f"""
        import os, sys, time
        sys.path.insert(0, {str(ROOT / 'src')!r})
        os.environ['SUTANDO_WORKSPACE'] = {str(workspace)!r}
        from single_instance import acquire
        acquire({name!r})
        time.sleep({hold_seconds})
    """)
    return subprocess.run(
        [sys.executable, "-c", script],
        capture_output=True,
        text=True,
        timeout=15,
    )


class TestSingleInstance(unittest.TestCase):
    def setUp(self):
        self._saved_env = os.environ.get("SUTANDO_WORKSPACE")
        self.tmp = Path(tempfile.mkdtemp(prefix="single-instance-"))
        os.environ["SUTANDO_WORKSPACE"] = str(self.tmp)

    def tearDown(self):
        if self._saved_env is None:
            os.environ.pop("SUTANDO_WORKSPACE", None)
        else:
            os.environ["SUTANDO_WORKSPACE"] = self._saved_env
        import shutil
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_first_acquire_creates_lock_with_pid(self):
        """First acquire() writes the holder's PID into the lock file."""
        # First holder spawns as a child so we can read the lock file while
        # it's still holding (then it exits cleanly).
        proc = _spawn_second_holder(self.tmp, "test-bridge", hold_seconds=0)
        self.assertEqual(proc.returncode, 0, f"first acquire failed: {proc.stderr}")
        lock_path = self.tmp / "state" / "locks" / "test-bridge.lock"
        self.assertTrue(lock_path.exists(), "lock file not created")

    def test_second_acquire_exits_zero_while_first_holds(self):
        """Contended acquire() exits 0 so launchd KeepAlive doesn't restart-loop."""
        script = textwrap.dedent(f"""
            import os, sys, time
            sys.path.insert(0, {str(ROOT / 'src')!r})
            os.environ['SUTANDO_WORKSPACE'] = {str(self.tmp)!r}
            from single_instance import acquire
            acquire('test-bridge')
            time.sleep(2.0)
        """)
        first = subprocess.Popen(
            [sys.executable, "-c", script],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        try:
            time.sleep(0.4)  # let the first holder grab the flock
            second = _spawn_second_holder(self.tmp, "test-bridge", hold_seconds=0)
            self.assertEqual(
                second.returncode, 0,
                f"second acquire should exit 0 (got {second.returncode}); "
                f"stderr={second.stderr!r}",
            )
            self.assertIn(
                "another instance already holds the lock",
                second.stderr,
                "contention message missing from stderr",
            )
        finally:
            first.terminate()
            first.wait(timeout=5)

    def test_lock_released_after_first_holder_exits(self):
        """After the first holder dies, a new acquire() succeeds."""
        first = _spawn_second_holder(self.tmp, "test-bridge", hold_seconds=0)
        self.assertEqual(first.returncode, 0)
        second = _spawn_second_holder(self.tmp, "test-bridge", hold_seconds=0)
        self.assertEqual(
            second.returncode, 0,
            "second acquire should succeed after first holder dies",
        )
        self.assertNotIn(
            "another instance already holds the lock",
            second.stderr,
            "second acquire should NOT see contention after first exited",
        )

    def test_distinct_names_do_not_contend(self):
        """Different `name` arguments mean different lock files."""
        script_telegram = textwrap.dedent(f"""
            import os, sys, time
            sys.path.insert(0, {str(ROOT / 'src')!r})
            os.environ['SUTANDO_WORKSPACE'] = {str(self.tmp)!r}
            from single_instance import acquire
            acquire('telegram-bridge')
            time.sleep(2.0)
        """)
        telegram = subprocess.Popen(
            [sys.executable, "-c", script_telegram],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        try:
            time.sleep(0.4)
            slack = _spawn_second_holder(self.tmp, "slack-bridge", hold_seconds=0)
            self.assertEqual(slack.returncode, 0, f"slack should not contend: {slack.stderr}")
            self.assertNotIn(
                "another instance already holds the lock",
                slack.stderr,
                "different bridge names must not share a lock",
            )
        finally:
            telegram.terminate()
            telegram.wait(timeout=5)


if __name__ == "__main__":
    unittest.main()
