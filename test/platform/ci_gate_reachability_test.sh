#!/usr/bin/env bash
# test/platform/ci_gate_reachability_test.sh
#
# `gate-pre-push-report` decides whether 22 jobs run. These cases are about the
# two ways that decision went wrong.
#
# ⛔ MEASURED, NOT HYPOTHETICAL. Run 39308930602 — a dependabot bump of pinned
# action SHAs — had `gate-pre-push-report: success`, `changes: skipped`, all 22
# dependent jobs `skipped`, and a run conclusion of **"success"**. So an entire
# PR category received ZERO CI jobs and reported green.
#
# Two separate defects produced that, and fixing either alone is not enough:
#
#   1. The gate reads a `ci-summary` sentinel from the PR description, which the
#      local pre-push hook writes. Dependabot authors its own body and has no
#      such block, so the gate could NEVER pass for it — a standing condition
#      for a whole category rather than an occasional slip. Fixing only (2)
#      would turn those PRs from silently green to loudly red with still no CI.
#   2. The gate exited 0 whether or not it was satisfied, publishing the verdict
#      as an OUTPUT. Twenty-two grey skips say nothing on a PR page. Fixing only
#      (1) would leave every other un-sentinelled PR silently untested.
#
# ⚠️ The change class makes (1) the expensive one to lose: dependabot's job here
# is bumping pinned action SHAs, which is exactly what silently breaks a
# workflow — and the lane that would notice was the skipped one. First execution
# was post-merge, with the breakage already on the default branch.
#
# ⛔ THE GATE'S OWN SCRIPT IS EXTRACTED AND EXECUTED, not asserted about. A test
# that greps the YAML for `exit 1` proves the characters are present and nothing
# about what the script does with a given PR body. This repository has the rule
# written down from a differential test that compared two things it had both
# written; the fix is to run the real implementation.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib/assert.sh
source "$HERE/lib/assert.sh"

CI_YML="$REPO_ROOT/.github/workflows/ci.yml"

test_case "inputs_exist" "the workflow is present"
assert_path_exists "$CI_YML" ".github/workflows/ci.yml exists"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ── Extract the gate step's script, and refuse if the shape moved ───────────
python3 - "$CI_YML" "$WORK/gate.sh" <<'EXTRACT'
import sys

import yaml

ci_yml, out = sys.argv[1], sys.argv[2]
doc = yaml.safe_load(open(ci_yml, encoding="utf-8"))
job = doc["jobs"]["gate-pre-push-report"]
steps = [s for s in job["steps"] if "run" in s]
assert len(steps) == 1, f"expected one run step, found {len(steps)}"
script = steps[0]["run"]
# If the sentinel handling moved out of this step, every case below would be
# testing an empty script and passing.
assert "ci-summary" in script, "the gate step no longer mentions the sentinel"
assert "proceed" in script, "the gate step no longer computes `proceed`"
open(out, "w", encoding="utf-8").write(script)
print(f"extracted {len(script.splitlines())} lines")
EXTRACT

test_case "the_gate_script_was_extracted" "these cases run the real implementation, not a copy"
assert_path_exists "$WORK/gate.sh" "the gate's run block was written out"
if [[ -s "$WORK/gate.sh" ]]; then
    _record_pass "and it is non-empty, so the cases below are not driving nothing"
else
    _record_fail "the extracted script is EMPTY — every case below would pass vacuously"
fi

# `gh pr view --json body --jq .body` is the gate's only input. Stubbed to emit
# whatever body a case wants.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
cat "$STUB_PR_BODY"
STUB
chmod +x "$WORK/bin/gh"

run_gate_with_body() {
    printf '%s' "$1" > "$WORK/body.txt"
    : > "$WORK/github_output"
    OUT="$(
        STUB_PR_BODY="$WORK/body.txt" \
        PATH="$WORK/bin:$PATH" \
        GH_TOKEN=stub PR_NUMBER=1 GH_REPO=o/r \
        GITHUB_OUTPUT="$WORK/github_output" \
            bash "$WORK/gate.sh" 2>&1
    )"
    RC=$?
    PROCEED="$(sed -n 's/^proceed=//p' "$WORK/github_output")"
}

GREEN_BODY='## Summary
<!-- ci-summary-start -->
| gate | result |
|---|---|
| format | ✅ |
| tests | ✅ |
<!-- ci-summary-end -->'

RED_BODY='## Summary
<!-- ci-summary-start -->
| gate | result |
|---|---|
| format | ✅ |
| tests | ❌ |
<!-- ci-summary-end -->'

# A dependabot-shaped body: no sentinel block at all.
BOT_BODY='Bumps actions/checkout from 4.1.1 to 7.0.1.

Release notes
...'

# ── a green sentinel proceeds ───────────────────────────────────────────────
test_case "a_green_sentinel_proceeds" "the gate must still let a normal PR through"
run_gate_with_body "$GREEN_BODY"
assert_exit_zero "$RC" "a fully green ci-summary block exits 0"
if [[ "$PROCEED" == "true" ]]; then
    _record_pass "and publishes proceed=true"
else
    _record_fail "proceed was '${PROCEED}', so no job would run on a green PR: ${OUT}"
fi

# ── an un-green sentinel FAILS rather than succeeding quietly ──────────────
#
# ⛔ This is defect (2). The gate used to exit 0 here and publish
# proceed=false, which rendered as 22 grey skips and a green run.
test_case "a_red_sentinel_fails_the_gate" \
    "'CI did not run' and 'CI ran and was fine' must not render identically"
run_gate_with_body "$RED_BODY"
assert_exit_nonzero "$RC" "a ci-summary block with a ❌ fails the gate"
assert_contains "$OUT" "CI did not run" "and says so in a title a PR page surfaces"
assert_contains "$OUT" "NOT a passing CI run" "leaving no room to read the skip as a pass"
if [[ "$PROCEED" == "false" ]]; then
    _record_pass "while still publishing proceed=false, so downstream conditions are unchanged"
else
    _record_fail "proceed was '${PROCEED}'; the output must be set BEFORE the failure exit"
fi

test_case "a_missing_sentinel_fails_the_gate" "an absent block is not a green one"
run_gate_with_body "$BOT_BODY"
assert_exit_nonzero "$RC" "a body with no ci-summary block fails the gate"
assert_contains "$OUT" "missing, empty, or not green" "naming all three ways it can be unsatisfied"

# ── the behaviour that must NOT have changed ────────────────────────────────
#
# ⚠️ The point of the sentinel is that CI does not run without a green pre-push
# report. This change makes the skip LOUD; it must not make it permissive.
test_case "an_un_green_sentinel_still_does_not_run_ci" \
    "making the skip loud must not make it permissive"
if [[ "$PROCEED" != "true" ]]; then
    _record_pass "proceed is not true, so the dependent jobs' conditions still hold them back"
else
    _record_fail "an un-sentinelled PR now proceeds — the gate was loosened, not clarified"
fi

# ── bot actors are admitted so their PRs get the full suite ────────────────
#
# ⛔ Defect (1), and it is a property of the job's `if:` rather than of the
# script above — a bot can never satisfy the script, so it must not reach it.
test_case "bot_actors_do_not_reach_this_gate" \
    "a category that cannot satisfy the gate must not be gated by it"
python3 - "$CI_YML" <<'CONDITIONS'
import sys

import yaml

doc = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
gate_if = " ".join(doc["jobs"]["gate-pre-push-report"]["if"].split())
changes_if = " ".join(doc["jobs"]["changes"]["if"].split())

failures = []
if "dependabot[bot]" not in gate_if:
    failures.append(
        "the gate's `if:` does not exclude dependabot, so its PRs reach a check they "
        "cannot pass and every dependent job skips"
    )
# The admission path: a skipped gate must let `changes` run, or exempting the
# bot would trade a silent skip for a different silent skip.
if "result == 'skipped'" not in changes_if:
    failures.append(
        "`changes` no longer admits a SKIPPED gate, so exempting the bot would stop "
        "its jobs running rather than start them"
    )
# And the gated path must still require the output, or the gate is decorative.
if "proceed == 'true'" not in changes_if:
    failures.append("`changes` no longer requires proceed == 'true'; the gate is decorative")

for f in failures:
    print(f"FAIL: {f}")
raise SystemExit(1 if failures else 0)
CONDITIONS
if [[ $? -eq 0 ]]; then
    _record_pass "the gate excludes bot actors, and a skipped gate still admits the pipeline"
else
    _record_fail "the admission path is broken — see the FAIL lines above"
fi

# ── the blast radius is stated, so a future reader knows the cost ──────────
test_case "the_dependent_job_count_is_known" \
    "the cost of this gate failing open is 22 jobs, and that number should be visible"
DEPENDENT="$(grep -cE '^\s+needs: \[?changes' "$CI_YML" || true)"
if [[ "$DEPENDENT" -ge 15 ]]; then
    _record_pass "${DEPENDENT} job(s) depend on \`changes\`, which is what this gate decides"
else
    _record_fail "only ${DEPENDENT} job(s) depend on \`changes\` — either the pipeline was restructured or this count's pattern stopped matching"
fi

summarise
