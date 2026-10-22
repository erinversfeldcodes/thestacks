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

# ⚠️ PyYAML resolves the bare key `on` to BOOLEAN TRUE, because YAML 1.1 treats
# `on`/`off`/`yes`/`no` as booleans. So `doc["on"]` raises `KeyError` on every
# GitHub workflow file, and `doc.get("on", {})` silently returns the default —
# which is the dangerous one, because a sweep for triggers would then report
# every workflow as having none.
#
# ⛔ SWEPT BEFORE ADDING THIS: zero live instances. Five files parse YAML here,
# four of them workflow files, and none reads the `on` key today — so the
# reviewer's recommendation was a HELPER rather than a gate, applying their own
# base-rate rule to itself: a gate over zero instances is unfalsifiable from
# birth, while a helper placed before it is needed costs nothing.
#
# ⚠️ It is one line from mattering: `deploy_production_workflow_test.sh:327`
# already `safe_load`s a workflow and would hit this the first time it asks what
# triggers it.
#
# Emit this into an embedded python block that needs workflow triggers:
#
#     eval "$(workflow_triggers_py)"
#     trig = workflow_triggers(yaml.safe_load(open(path)))
workflow_triggers_py() {
    cat <<'PYHELPER'
def workflow_triggers(doc):
    """A workflow's `on:` mapping, surviving YAML 1.1's boolean coercion."""
    return doc.get("on", doc.get(True, {})) or {}
PYHELPER
}
