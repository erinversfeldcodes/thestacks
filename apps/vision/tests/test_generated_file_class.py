"""The proto drift check must split local staleness from real drift
(354): a GITIGNORED generated artefact can only be locally stale (CI
regenerates from scratch) and must be regenerated-and-passed, while a
TRACKED artefact diverging from its .proto is the real defect and must
still fail. Wave 4/5 burned two full `just ci` re-runs on the former
being treated as the latter.
"""

import os
import subprocess
import sys
from collections.abc import Iterator
from contextlib import contextmanager
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO_ROOT / "scripts"))

from gen_python_proto import _resolve_drift, classify  # noqa: E402

CLASSIFIER = REPO_ROOT / "scripts" / "generated-file-class.sh"

IGNORED_PROBE = REPO_ROOT / f"apps/core/lib/stacks/gen/proto/drift_probe_{os.getpid()}.ex"
TRACKED_PROBE = REPO_ROOT / f"drift_probe_tracked_{os.getpid()}.tmp"


def _classify_via_shell(path: Path) -> str:
    result = subprocess.run(
        [str(CLASSIFIER), str(path)], capture_output=True, text=True, check=True
    )
    return result.stdout.strip()


@contextmanager
def temporarily_tracked(path: Path, content: str) -> Iterator[Path]:
    """Force a throwaway file into the index, then take it back out.

    The tracked-file assertion is "the implementation must NOT write here" — so
    a broken implementation writes there anyway. Pointing it at a real repo file
    means the failing test corrupts the working tree: an earlier draft of this
    test aimed at `justfile` and a mutation probe duly overwrote it with
    "deliberately wrong". The file under test has to be disposable.
    """
    path.write_text(content)
    subprocess.run(["git", "-C", str(REPO_ROOT), "add", "-f", "--", str(path)], check=True)
    try:
        yield path
    finally:
        subprocess.run(
            ["git", "-C", str(REPO_ROOT), "rm", "--cached", "-f", "--quiet", "--", str(path)],
            check=False,
            capture_output=True,
        )
        path.unlink(missing_ok=True)


class TestClassifier:
    def test_gitignored_generated_file_is_ignored(self) -> None:
        assert (
            _classify_via_shell(REPO_ROOT / "apps/core/lib/stacks/gen/proto/enums.ex") == "ignored"
        )

    def test_committed_file_is_tracked(self) -> None:
        assert _classify_via_shell(REPO_ROOT / "justfile") == "tracked"

    def test_a_file_forced_into_the_index_reads_as_tracked(self) -> None:
        """Even one .gitignore covers: git's answer is the index, not the pattern."""
        assert _classify_via_shell(TRACKED_PROBE) == "untracked"

        with temporarily_tracked(TRACKED_PROBE, "probe\n"):
            assert _classify_via_shell(TRACKED_PROBE) == "tracked"

        assert _classify_via_shell(TRACKED_PROBE) == "untracked"

    def test_missing_gitignored_path_still_classifies(self) -> None:
        """check-ignore is a pattern match, not a stat — a fresh clone has no file yet."""
        assert (
            _classify_via_shell(REPO_ROOT / "apps/core/lib/stacks/gen/proto/never.ex") == "ignored"
        )

    def test_path_outside_the_repo_fails_closed(self) -> None:
        """Un-classifiable is not the same as disposable."""
        assert _classify_via_shell(Path("/tmp/definitely-not-in-this-repo.txt")) == "untracked"

    def test_python_wrapper_agrees_with_the_shell(self) -> None:
        """One policy, one implementation — the wrapper must not drift from it."""
        for path in (
            REPO_ROOT / "justfile",
            REPO_ROOT / "apps/core/lib/stacks/gen/proto/enums.ex",
        ):
            assert classify(path) == _classify_via_shell(path)


class TestResolveDrift:
    def test_stale_gitignored_artefact_is_regenerated_not_failed(self) -> None:
        # gen/ is gitignored, so a fresh CI checkout has no such directory
        IGNORED_PROBE.parent.mkdir(parents=True, exist_ok=True)
        IGNORED_PROBE.write_text("# stale\n")
        try:
            fails_build = _resolve_drift(IGNORED_PROBE, "# fresh\n", "elixir", missing=False)

            assert fails_build is False
            assert IGNORED_PROBE.read_text() == "# fresh\n"
        finally:
            IGNORED_PROBE.unlink(missing_ok=True)

    def test_absent_gitignored_artefact_is_generated_not_failed(self) -> None:
        IGNORED_PROBE.parent.mkdir(parents=True, exist_ok=True)
        IGNORED_PROBE.unlink(missing_ok=True)
        try:
            fails_build = _resolve_drift(IGNORED_PROBE, "# fresh\n", "elixir", missing=True)

            assert fails_build is False
            assert IGNORED_PROBE.read_text() == "# fresh\n"
        finally:
            IGNORED_PROBE.unlink(missing_ok=True)

    def test_drifted_tracked_artefact_still_fails_and_is_left_alone(self) -> None:
        """The real gate. Self-healing here would erase the evidence of the defect."""
        with temporarily_tracked(TRACKED_PROBE, "committed\n"):
            fails_build = _resolve_drift(
                TRACKED_PROBE, "deliberately wrong\n", "elixir", missing=False
            )

            assert fails_build is True
            assert TRACKED_PROBE.read_text() == "committed\n"

    def test_untracked_un_ignored_artefact_fails_closed(self) -> None:
        """Not provably disposable is not disposable."""
        TRACKED_PROBE.write_text("committed\n")
        try:
            assert _classify_via_shell(TRACKED_PROBE) == "untracked"

            fails_build = _resolve_drift(
                TRACKED_PROBE, "deliberately wrong\n", "elixir", missing=False
            )

            assert fails_build is True
            assert TRACKED_PROBE.read_text() == "committed\n"
        finally:
            TRACKED_PROBE.unlink(missing_ok=True)

    def test_message_says_which_case_it_took(self, capsys: pytest.CaptureFixture[str]) -> None:
        """A gate that cries wolf trains people to re-run it; say what happened."""
        IGNORED_PROBE.write_text("# stale\n")
        try:
            _resolve_drift(IGNORED_PROBE, "# fresh\n", "elixir", missing=False)
            regenerated = capsys.readouterr().err
        finally:
            IGNORED_PROBE.unlink(missing_ok=True)

        with temporarily_tracked(TRACKED_PROBE, "committed\n"):
            _resolve_drift(TRACKED_PROBE, "deliberately wrong\n", "elixir", missing=False)
            drifted = capsys.readouterr().err

        assert "REGENERATED" in regenerated
        assert "gitignored" in regenerated
        assert "DRIFT" not in regenerated

        assert "DRIFT" in drifted
        assert "REGENERATED" not in drifted
