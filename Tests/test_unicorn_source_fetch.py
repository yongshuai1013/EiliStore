#!/usr/bin/env python3
"""Regression tests for the on-device Unicorn source fetch retry behavior.

The builder is run as a subprocess with mocked platform/build tools. No network,
Apple toolchain, credentials, or physical device is used.
"""
from __future__ import annotations

import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import textwrap
import unittest


ROOT = Path(__file__).resolve().parents[1]
BUILDER = ROOT / "Scripts" / "build-on-device-anisette.sh"
PINNED_REPO = "https://github.com/mahee96/unicorn.git"
PINNED_REV = "a53ddc9ac6d65b24936d4a37917333fcd816cfd0"


class UnicornSourceFetchTests(unittest.TestCase):
    def run_builder(self, failures: int = 0, permanent_failure: bool = False,
                    mismatch: bool = False) -> tuple[subprocess.CompletedProcess[str], list[str]]:
        with tempfile.TemporaryDirectory(prefix="unicorn-fetch-test-") as temp:
            base = Path(temp)
            bindir = base / "bin"
            bindir.mkdir()
            state = base / "state"
            state.mkdir()
            log = state / "calls.log"

            def stub(name: str, body: str) -> None:
                path = bindir / name
                path.write_text("#!/bin/sh\n" + textwrap.dedent(body), encoding="utf-8")
                path.chmod(0o755)

            stub("uname", 'echo Darwin\n')
            stub("xcrun", 'case "$*" in *--show-sdk-path*) echo /fake/sdk;; *) echo /fake/clang;; esac\n')
            stub("cmake", 'echo cmake >> "$MOCK_LOG"\nexit 55\n')
            stub("xcodebuild", 'echo xcodebuild >> "$MOCK_LOG"\nexit 99\n')
            stub("sleep", 'exit 0\n')
            # Keep the real interpreter available for this stateful, deterministic git mock.
            git_body = f"""
                import os, pathlib, sys
                root = pathlib.Path(os.environ['MOCK_STATE'])
                log = pathlib.Path(os.environ['MOCK_LOG'])
                args = sys.argv[1:]
                with log.open('a') as f: f.write('git ' + ' '.join(args) + '\\n')
                cmd = args[0] if args else ''
                rest = args[1:]
                if cmd == '-C':
                    rest = rest[1:]
                    cmd = rest[0] if rest else ''
                    rest = rest[1:]
                if cmd == 'init' or (cmd == 'remote' and rest and rest[0] == 'add'):
                    sys.exit(0)
                if cmd == 'clone':
                    sys.exit(97)
                if cmd == 'fetch':
                    nfile = root / 'fetch-count'
                    n = int(nfile.read_text()) + 1 if nfile.exists() else 1
                    nfile.write_text(str(n))
                    configured_failures = int(os.environ['MOCK_FAILURES'])
                    if os.environ['MOCK_PERMANENT'] == '1' or n <= configured_failures:
                        sys.exit(128)
                    sys.exit(0)
                if cmd == 'checkout':
                    sys.exit(0)
                if cmd == 'rev-parse':
                    sys.stdout.write(('0000000000000000000000000000000000000000' if os.environ['MOCK_MISMATCH'] == '1' else os.environ['MOCK_REV']) + '\\n')
                    sys.exit(0)
                sys.exit(96)
            """
            git_mock = base / "git_mock.py"
            git_mock.write_text(textwrap.dedent(git_body), encoding="utf-8")
            stub("git", f'exec {shlex.quote(sys.executable)} {shlex.quote(str(git_mock))} "$@"\n')
            # Invoke the real interpreter explicitly; only the build tools are mocked.
            env = os.environ.copy()
            env.update({
                "PATH": str(bindir) + os.pathsep + env.get("PATH", ""),
                "TMPDIR": str(base / "tmp"),
                "EILI_UNICORN_PACKAGE": str(base / "package"),
                "MOCK_STATE": str(state),
                "MOCK_LOG": str(log),
                "MOCK_FAILURES": str(failures),
                "MOCK_PERMANENT": "1" if permanent_failure else "0",
                "MOCK_MISMATCH": "1" if mismatch else "0",
                "MOCK_REV": PINNED_REV,
            })
            (base / "tmp").mkdir()
            result = subprocess.run(["bash", str(BUILDER)], cwd=ROOT, env=env,
                                    text=True, capture_output=True, check=False)
            calls = log.read_text(encoding="utf-8").splitlines() if log.exists() else []
            return result, calls

    def fetch_count(self, calls: list[str]) -> int:
        return sum(" fetch " in f" {line} " for line in calls)

    def test_transient_first_two_fetches_then_success_reaches_cmake(self) -> None:
        result, calls = self.run_builder(failures=2)
        self.assertEqual(result.returncode, 55, result.stdout + result.stderr)
        self.assertEqual(self.fetch_count(calls), 3)
        self.assertTrue(any(f"remote add origin {PINNED_REPO}" in line for line in calls))
        fetches = [line for line in calls if " fetch " in f" {line} "]
        self.assertTrue(all(line.endswith(f"fetch --depth 1 origin {PINNED_REV}") for line in fetches))
        self.assertIn("cmake", calls)

    def test_permanent_fetch_failure_stops_after_three_without_checkout_or_cmake(self) -> None:
        result, calls = self.run_builder(permanent_failure=True)
        self.assertEqual(result.returncode, 128, result.stdout + result.stderr)
        self.assertEqual(self.fetch_count(calls), 3)
        self.assertFalse(any(" checkout " in f" {line} " for line in calls))
        self.assertNotIn("cmake", calls)

    def test_successful_first_fetch_attempts_only_once(self) -> None:
        result, calls = self.run_builder()
        self.assertEqual(result.returncode, 55, result.stdout + result.stderr)
        self.assertEqual(self.fetch_count(calls), 1)
        self.assertIn("cmake", calls)

    def test_fetched_revision_mismatch_fails_guard_before_cmake(self) -> None:
        result, calls = self.run_builder(mismatch=True)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(self.fetch_count(calls), 1)
        self.assertTrue(any(" checkout " in f" {line} " for line in calls))
        self.assertTrue(any("rev-parse HEAD" in line for line in calls))
        self.assertNotIn("cmake", calls)


if __name__ == "__main__":
    unittest.main()
