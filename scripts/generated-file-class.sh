#!/usr/bin/env bash
# scripts/generated-file-class.sh — classify a generated artefact by its git
# status, so a drift check can tell a real defect from local staleness.
#
# WHY THIS EXISTS (Issue #354)
# ----------------------------
# Drift in a GITIGNORED generated file can only ever be local staleness. CI
# generates those artefacts from scratch on every run, so there is nothing there
# that *can* be stale, and nothing that could have been committed wrong. The
# correct response is to regenerate them and carry on.
#
# Drift in a TRACKED generated file is the thing the drift check exists for: a
# committed artefact that has diverged from its `.proto` source. That must fail
# the build, and this script must never make that case quieter.
#
# Conflating the two cost two full `just ci` re-runs (Waves 4 and 5). Wave 5's
# gate reported three failing groups — `elixir: test`, `python: test` and
# `proto: lint` — which were one cause and zero real defects. A gate that cries
# wolf on a clean tree trains people to re-run it and move on, which is exactly
# how a real drift would get waved through.
#
# WHY GIT, NOT .gitignore
# -----------------------
# The project convention is to answer "is this tracked?" with git itself, never
# by reading `.gitignore` — a hand-rolled matcher gets negations, directory
# rules and precedence wrong, and does it silently.
#
# Order matters: `git check-ignore` is a pure pattern match and will report a
# TRACKED file as ignored if some pattern happens to cover it. So tracked is
# asked first and wins.
#
# USAGE
#   scripts/generated-file-class.sh <path>
#
# Prints exactly one word on stdout:
#   tracked    — in the index; drift here MUST fail the build
#   ignored    — gitignored; drift here is local staleness, safe to regenerate
#   untracked  — neither, or git cannot answer; NOT proven disposable, so
#                callers must treat it exactly like `tracked` and fail
#
# The path need not exist: `check-ignore` is a pattern match, not a stat, so a
# generated file that is missing entirely classifies correctly too.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ $# -ne 1 || -z "${1:-}" ]]; then
    echo "usage: scripts/generated-file-class.sh <path>" >&2
    exit 2
fi

TARGET="$1"

if git -C "$REPO_ROOT" ls-files --error-unmatch -- "$TARGET" >/dev/null 2>&1; then
    echo tracked
elif git -C "$REPO_ROOT" check-ignore -q -- "$TARGET" 2>/dev/null; then
    echo ignored
else
    # Untracked and un-ignored, or git failed (no repo, path outside the tree).
    # Fail closed: an artefact we cannot prove is disposable is treated as one
    # that must be committed, so its drift still fails the build.
    echo untracked
fi
