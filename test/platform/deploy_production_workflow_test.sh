#!/usr/bin/env bash
# test/platform/deploy_production_workflow_test.sh
#
# Covers Phase 3 DoD:
#   - "`deploy-production.yml` deploys core+vision+scraper, runs gate, rolls
#      back on breach, uploads JSON artifact, prints summary"
#
# The workflow must exist at .github/workflows/deploy-production.yml with
# the structure below. Until implementation lands, the file should be absent
# entirely; this suite asserts its expected shape.
#
# Structural checks (no runtime execution of the workflow):
#   1. File exists.
#   2. Top-level trigger is `on.workflow_run` (NOT `push.main` — that's a
#      pre-merge change flagged in the issue).
#   3. workflow_run.workflows lists CI; workflow_run.types lists completed.
#   4. A job named `deploy-production` exists with a recognisable step
#      sequence: checkout → record-prev-state → deploy-stack.sh →
#      check-slo-gate.sh → conditional rollback → upload-artifact → summary.
#   5. References the expected secrets (superset of deploy-preview + METRICS_SCRAPE_TOKEN).

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib/assert.sh
source "$HERE/lib/assert.sh"

WF="$REPO_ROOT/.github/workflows/deploy-production.yml"

# ── File exists ──────────────────────────────────────────────────────────────
test_case "workflow_exists" "deploy-production.yml is present"
if [[ -f "$WF" ]]; then
    _record_pass "workflow file exists at $WF"
else
    _record_fail "workflow file not found at $WF"
    summarise
    exit $?
fi

# ── workflow_run trigger ────────────────────────────────────────────────────
test_case "workflow_run_trigger" "triggered by workflow_run on CI completion (not push.main yet)"
PARSE_OUT=$(python3 - "$WF" <<'PY' 2>&1
import re, sys

path = sys.argv[1]
with open(path) as f:
    txt = f.read()

# We avoid depending on PyYAML — the existing ci_migration_safety_job_test.sh
# deliberately uses regex for the same reason. Phase 3 keeps the convention.
findings = []

# Must contain `on:` block with `workflow_run:`
if not re.search(r"^on:\s*$", txt, re.MULTILINE):
    findings.append("no top-level `on:` block")
if not re.search(r"^\s+workflow_run:\s*$", txt, re.MULTILINE):
    findings.append("on.workflow_run not present")
# Must list the upstream workflow (CI). Accept either block list or inline.
if not re.search(r"workflows:\s*\n\s*-\s*CI\b", txt) and not re.search(r"workflows:\s*\[.*CI.*\]", txt):
    findings.append("workflow_run.workflows does not list CI")
# Must include `types:` with `completed`.
if not re.search(r"types:\s*\n\s*-\s*completed\b", txt) and not re.search(r"types:\s*\[.*completed.*\]", txt):
    findings.append("workflow_run.types does not list completed")

# Guardrail: must NOT yet be a push.main trigger — that's a pre-merge change.
if re.search(r"^on:\s*\n(?:.*\n)*?\s+push:\s*\n\s*branches:\s*\n?\s*-?\s*main\b", txt, re.MULTILINE):
    findings.append("on.push.main trigger is present — should still be workflow_run at this stage")

if findings:
    print("FINDINGS:" + "||".join(findings))
    sys.exit(1)
print("OK")
PY
)
RC=$?
assert_exit_zero "$RC" "trigger shape is workflow_run on CI.completed"
if [[ "$PARSE_OUT" == FINDINGS:* ]]; then
    for f in ${PARSE_OUT#FINDINGS:}; do
        _record_fail "trigger finding: $f"
    done
fi

# ── job structure ────────────────────────────────────────────────────────────
test_case "job_structure" "deploy-production job has the expected step sequence"
STRUCT_OUT=$(python3 - "$WF" <<'PY' 2>&1
import re, sys

path = sys.argv[1]
with open(path) as f:
    txt = f.read()

# Find `deploy-production:` as a jobs.<name>.
if not re.search(r"^\s{2,4}deploy-production:\s*$", txt, re.MULTILINE):
    print("MISSING_JOB")
    sys.exit(1)

# Isolate job body.
m = re.search(r"^(\s{2,4})deploy-production:\s*$", txt, re.MULTILINE)
indent = m.group(1)
rest = txt[m.end():]
nxt = re.search(rf"^{indent}\S", rest, re.MULTILINE)
body = rest[: nxt.start()] if nxt else rest

missing = []

# Step markers we expect — fuzzy match on recognisable strings.
markers = {
    "checkout":          r"actions/checkout@",
    "record-prev-state": r"(prev[-_]?image|CORE_PREV_IMAGE|fly image show|modal app history|record[-_]prev)",
    "deploy-stack":      r"scripts/deploy-stack\.sh",
    "check-slo-gate":    r"scripts/check-slo-gate\.sh",
    "rollback":          r"(scripts/rollback-production\.sh|rollback-production|rollback)",
    "upload-artifact":   r"actions/upload-artifact@",
    "step-summary":      r"GITHUB_STEP_SUMMARY",
}
for name, pat in markers.items():
    if not re.search(pat, body):
        missing.append(name)

# Ordering checks: deploy-stack before check-slo-gate; check-slo-gate before rollback.
def pos(pat):
    m = re.search(pat, body)
    return m.start() if m else -1

order_errs = []
p_deploy = pos(r"scripts/deploy-stack\.sh")
p_gate = pos(r"scripts/check-slo-gate\.sh")
p_roll = pos(r"(scripts/rollback-production\.sh|rollback-production|rollback)")
if p_deploy > 0 and p_gate > 0 and p_deploy > p_gate:
    order_errs.append("deploy-stack.sh must come before check-slo-gate.sh")
if p_gate > 0 and p_roll > 0 and p_gate > p_roll:
    order_errs.append("check-slo-gate.sh must come before rollback step")

if missing or order_errs:
    out = []
    if missing:
        out.append("MISSING_STEPS:" + ",".join(missing))
    if order_errs:
        out.append("ORDER_ERRORS:" + "||".join(order_errs))
    print("|".join(out))
    sys.exit(2)
print("OK")
PY
)
RC=$?
assert_exit_zero "$RC" "deploy-production job body has every required marker in order"
if [[ "$STRUCT_OUT" == MISSING_JOB* ]]; then
    _record_fail "no top-level deploy-production: job"
elif [[ "$STRUCT_OUT" == *MISSING_STEPS:* ]]; then
    _record_fail "job missing steps: ${STRUCT_OUT#*MISSING_STEPS:}"
elif [[ "$STRUCT_OUT" == *ORDER_ERRORS:* ]]; then
    _record_fail "step ordering: ${STRUCT_OUT#*ORDER_ERRORS:}"
fi

# ── secrets referenced ───────────────────────────────────────────────────────
test_case "secrets_referenced" "workflow references all required secrets (preview set + METRICS_SCRAPE_TOKEN)"
REQUIRED_SECRETS=(
    FLY_API_TOKEN
    NEON_PROJECT_ID
    NEON_API_KEY
    VISION_TOGETHER_API_KEY
    VISION_HMAC_SECRET
    SECRET_KEY_BASE
    CLOAK_KEY
    SCRAPER_HMAC_SECRET
    MODAL_TOKEN_ID
    MODAL_TOKEN_SECRET
    GUARDIAN_SECRET_KEY
    R2_ACCOUNT_ID
    R2_ACCESS_KEY_ID
    R2_SECRET_ACCESS_KEY
    METRICS_SCRAPE_TOKEN
    LOG_SHIPPER_ACCESS_TOKEN
    AXIOM_TOKEN
    AXIOM_DATASET
)
WF_CONTENT="$(cat "$WF" 2>/dev/null || echo "")"
for s in "${REQUIRED_SECRETS[@]}"; do
    if [[ "$WF_CONTENT" == *"secrets.$s"* ]]; then
        _record_pass "references secrets.$s"
    else
        _record_fail "missing secrets.$s reference"
    fi
done

# ── Reviewer P1 #1: rollback step fires on any prior failure ─────────────────
test_case "rollback_if_failure" "rollback step uses failure() — not just gate-conclusion"
ROLLBACK_BLOCK="$(python3 -c '
import re, sys
txt = open(sys.argv[1]).read()
m = re.search(r"name:\s*rollback-production\.sh[^\n]*\n(?:.*\n){0,6}?\s*if:\s*([^\n]+)", txt)
print(m.group(1) if m else "")
' "$WF")"
if [[ "$ROLLBACK_BLOCK" == *"failure()"* ]]; then
    _record_pass "rollback step if: contains failure()"
else
    _record_fail "rollback step if: does not contain failure() (got: ${ROLLBACK_BLOCK})"
fi
if [[ "$ROLLBACK_BLOCK" != *"steps.gate.conclusion == 'failure'"* ]] \
    && [[ "$ROLLBACK_BLOCK" != *'steps.gate.conclusion == "failure"'* ]]; then
    _record_pass "rollback step no longer scoped to gate-only failure"
else
    _record_fail "rollback step still scoped only to steps.gate.conclusion"
fi

# ── Reviewer P1 #5: tag-on-merge workflow exists + record-prev-state uses it ─
test_case "tag_main_workflow" "tag-main.yml exists, triggers on push.main, has contents: write"
TAG_WF="$REPO_ROOT/.github/workflows/tag-main.yml"
if [[ -f "$TAG_WF" ]]; then
    _record_pass "tag-main.yml file exists"
    TAG_CONTENT="$(cat "$TAG_WF")"
    # push trigger on main branch
    if echo "$TAG_CONTENT" | python3 -c '
import re, sys
txt = sys.stdin.read()
sys.exit(0 if re.search(r"push:\s*\n\s*branches:\s*\n\s*-\s*main\b", txt) else 1)
' ; then
        _record_pass "tag-main.yml triggers on push.branches: [main]"
    else
        _record_fail "tag-main.yml missing push.branches: [main] trigger"
    fi
    # permissions contents: write
    if echo "$TAG_CONTENT" | python3 -c '
import re, sys
txt = sys.stdin.read()
sys.exit(0 if re.search(r"permissions:\s*\n\s*contents:\s*write", txt) else 1)
' ; then
        _record_pass "tag-main.yml declares contents: write permission"
    else
        _record_fail "tag-main.yml missing contents: write permission"
    fi
    # actually creates a main-* tag (regex)
    if [[ "$TAG_CONTENT" =~ main-\$\{short\} ]] \
        || echo "$TAG_CONTENT" | grep -q 'main-'; then
        _record_pass "tag-main.yml creates main-* tags"
    else
        _record_fail "tag-main.yml does not create main-* tags"
    fi
else
    _record_fail "tag-main.yml workflow file not found"
fi

test_case "record_prev_state_uses_main_tag" "record-prev-state queries git tag --list 'main-*'"
if echo "$WF_CONTENT" | grep -qE "git tag --list ['\"]main-\\*['\"]"; then
    _record_pass "record-prev-state uses git tag --list 'main-*'"
else
    _record_fail "record-prev-state does not query git tag --list 'main-*'"
fi

# ── workflow_dispatch feature: both triggers + inputs declared + referenced ──
test_case "workflow_dispatch_feature" "workflow has both workflow_run and workflow_dispatch triggers with expected inputs"
if echo "$WF_CONTENT" | python3 -c '
import re, sys
txt = sys.stdin.read()
# Both triggers must appear under on:
has_run = bool(re.search(r"workflow_run:", txt))
has_dispatch = bool(re.search(r"workflow_dispatch:", txt))
has_target_app = bool(re.search(r"target_app:", txt))
has_force_rollback = bool(re.search(r"force_rollback:", txt))
sys.exit(0 if (has_run and has_dispatch and has_target_app and has_force_rollback) else 1)
' ; then
    _record_pass "workflow declares both triggers and both inputs"
else
    _record_fail "workflow missing workflow_run, workflow_dispatch, target_app, or force_rollback"
fi
if echo "$WF_CONTENT" | grep -qE 'inputs\.target_app'; then
    _record_pass "job references \${{ inputs.target_app }}"
else
    _record_fail "job does not reference inputs.target_app"
fi
if echo "$WF_CONTENT" | grep -qE 'inputs\.force_rollback'; then
    _record_pass "job references \${{ inputs.force_rollback }}"
else
    _record_fail "job does not reference inputs.force_rollback"
fi

summarise
