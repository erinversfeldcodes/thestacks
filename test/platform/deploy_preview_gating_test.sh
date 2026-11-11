#!/usr/bin/env bash
# test/platform/deploy_preview_gating_test.sh
#
# The preview stack is what the IDOR gate and the deployed E2E run against, so a
# preview built from code whose tests have not passed makes those runs mean less
# than they appear to.
#
# `deploy-preview` carried `needs: [versions, changes]` with the real dependency
# list commented out behind a "restore after deploy-preview is stable" TODO. The
# gate ran against a stack built without the Elixir, Elm, Rust, Python, proto or
# dbt suites having passed, and nothing said so.
#
# ⚠️ This suite pins BOTH halves, because fixing one without the other is worse
# than the original:
#
#   - the correctness suites really are dependencies, AND
#   - the `if:` overrides the implicit `success()`.
#
# The second is the trap. Every correctness job is itself gated on a
# paths-filter, and in GitHub Actions a SKIPPED dependency skips the dependent
# job. So restoring the `needs:` list on its own would have skipped
# `deploy-preview` on nearly every PR — silently, since a skipped job is not a
# failure. `!cancelled()` is what lets it run past an irrelevant skip, and
# `!contains(needs.*.result, 'failure')` is what actually blocks.
#
# Parsed with PyYAML rather than grepped: the job carries a long comment that
# quotes both the old `needs:` line and the scanner names, so a textual search
# reads the prose as configuration. An earlier check of this change did exactly
# that and reported 150 non-existent jobs.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib/assert.sh
source "$HERE/lib/assert.sh"

CI_YML="$REPO_ROOT/.github/workflows/ci.yml"

test_case "inputs_exist" "the workflow is present"
assert_path_exists "$CI_YML" ".github/workflows/ci.yml exists"

if ! python3 -c "import yaml" 2>/dev/null; then
    echo "# SKIP: PyYAML not available — this suite asserts nothing without it"
    summarise
    exit 0
fi

# One python call emits every fact the cases below assert on, as `key=value`,
# so the YAML is parsed once and the assertions stay readable.
FACTS="$(python3 - "$CI_YML" <<'PY'
import sys

import yaml

doc = yaml.safe_load(open(sys.argv[1]).read())
jobs = doc["jobs"]
dp = jobs.get("deploy-preview", {})
needs = dp.get("needs") or []
if isinstance(needs, str):
    needs = [needs]
cond = dp.get("if", "") or ""

print(f"needs={','.join(needs)}")
print(f"unknown_needs={','.join(n for n in needs if n not in jobs)}")
print(f"has_not_cancelled={'!cancelled()' in cond}")
print(f"has_failure_guard={'contains(needs.*.result,' in cond.replace(' ', '')}")
print(f"todo_restored={'TODO: restore full dependency list' in open(sys.argv[1]).read()}")
PY
)"

fact() { printf '%s\n' "$FACTS" | grep "^$1=" | cut -d= -f2-; }

NEEDS="$(fact needs)"
UNKNOWN="$(fact unknown_needs)"

test_case "correctness_suites_are_dependencies" "the preview waits for the suites that make it meaningful"
for job in test-elixir test-elm test-rust test-python lint-proto test-dbt; do
    assert_contains "$NEEDS" "$job" \
        "deploy-preview must depend on $job — the IDOR gate and deployed E2E run against this stack"
done

test_case "needs_are_real_jobs" "every dependency names a job that exists"
if [[ -z "$UNKNOWN" ]]; then
    _record_pass "all of deploy-preview's needs resolve to real jobs"
else
    _record_fail "deploy-preview needs jobs that do not exist: $UNKNOWN"
fi

# ⛔ The trap. Without these two clauses the job inherits the implicit
# `success()`, and a dependency skipped by its own paths-filter skips the deploy.
test_case "skip_does_not_disable_the_deploy" "an irrelevant skipped suite does not skip the deploy"
if [[ "$(fact has_not_cancelled)" == "True" ]]; then
    _record_pass "the if: carries !cancelled(), so a skipped dependency does not skip the deploy"
else
    _record_fail "the if: lacks !cancelled() — every correctness job is paths-filtered, so with the implicit success() this deploy is skipped on nearly every PR"
fi

test_case "a_real_failure_still_blocks" "a failing suite blocks the preview"
if [[ "$(fact has_failure_guard)" == "True" ]]; then
    _record_pass "the if: carries !contains(needs.*.result, 'failure')"
else
    _record_fail "the if: lacks the failure guard — with !cancelled() alone the deploy runs even when a suite FAILED, which is worse than the original"
fi

test_case "the_todo_is_gone" "the disabled-dependency TODO has not come back"
if [[ "$(fact todo_restored)" == "False" ]]; then
    _record_pass "no 'restore full dependency list' TODO remains"
else
    _record_fail "the 'TODO: restore full dependency list' comment is back — the dependencies were disabled again"
fi

# Stated as an assertion so the scope is a decision on the record rather than an
# omission someone later "completes". These gate the merge, not an ephemeral
# preview; blocking a preview on a licence scan adds latency without making its
# E2E results more trustworthy.
test_case "scanners_gate_the_merge_not_the_preview" "supply-chain scanners are deliberately not preview dependencies"
for scanner in check-licenses gitleaks semgrep checkov trivy trufflehog syft-grype dockle; do
    assert_not_contains "$NEEDS" "$scanner" \
        "$scanner gates the merge, not the preview — if that changes, change it for a reason about previews"
done

summarise
