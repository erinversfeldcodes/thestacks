"""Tests for run_test_suite MCP tool and _extract_summary helper."""

from __future__ import annotations

import unittest
from unittest.mock import patch, MagicMock

from project_tools import run_test_suite, _extract_summary


class TestExtractSummary(unittest.TestCase):
    """Test _extract_summary with sample output for each domain."""

    def test_elixir_summary(self):
        output = (
            "Compiling 5 files (.ex)\n"
            "...........\n"
            "Finished in 1.2 seconds (0.1s async, 1.1s sync)\n"
            "42 tests, 0 failures\n"
            "\n"
            "Randomized with seed 12345\n"
        )
        self.assertEqual(_extract_summary("elixir", output), "42 tests, 0 failures")

    def test_elixir_failures(self):
        output = "10 tests, 3 failures\n"
        self.assertEqual(_extract_summary("elixir", output), "10 tests, 3 failures")

    def test_elm_passed(self):
        output = (
            "elm-test 0.19.1-revision12\n"
            "Running 15 tests.\n"
            "TEST RUN PASSED\n"
            "\n"
            "Duration: 850 ms\n"
            "Passed:   15\n"
            "Failed:   0\n"
        )
        self.assertEqual(_extract_summary("elm", output), "TEST RUN PASSED")

    def test_elm_failed(self):
        output = "TEST RUN FAILED\n\nSome details\n"
        self.assertEqual(_extract_summary("elm", output), "TEST RUN FAILED")

    def test_rust_summary(self):
        output = (
            "running 8 tests\n"
            "test foo ... ok\n"
            "test bar ... ok\n"
            "test result: ok. 8 passed; 0 failed; 0 ignored\n"
        )
        self.assertEqual(
            _extract_summary("rust", output),
            "test result: ok. 8 passed; 0 failed; 0 ignored",
        )

    def test_python_passed(self):
        output = (
            "===== test session starts =====\n"
            "collected 12 items\n"
            "...........\n"
            "12 passed in 1.23s\n"
        )
        self.assertEqual(_extract_summary("python", output), "12 passed")

    def test_python_failed(self):
        output = "FAILED tests/test_foo.py::test_bar - AssertionError\n"
        self.assertEqual(_extract_summary("python", output), "FAILED")

    def test_fallback_last_line(self):
        output = "some random output\nlast line here\n"
        self.assertEqual(_extract_summary("elixir", output), "last line here")

    def test_empty_output(self):
        self.assertEqual(_extract_summary("elixir", ""), "No output")


class TestRunTestSuiteInvalidDomain(unittest.TestCase):
    """Test run_test_suite with invalid domain."""

    def test_unsupported_domain(self):
        result = run_test_suite("java")
        self.assertIn("error", result)
        self.assertIn("Unsupported domain", result["error"])
        self.assertIn("java", result["error"])

    def test_supported_domains_listed(self):
        result = run_test_suite("cobol")
        for domain in ("elixir", "elm", "python", "rust"):
            self.assertIn(domain, result["error"])


class TestRunTestSuiteReturnKeys(unittest.TestCase):
    """Test run_test_suite returns the expected keys on success."""

    @patch("project_tools.subprocess.run")
    def test_success_keys(self, mock_run: MagicMock):
        mock_run.return_value = MagicMock(
            returncode=0,
            stdout="42 tests, 0 failures\n",
            stderr="",
        )
        result = run_test_suite("elixir")
        expected_keys = {"domain", "passed", "summary", "output", "command"}
        self.assertEqual(set(result.keys()), expected_keys)
        self.assertEqual(result["domain"], "elixir")
        self.assertTrue(result["passed"])
        self.assertEqual(result["command"], "mix test")

    @patch("project_tools.subprocess.run")
    def test_failure_keys(self, mock_run: MagicMock):
        mock_run.return_value = MagicMock(
            returncode=1,
            stdout="1 test, 1 failure\n",
            stderr="",
        )
        result = run_test_suite("elixir")
        self.assertFalse(result["passed"])

    def test_missing_directory(self):
        result = run_test_suite("elixir", worktree_path="/nonexistent/path")
        self.assertIn("error", result)
        self.assertIn("does not exist", result["error"])

    @patch("project_tools.subprocess.run")
    def test_output_truncation(self, mock_run: MagicMock):
        long_output = "x" * 10000
        mock_run.return_value = MagicMock(
            returncode=0,
            stdout=long_output,
            stderr="",
        )
        result = run_test_suite("elixir")
        self.assertLessEqual(len(result["output"]), 5000)

    @patch("project_tools.subprocess.run")
    def test_timeout_handling(self, mock_run: MagicMock):
        import subprocess

        mock_run.side_effect = subprocess.TimeoutExpired(cmd="mix test", timeout=300)
        result = run_test_suite("elixir")
        self.assertFalse(result["passed"])
        self.assertIn("timed out", result["summary"])


if __name__ == "__main__":
    unittest.main()
