#!/usr/bin/env bash
# test/platform/workflow_health_test.sh
#
# `scripts/check-workflow-health.sh`: a workflow nobody's pull request depends
# on can stay red indefinitely.
#
# ⚠️ The gap is specific. Eleven of fifteen workflows here have no
# `pull_request` trigger, so no PR ever goes red for them — including the backup
# dump, production deploy, both GDPR operator tools, and the staging reseed,
# which failed deterministically for two months and three runs before a human
# went looking.
#
# ⛔ The hard part is NOT detecting a red. It is not crying wolf. Two real cases
# in this repository would each produce a false alarm under a naive check:
#
#   * the GDPR lookup tool's last run is a failure from 2026-07-19, fixed on
#     2026-08-12 and simply not dispatched since — a STALE red, where the result
#     predates the current definition and says nothing about it;
#   * two scheduled workflows have never run because they live on an unmerged
#     branch, and schedules only fire from the default branch.
#
# A check that reported either as a failure would be switched off within a week,
# which is why both are asserted here as explicitly NOT failures.
#
# The run data is injected from fixtures, so these assertions pin the
# classification itself rather than whatever the GitHub API happens to say today.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib/assert.sh
source "$HERE/lib/assert.sh"

GATE="$REPO_ROOT/scripts/check-workflow-health.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

test_case "inputs_exist" "the gate is present and parses"
assert_path_exists "$GATE" "scripts/check-workflow-health.sh exists"
if bash -n "$GATE" 2>/dev/null; then
    _record_pass "it parses under $(bash --version | head -1)"
else
    _record_fail "it does NOT parse, so it has never run here"
fi

GATE_SRC="$(cat "$GATE" 2>/dev/null)"

# Every workflow on the default branch, so a fixture can name real files.
#
# ⚠️ A `while read` loop, not `mapfile`. `mapfile` is a bash 4 builtin and the
# system bash on this project's macOS machines is 3.2, where it is simply not
# found — and because the failure is a non-fatal "command not found", the array
# stays unset and every assertion below it would run against an empty
# population. The first draft of this file did exactly that.
WF_NAMES=()
while IFS= read -r _wf; do
    [[ -z "$_wf" ]] && continue
    WF_NAMES+=("$_wf")
done < <(
    git -C "$REPO_ROOT" ls-tree -r --name-only origin/main .github/workflows 2>/dev/null |
        sed 's|.*/||' | grep -E '\.ya?ml$' | sort
)

test_case "the_population_is_the_default_branch" "it reads workflows from origin/main"
if [[ "${#WF_NAMES[@]}" -ge 5 ]]; then
    _record_pass "origin/main holds ${#WF_NAMES[@]} workflow file(s) to classify"
else
    _record_fail "read only ${#WF_NAMES[@]} workflow(s) from origin/main — the rest of this suite would be asserting over an empty population"
fi

# A fixture reporting every workflow as a clean success.
all_green() {
    local out="$1"
    {
        echo "{"
        local first=1
        for name in "${WF_NAMES[@]}"; do
            [[ $first -eq 0 ]] && echo ","
            first=0
            printf '  "%s": {"conclusion": "success", "createdAt": "2026-10-19T00:00:00Z", "event": "schedule"}' "$name"
        done
        echo ""
        echo "}"
    } >"$out"
}

run_gate() {
    local fixture="$1"
    WORKFLOW_HEALTH_FIXTURE="$fixture" bash "$GATE" 2>&1
}

test_case "all_green_passes" "a fleet with no failures exits 0"
all_green "$WORK/green.json"
OUT="$(run_gate "$WORK/green.json")"
RC=$?
if [[ "$RC" -eq 0 ]]; then
    _record_pass "the gate passes when nothing is failing"
else
    _record_fail "the gate failed on an all-green fleet: $OUT"
fi
assert_contains "$OUT" "workflow(s) outside PR CI checked" \
    "the pass says how many workflows it actually examined"

test_case "a_live_red_fails" "a failure newer than the workflow's last edit is reported"
# `createdAt` in the future relative to any commit, so the run is unambiguously
# newer than the definition — a red nothing has superseded.
python3 - "$WORK/green.json" "$WORK/live.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
target = "backup-dump.yml" if "backup-dump.yml" in data else sorted(data)[0]
data[target] = {"conclusion": "failure", "createdAt": "2099-01-01T00:00:00Z", "event": "schedule"}
json.dump(data, open(sys.argv[2], "w"))
print(target)
PY
LIVE_TARGET="$(python3 -c "
import json;d=json.load(open('$WORK/live.json'))
print([k for k,v in d.items() if v['conclusion']=='failure'][0])
")"
OUT="$(run_gate "$WORK/live.json")"
RC=$?
if [[ "$RC" -ne 0 ]]; then
    _record_pass "a live red fails the gate (exit $RC)"
else
    _record_fail "a workflow failing with no fix since passed the gate — the one thing it exists to catch"
fi
assert_contains "$OUT" "$LIVE_TARGET" "the failure names the workflow"
assert_contains "$OUT" "failing with no fix since" "and says why that matters"

test_case "a_stale_red_does_NOT_fail" "a failure the current definition has superseded is unverified, not failing"
# ⛔ The false-alarm case, and the reason this gate is usable. The GDPR lookup
# tool really is in this state: red in July, fixed in August, not dispatched
# since. Reporting that as a live failure would be wrong, and a gate that is
# wrong once gets ignored forever.
python3 - "$WORK/green.json" "$WORK/stale.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
target = "backup-dump.yml" if "backup-dump.yml" in data else sorted(data)[0]
# Long before any commit in this repository, so the definition is certainly newer.
data[target] = {"conclusion": "failure", "createdAt": "2000-01-01T00:00:00Z", "event": "schedule"}
json.dump(data, open(sys.argv[2], "w"))
PY
OUT="$(run_gate "$WORK/stale.json")"
RC=$?
if [[ "$RC" -eq 0 ]]; then
    _record_pass "a stale red does not fail the gate"
else
    _record_fail "a red predating the workflow's own last edit failed the gate. That is the false alarm that gets a check like this switched off: output was: $OUT"
fi
assert_contains "$OUT" "UNVERIFIED" "it is still reported, loudly, as unverified"
assert_contains "$OUT" "says nothing about" "and explains why the old result proves nothing"

test_case "both_anti_vacuity_guards_are_present" "neither population can be silently empty"
# The verdict is a loop over two lists. Empty, both produce a clean pass having
# examined nothing — the shape this repository keeps finding in its own gates.
assert_contains "$GATE_SRC" "found only" "a too-small workflow population is refused"
assert_contains "$GATE_SRC" "examined nothing" "a fleet with no non-PR workflows is refused"

test_case "a_missing_cli_is_a_refusal_not_a_pass" "it says so rather than reporting success"
assert_contains "$GATE_SRC" "refusal, not a pass" "the unavailable-CLI path states it is a refusal"

test_case "pr_triggered_workflows_are_out_of_scope" "the gate covers what PR CI cannot"
assert_contains "$GATE_SRC" "pull_request" "PR-triggered workflows are identified"
assert_contains "$GATE_SRC" "already fails somebody's pull request" \
    "and skipped, with the reason stated"

test_case "never_run_is_scoped_to_scheduled_workflows" \
    "a dispatch-only operator tool is not reported for never having run"
# Otherwise every manual GDPR tool reads as broken, and two scheduled workflows
# sitting on an unmerged branch read as broken too.
assert_contains "$GATE_SRC" "has correctly never run" \
    "a dispatch-only workflow that never ran is explicitly fine"
assert_contains "$GATE_SRC" "DEFAULT BRANCH only" \
    "the gate records that schedules fire only from the default branch"

summarise
