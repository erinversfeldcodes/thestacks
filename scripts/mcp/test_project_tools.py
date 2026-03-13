"""Tests for project_tools MCP server helpers and tools."""

from __future__ import annotations

import unittest
from pathlib import Path
from unittest.mock import patch, MagicMock

from project_tools import (
    run_test_suite,
    _extract_summary,
    _parse_feedback_file,
    _worktree_info,
    create_worktree,
    remove_worktree,
    get_feedback_summary,
    draft_issue,
)
from dod_templates import DOD_TEMPLATES, DOMAIN_AGENTS


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


# ---------------------------------------------------------------------------
# Feedback parsing tests
# ---------------------------------------------------------------------------

_HEADER = """\
# Feedback Log: test-agent

> Preamble text.

<!-- Entries below this line -->
"""

_OPEN_ENTRY = """\
## 2026-03-13 — Issue #014, Phase 2
**Reviewer axis:** Code Quality
**Finding:** Missing typespecs on 3 public functions
**Root cause:** Prompt does not require typespecs
**Prompt change needed:** Add typespec rule
**Status:** open
"""

_APPLIED_ENTRY = """\
## 2026-03-10 — Issue #012, Phase 1
**Reviewer axis:** Security
**Finding:** Hardcoded secret in config
**Root cause:** No secret-scanning reminder
**Prompt change needed:** Add secret-scanning step
**Status:** applied (commit: abc1234)
"""

_SECOND_OPEN_ENTRY = """\
## 2026-03-12 — Issue #013, Phase 3
**Reviewer axis:** Testing
**Finding:** No property tests for parser
**Root cause:** Prompt only mentions unit tests
**Prompt change needed:** Add property testing guidance
**Status:** open
"""


class TestParseFeedbackFile(unittest.TestCase):
    """Test _parse_feedback_file helper."""

    def _write(self, tmp: Path, content: str) -> Path:
        path = tmp / "test-agent.md"
        path.write_text(content)
        return path

    def test_one_open_one_applied(self):
        """Only the open entry is returned."""
        import tempfile

        with tempfile.TemporaryDirectory() as tmp:
            path = self._write(
                Path(tmp), _HEADER + _OPEN_ENTRY + "---\n" + _APPLIED_ENTRY
            )
            result = _parse_feedback_file(path)
            self.assertEqual(len(result), 1)
            self.assertEqual(result[0]["agent"], "test-agent")
            self.assertEqual(result[0]["date"], "2026-03-13")
            self.assertEqual(result[0]["issue"], "#014")
            self.assertEqual(result[0]["phase"], "2")
            self.assertEqual(result[0]["reviewer_axis"], "Code Quality")
            self.assertEqual(result[0]["status"], "open")

    def test_header_only(self):
        """File with no entries returns empty list."""
        import tempfile

        with tempfile.TemporaryDirectory() as tmp:
            path = self._write(Path(tmp), _HEADER)
            self.assertEqual(_parse_feedback_file(path), [])

    def test_multiple_open(self):
        """All open entries are returned."""
        import tempfile

        with tempfile.TemporaryDirectory() as tmp:
            path = self._write(
                Path(tmp),
                _HEADER + _OPEN_ENTRY + "---\n" + _SECOND_OPEN_ENTRY,
            )
            result = _parse_feedback_file(path)
            self.assertEqual(len(result), 2)
            self.assertEqual(result[0]["issue"], "#014")
            self.assertEqual(result[1]["issue"], "#013")


class TestGetFeedbackSummary(unittest.TestCase):
    """Test get_feedback_summary tool."""

    def test_nonexistent_agent(self):
        """Nonexistent agent returns empty list, not an error."""
        result = get_feedback_summary(agent_name="no-such-agent-xyz")
        self.assertEqual(result, [])


# ---------------------------------------------------------------------------
# Worktree tool tests
# ---------------------------------------------------------------------------


class TestWorktreeInfo(unittest.TestCase):
    """Test _worktree_info helper returns correct path and branch."""

    def test_basic(self):
        path, branch = _worktree_info(14, "2")
        self.assertTrue(str(path).endswith(".claude/worktrees/014-phase-2"))
        self.assertEqual(branch, "worktree/014-phase-2")

    def test_alphanumeric_phase(self):
        path, branch = _worktree_info(7, "2a")
        self.assertTrue(str(path).endswith(".claude/worktrees/007-phase-2a"))
        self.assertEqual(branch, "worktree/007-phase-2a")

    def test_large_issue_number(self):
        path, branch = _worktree_info(123, "1")
        self.assertTrue(str(path).endswith(".claude/worktrees/123-phase-1"))
        self.assertEqual(branch, "worktree/123-phase-1")


class TestCreateWorktree(unittest.TestCase):
    """Test create_worktree tool."""

    @patch("project_tools.Path.exists", return_value=True)
    def test_already_exists(self, _mock_exists: MagicMock):
        result = create_worktree(14, "2")
        self.assertIn("error", result)
        self.assertIn("already exists", result["error"])

    @patch("project_tools.subprocess.run")
    @patch("project_tools.Path.mkdir")
    @patch("project_tools.Path.exists", return_value=False)
    def test_success(
        self,
        _mock_exists: MagicMock,
        _mock_mkdir: MagicMock,
        mock_run: MagicMock,
    ):
        mock_run.return_value = MagicMock(returncode=0, stdout="", stderr="")
        result = create_worktree(14, "2")
        self.assertIn("path", result)
        self.assertIn("branch", result)
        self.assertEqual(result["branch"], "worktree/014-phase-2")
        self.assertTrue(result["path"].endswith("014-phase-2"))

    @patch("project_tools.subprocess.run")
    @patch("project_tools.Path.mkdir")
    @patch("project_tools.Path.exists", return_value=False)
    def test_git_failure(
        self,
        _mock_exists: MagicMock,
        _mock_mkdir: MagicMock,
        mock_run: MagicMock,
    ):
        mock_run.return_value = MagicMock(
            returncode=128, stdout="", stderr="fatal: branch already exists"
        )
        result = create_worktree(14, "2")
        self.assertIn("error", result)
        self.assertIn("branch already exists", result["error"])


class TestRemoveWorktree(unittest.TestCase):
    """Test remove_worktree tool."""

    @patch("project_tools.Path.exists", return_value=False)
    def test_no_worktree(self, _mock_exists: MagicMock):
        result = remove_worktree(14, "2")
        self.assertIn("error", result)
        self.assertIn("No worktree at", result["error"])

    @patch("project_tools.subprocess.run")
    @patch("project_tools.Path.exists", return_value=True)
    def test_success(self, _mock_exists: MagicMock, mock_run: MagicMock):
        mock_run.return_value = MagicMock(returncode=0, stdout="", stderr="")
        result = remove_worktree(14, "2")
        self.assertTrue(result["ok"])
        self.assertTrue(result["removed_path"].endswith("014-phase-2"))
        self.assertEqual(result["removed_branch"], "worktree/014-phase-2")
        self.assertEqual(mock_run.call_count, 2)

    @patch("project_tools.subprocess.run")
    @patch("project_tools.Path.exists", return_value=True)
    def test_git_remove_failure(self, _mock_exists: MagicMock, mock_run: MagicMock):
        mock_run.return_value = MagicMock(
            returncode=1, stdout="", stderr="fatal: not a worktree"
        )
        result = remove_worktree(14, "2")
        self.assertIn("error", result)
        self.assertIn("not a worktree", result["error"])


# ---------------------------------------------------------------------------
# DoD templates tests
# ---------------------------------------------------------------------------


class TestDoDTemplates(unittest.TestCase):
    """Test DOD_TEMPLATES covers all required domains."""

    def test_required_domains_present(self):
        required = {"elixir", "elm", "rust", "python", "platform", "database"}
        self.assertTrue(required.issubset(set(DOD_TEMPLATES.keys())))

    def test_each_domain_has_items(self):
        for domain, items in DOD_TEMPLATES.items():
            with self.subTest(domain=domain):
                self.assertIsInstance(items, list)
                self.assertGreater(len(items), 0)


class TestDomainAgents(unittest.TestCase):
    """Test DOMAIN_AGENTS mapping."""

    def test_expected_mappings(self):
        expected = {
            "elixir": "elixir-agent",
            "elm": "elm-agent",
            "rust": "rust-agent",
            "python": "python-agent",
            "platform": "platform-agent",
            "database": "database-agent",
            "protobuf": "protobuf-agent",
            "partner": "partner-agent",
            "security": "security-agent",
        }
        self.assertEqual(DOMAIN_AGENTS, expected)


# ---------------------------------------------------------------------------
# draft_issue tests
# ---------------------------------------------------------------------------


class TestDraftIssueSingleDomain(unittest.TestCase):
    """Test draft_issue with a single domain."""

    @patch("project_tools.list_issues", return_value=[])
    def test_single_domain_dod(self, _mock_list: MagicMock):
        result = draft_issue(
            title="Add book search",
            roadmap_context="Implement full-text book search.",
            domains=["elixir"],
        )
        self.assertEqual(result["title"], "Add book search")
        self.assertEqual(result["summary"], "Implement full-text book search.")
        self.assertEqual(result["dod_items"], DOD_TEMPLATES["elixir"])
        self.assertIn("elixir-agent", result["agent_assignment"])
        self.assertEqual(result["goal"], "[To be refined by human]")


class TestDraftIssueMultipleDomains(unittest.TestCase):
    """Test draft_issue with multiple domains combines DoD items."""

    @patch("project_tools.list_issues", return_value=[])
    def test_combined_dod(self, _mock_list: MagicMock):
        result = draft_issue(
            title="Full stack feature",
            roadmap_context="Spans elixir and elm.",
            domains=["elixir", "elm"],
        )
        # Should have all elixir items + all elm items (no overlap).
        expected = DOD_TEMPLATES["elixir"] + DOD_TEMPLATES["elm"]
        self.assertEqual(result["dod_items"], expected)

    @patch("project_tools.list_issues", return_value=[])
    def test_deduplication(self, _mock_list: MagicMock):
        # Both elixir and database share "mix test" related items but with
        # different text, so all should appear. Passing same domain twice
        # should deduplicate.
        result = draft_issue(
            title="Test dedup",
            roadmap_context="Dedup test.",
            domains=["elixir", "elixir"],
        )
        self.assertEqual(result["dod_items"], DOD_TEMPLATES["elixir"])


class TestDraftIssueUnknownDomain(unittest.TestCase):
    """Test draft_issue with unknown domain doesn't error."""

    @patch("project_tools.list_issues", return_value=[])
    def test_unknown_domain_skipped(self, _mock_list: MagicMock):
        result = draft_issue(
            title="Mystery domain",
            roadmap_context="Uses an unknown domain.",
            domains=["cobol"],
        )
        self.assertEqual(result["dod_items"], [])
        self.assertEqual(result["agent_assignment"], "")
        self.assertEqual(result["dependencies"], "None.")

    @patch("project_tools.list_issues", return_value=[])
    def test_mixed_known_unknown(self, _mock_list: MagicMock):
        result = draft_issue(
            title="Mixed",
            roadmap_context="Mix of known and unknown.",
            domains=["cobol", "rust"],
        )
        self.assertEqual(result["dod_items"], DOD_TEMPLATES["rust"])
        self.assertIn("rust-agent", result["agent_assignment"])


class TestDraftIssueDependencyDetection(unittest.TestCase):
    """Test dependency detection finds issues with matching domains."""

    @patch("project_tools._find_issue_file", return_value=None)
    @patch(
        "project_tools.list_issues",
        return_value=[
            {"number": 5, "title": "Elixir context refactor", "status": "open"},
            {"number": 6, "title": "Add new partner API", "status": "open"},
            {"number": 7, "title": "Fix CSS bug", "status": "open"},
        ],
    )
    def test_domain_keyword_match(self, _mock_list: MagicMock, _mock_find: MagicMock):
        result = draft_issue(
            title="Elixir feature",
            roadmap_context="New elixir work.",
            domains=["elixir"],
        )
        # Issue #5 has "Elixir" in the title, should be suggested.
        self.assertEqual(len(result["suggested_dependencies"]), 1)
        self.assertEqual(result["suggested_dependencies"][0]["issue"], 5)
        self.assertIn("domain: elixir", result["suggested_dependencies"][0]["reason"])


class TestDraftIssueAgentFormatting(unittest.TestCase):
    """Test agent assignment formatting."""

    @patch("project_tools.list_issues", return_value=[])
    def test_agent_formatting(self, _mock_list: MagicMock):
        result = draft_issue(
            title="Multi-agent",
            roadmap_context="Multiple agents needed.",
            domains=["elixir", "elm"],
        )
        lines = result["agent_assignment"].split("\n")
        self.assertEqual(len(lines), 2)
        self.assertIn("**elixir-agent**", lines[0])
        self.assertIn("**elm-agent**", lines[1])


if __name__ == "__main__":
    unittest.main()
