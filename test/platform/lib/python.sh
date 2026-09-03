#!/usr/bin/env bash
# Find a Python that can do the one thing a suite needs.
#
# Three suites carried a near-identical copy of this: two line-for-line the same
# but for the fallback venv's name, and a third differing only in what it probes
# for. A change to the candidate list — a new venv location, a different
# ordering — had to be made in three places or the suites quietly disagreed
# about which interpreter they were testing under.
#
#   pick_python <probe> <venv-name> [pip-package] [extra-candidate...]
#
#     probe        Python source that must run cleanly, e.g. "import yaml"
#     venv-name    directory name under TMPDIR for the built fallback
#     pip-package  installed into the fallback when the probe needs it
#
# Prints the interpreter path and returns 0, or returns 1 if none can be found
# or built. Callers treat a non-zero return as "cannot run these cases" and say
# so, rather than skipping silently.
pick_python() {
    local probe="$1"
    local venv_name="$2"
    local pip_package="${3:-}"
    shift 3 2>/dev/null || shift $#

    local candidates=(
        "$REPO_ROOT/.venv-tools/bin/python3"
        "$REPO_ROOT/scripts/mcp/.venv/bin/python3"
        "$@"
        "python3"
    )

    local cand
    for cand in "${candidates[@]}"; do
        [[ -n "$cand" ]] || continue
        if command -v "$cand" >/dev/null 2>&1 \
            && "$cand" -c "$probe" >/dev/null 2>&1; then
            echo "$cand"
            return 0
        fi
    done

    # Nothing on hand can do it — build a throwaway venv and install what the
    # probe needs. Kept per-suite by name so two suites running concurrently do
    # not race on the same directory.
    local fallback_venv="${TMPDIR:-/tmp}/${venv_name}"
    if [[ ! -x "$fallback_venv/bin/python3" ]] \
        || ! "$fallback_venv/bin/python3" -c "$probe" >/dev/null 2>&1; then
        python3 -m venv "$fallback_venv" >/dev/null 2>&1 || return 1
        if [[ -n "$pip_package" ]]; then
            "$fallback_venv/bin/pip" install --quiet "$pip_package" >/dev/null 2>&1 || return 1
        fi
        "$fallback_venv/bin/python3" -c "$probe" >/dev/null 2>&1 || return 1
    fi

    echo "$fallback_venv/bin/python3"
    return 0
}
