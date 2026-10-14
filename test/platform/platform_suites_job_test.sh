#!/usr/bin/env bash
#
# Proves that PR CI actually runs the platform gates, and that it runs them when
# the files they assert on change.
#
# Two holes, both found by review rather than by any gate:
#
#   1. The `platform` paths-filter listed `test/platform/**`, `scripts/**`,
#      `deploy/**` and `.github/actions/**` — but NOT `.github/workflows/**`.
#      Four suites here assert on the workflow file itself. So reverting or
#      deleting one of those steps was a workflows-only edit, `platform` came
#      out false, the job was skipped, and the assertions written to catch
#      exactly that regression never ran. The gate worked perfectly and was
#      unreachable by the change class it guards.
#
#   2. `scripts/ci.sh`'s platform group runs THREE things; the `platform-suites`
#      job ran only the first. A gate that reddens `just ci` could therefore
#      pass every PR check — the same shape as a gate that cannot fail at all,
#      and it bit once already when a new script left `scripts/README.md` stale.
#
# The second assertion is derived from `scripts/ci.sh`, not from a list written
# here, so adding a fourth script to that group without adding it to the
# workflow reddens this suite rather than quietly widening the gap again.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib/assert.sh
source "$HERE/lib/assert.sh"

CI_YML="$REPO_ROOT/.github/workflows/ci.yml"
CI_SH="$REPO_ROOT/scripts/ci.sh"

test_case "inputs_exist" "the workflow and the local gate runner are both present"
assert_path_exists "$CI_YML" ".github/workflows/ci.yml exists"
assert_path_exists "$CI_SH" "scripts/ci.sh exists"

# The `platform:` list inside the paths-filter block. A flag rather than an
# awk range: the terminating pattern (a sibling filter key) and the opening one
# are both `^            <word>:`, so a range would close on the opening line.
platform_filter() {
    awk '
        /^            platform:$/ { in_block = 1; next }
        in_block && /^            [a-z_]+:$/ { exit }
        in_block { print }
    ' "$CI_YML"
}

# The `platform-suites:` job body, stopping at the next top-level job key.
platform_job() {
    awk '
        /^  platform-suites:$/ { in_job = 1; next }
        in_job && /^  [a-z][a-z0-9_-]*:$/ { exit }
        in_job { print }
    ' "$CI_YML"
}

# Every `bash <script>` the platform group of scripts/ci.sh invokes.
platform_group_scripts() {
    awk '
        /^if has_group platform; then$/ { in_block = 1; next }
        in_block && /^fi$/ { exit }
        in_block { print }
    ' "$CI_SH" |
        grep -oE 'bash [a-zA-Z0-9_./-]+' |
        awk '{ print $2 }' |
        sort -u
}

FILTER_TXT="$(platform_filter)"
JOB_TXT="$(platform_job)"

test_case "filter_block_found" "the platform paths-filter block is readable"
if [[ -z "$FILTER_TXT" ]]; then
    _record_fail "the 'platform:' paths-filter block is gone from ci.yml, or was renamed"
else
    assert_contains "$FILTER_TXT" "test/platform/**" "the filter still covers the suites themselves"
fi

test_case "filter_watches_workflows" "a workflows-only edit still triggers the platform job"
if [[ -z "$FILTER_TXT" ]]; then
    _record_fail "no platform filter block to check"
else
    assert_contains "$FILTER_TXT" ".github/workflows/**" \
        "four suites assert on the workflow file; without this path a revert of the step they guard skips them"
fi

test_case "job_block_found" "the platform-suites job is readable"
if [[ -z "$JOB_TXT" ]]; then
    _record_fail "the 'platform-suites' job is gone from ci.yml, or was renamed"
else
    assert_contains "$JOB_TXT" "needs.changes.outputs.platform" "the job is still gated on the platform filter"
fi

test_case "job_runs_every_local_gate" "PR CI runs every script the local platform group runs"
GROUP_SCRIPTS="$(platform_group_scripts)"
if [[ -z "$GROUP_SCRIPTS" ]]; then
    _record_fail "could not read any 'bash <script>' from scripts/ci.sh's platform group"
elif [[ -z "$JOB_TXT" ]]; then
    _record_fail "no platform-suites job body to check"
else
    while IFS= read -r script; do
        [[ -z "$script" ]] && continue
        assert_contains "$JOB_TXT" "$script" \
            "scripts/ci.sh runs $script in its platform group, so PR CI must too"
    done <<<"$GROUP_SCRIPTS"
fi

# The `elm:` paths-filter block, same flag-not-range reason as above.
elm_filter() {
    awk '
        /^            elm:$/ { in_block = 1; next }
        in_block && /^            [a-z_]+:$/ { exit }
        in_block { print }
    ' "$CI_YML"
}

# Every directory the ports gate READS, taken from the gate itself rather than
# written down here. The gate compares Elm port declarations against the
# JavaScript that subscribes to them, and those two live in different trees —
# so its caller has to run when EITHER changes.
ports_gate_roots() {
    grep -oE '"[a-zA-Z0-9_/]+/\*\*/\*\.(elm|js)"' "$REPO_ROOT/scripts/check-ports-wired.sh" |
        tr -d '"' |
        sed 's|/\*\*/\*\..*$||' |
        sort -u
}

test_case "ports_gate_inputs_trigger_its_lane" \
    "the lane that runs the ports gate is triggered by every tree the gate reads"
ELM_FILTER_TXT="$(elm_filter)"
GATE_ROOTS="$(ports_gate_roots)"

if [[ -z "$ELM_FILTER_TXT" ]]; then
    _record_fail "the 'elm:' paths-filter block is gone from ci.yml, or was renamed"
elif [[ -z "$GATE_ROOTS" ]]; then
    _record_fail "could not read any glob root from scripts/check-ports-wired.sh"
else
    while IFS= read -r root; do
        [[ -z "$root" ]] && continue
        # The filter covers a root if it names that root, or any ancestor of it,
        # with a recursive glob. `frontend/**` covers `frontend/src`.
        covered=0
        candidate="$root"
        while [[ -n "$candidate" && "$candidate" != "." ]]; do
            if printf '%s' "$ELM_FILTER_TXT" | grep -qF "'$candidate/**'"; then
                covered=1
                break
            fi
            candidate="$(dirname "$candidate")"
        done

        if [[ "$covered" -eq 1 ]]; then
            _record_pass "the elm filter covers $root, which the ports gate reads"
        else
            _record_fail "the ports gate reads $root but no elm filter path covers it — a change confined to that tree skips the lane that runs the gate, so the gate cannot fire on the input most likely to break it"
        fi
    done <<<"$GATE_ROOTS"
fi

summarise
exit $?
