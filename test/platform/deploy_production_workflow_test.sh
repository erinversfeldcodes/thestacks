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
#   2. Top-level trigger is `on.push.branches: [main]` plus
#      `workflow_dispatch`. workflow_run is NOT used (PR-level branch
#      protection already gates CI-must-pass before merge, so the prod
#      deploy fires directly on the merge commit).
#   3. A job named `deploy-production` exists with a recognisable step
#      sequence: checkout → record-prev-state → deploy-stack.sh →
#      check-slo-gate.sh → conditional rollback → upload-artifact → summary.
#   4. References the expected secrets (superset of deploy-preview + METRICS_SCRAPE_TOKEN).

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

# ── push.main trigger ────────────────────────────────────────────────────────
test_case "push_main_trigger" "triggered by push to main + workflow_dispatch (workflow_run removed at merge)"
PARSE_OUT=$(python3 - "$WF" <<'PY' 2>&1
import re, sys

path = sys.argv[1]
with open(path) as f:
    txt = f.read()

# We avoid depending on PyYAML — the existing ci_migration_safety_job_test.sh
# deliberately uses regex for the same reason. Phase 3 keeps the convention.
findings = []

# Must contain `on:` block with `push:` + `branches: [main]`.
if not re.search(r"^on:\s*$", txt, re.MULTILINE):
    findings.append("no top-level `on:` block")
if not re.search(r"^\s+push:\s*$", txt, re.MULTILINE):
    findings.append("on.push not present")
# Accept either inline (`branches: [main]`) or block (`branches:\n  - main`).
if not re.search(r"branches:\s*\[\s*main\s*\]", txt) and \
   not re.search(r"branches:\s*\n\s*-\s*main\b", txt):
    findings.append("on.push.branches does not list main")
# workflow_dispatch must still be present (operator manual trigger).
if not re.search(r"^\s+workflow_dispatch:\s*$", txt, re.MULTILINE):
    findings.append("on.workflow_dispatch not present")

# Guardrail: workflow_run must be GONE — PR-level branch protection gates
# CI-must-pass before merge, so prod deploy fires directly on the merge
# commit (no separate workflow_run signal needed).
if re.search(r"^\s+workflow_run:\s*$", txt, re.MULTILINE):
    findings.append("on.workflow_run is still present — should be removed at merge time")
# Guardrail: pull_request must be GONE (was a Phase 7 iteration trigger).
if re.search(r"^\s+pull_request:\s*$", txt, re.MULTILINE):
    findings.append("on.pull_request is still present — should be removed at merge time")

if findings:
    print("FINDINGS:" + "||".join(findings))
    sys.exit(1)
print("OK")
PY
)
RC=$?
assert_exit_zero "$RC" "trigger shape is push.branches=[main] + workflow_dispatch"
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
    "rollback":          r"(scripts/rollback-production\.sh|rollback-production|\brollback\b)",
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
p_roll = pos(r"(scripts/rollback-production\.sh|rollback-production|\brollback\b)")
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
# NEON_PROJECT_ID + NEON_API_KEY were intentionally removed from
# deploy-production.yml in #142 (two-project Neon architecture). Prod mode
# never consults Neon — DATABASE_URL is composed from STACKS_PROD_DB_*
# components — so neither secret should be referenced from this workflow.
REQUIRED_SECRETS=(
    FLY_API_TOKEN
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
test_case "rollback_if_failure" "rollback step uses failure() (not just gate.conclusion)"
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

# ── Reviewer P1 #5: tag-on-deploy-success workflow + record-prev-state ───────
# tag-main fires on Deploy production / workflow_run success — failed deploys
# never get a tag, so `main-*` markers always point at known-good prod.
test_case "tag_main_workflow" "tag-main.yml fires on Deploy production success, has contents: write"
TAG_WF="$REPO_ROOT/.github/workflows/tag-main.yml"
if [[ -f "$TAG_WF" ]]; then
    _record_pass "tag-main.yml file exists"
    TAG_CONTENT="$(cat "$TAG_WF")"
    # workflow_run trigger on Deploy production
    if echo "$TAG_CONTENT" | python3 -c '
import re, sys
txt = sys.stdin.read()
has_run = bool(re.search(r"workflow_run:", txt))
has_target = bool(re.search(r"workflows:\s*\[\s*\"Deploy production\"\s*\]", txt) or \
                  re.search(r"workflows:\s*\n\s*-\s*\"?Deploy production\"?", txt))
sys.exit(0 if (has_run and has_target) else 1)
' ; then
        _record_pass "tag-main.yml triggers on workflow_run: Deploy production"
    else
        _record_fail "tag-main.yml missing workflow_run trigger targeting Deploy production"
    fi
    # success-only conclusion guard
    if echo "$TAG_CONTENT" | grep -qE "workflow_run\.conclusion\s*==\s*'success'"; then
        _record_pass "tag-main.yml gates on workflow_run.conclusion == 'success'"
    else
        _record_fail "tag-main.yml does not gate on workflow_run.conclusion == 'success'"
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
test_case "workflow_dispatch_feature" "workflow has push + workflow_dispatch triggers with expected inputs"
if echo "$WF_CONTENT" | python3 -c '
import re, sys
txt = sys.stdin.read()
# Both triggers must appear under on:
has_push = bool(re.search(r"^\s+push:\s*$", txt, re.MULTILINE))
has_dispatch = bool(re.search(r"workflow_dispatch:", txt))
has_target_app = bool(re.search(r"target_app:", txt))
has_force_rollback = bool(re.search(r"force_rollback:", txt))
sys.exit(0 if (has_push and has_dispatch and has_target_app and has_force_rollback) else 1)
' ; then
    _record_pass "workflow declares both triggers and both inputs"
else
    _record_fail "workflow missing push, workflow_dispatch, target_app, or force_rollback"
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

# ════════════════════════════════════════════════════════════════════════════
# PHASE 4 CONTRACT (Issue #137): Workflow shape after composite-action wiring
# ════════════════════════════════════════════════════════════════════════════
#
# These cases assert the SHAPE the Phase 4 implementation must produce in
# .github/workflows/deploy-production.yml:
#   - manual_rollback workflow_dispatch input (Case M1)
#   - Capture pre-migrate Neon LSN (prod) step (Case M2)
#   - Run prod migrations (before image cutover) step (Case M3)
#   - Rollback step uses ./.github/actions/rollback-production (Cases M4 + M5)
#   - Manual-rollback short-circuit gating on deploy-side steps (Case M6)
#   - actionlint clean (Case M7, best-effort)
#
# YAML parsing strategy mirrors test/platform/rollback_action_composite_test.sh:
# probe for a Python with `yaml` importable, parse-once, and `jq` the JSON form.
# ────────────────────────────────────────────────────────────────────────────

# ── YAML-capable Python probe (Phase 4 helper) ──────────────────────────────
_pick_yaml_python_p4() {
    local candidates=(
        "$REPO_ROOT/.venv-tools/bin/python3"
        "$REPO_ROOT/scripts/mcp/.venv/bin/python3"
        "python3"
    )
    for cand in "${candidates[@]}"; do
        if command -v "$cand" >/dev/null 2>&1 \
            && "$cand" -c "import yaml" >/dev/null 2>&1; then
            echo "$cand"
            return 0
        fi
    done
    # Last resort: ephemeral venv with pyyaml.
    local fallback_venv="${TMPDIR:-/tmp}/stacks-deploy-prod-test-venv"
    if [[ ! -x "$fallback_venv/bin/python3" ]] \
        || ! "$fallback_venv/bin/python3" -c "import yaml" >/dev/null 2>&1; then
        python3 -m venv "$fallback_venv" >/dev/null 2>&1 || return 1
        "$fallback_venv/bin/pip" install --quiet pyyaml >/dev/null 2>&1 || return 1
    fi
    echo "$fallback_venv/bin/python3"
    return 0
}

YAML_PY="$(_pick_yaml_python_p4 || true)"
if [[ -z "$YAML_PY" ]]; then
    test_case "phase4_yaml_python_available" "Python with pyyaml is available for Phase 4 probes"
    _record_fail "no Python interpreter with pyyaml available; Phase 4 contract cases cannot parse YAML"
    summarise
    exit $?
fi

# ── YAML parse cache: parse the workflow once, reuse across cases ───────────
WF_JSON_TMP="$(mktemp -t deploy-prod-wf-json.XXXXXX)"
trap 'rm -f "$WF_JSON_TMP"' EXIT
"$YAML_PY" - "$WF" >"$WF_JSON_TMP" 2>/dev/null <<'PY' || echo "{}" >"$WF_JSON_TMP"
import json, sys, yaml
with open(sys.argv[1]) as f:
    data = yaml.safe_load(f)
print(json.dumps(data if data is not None else {}))
PY

wfq() {
    # wfq <jq-filter>: jq the parsed workflow JSON.
    local filter="$1"
    jq -r "$filter" "$WF_JSON_TMP"
}

# Resolve the deploy-production job's steps once. The "on" key in YAML
# becomes the literal string "on" in JSON. PyYAML may also coerce some
# unquoted keys to booleans — we don't depend on `on:` anywhere below so
# this is fine.
JOB_STEPS_JQ='.jobs["deploy-production"].steps // []'

# Helper: extract a step's index in the steps array by id, or -1.
step_idx_by_id() {
    local target="$1"
    wfq "[$JOB_STEPS_JQ | to_entries[] | select(.value.id == \"$target\") | .key] | (.[0] // -1)"
}

# Helper: extract a step's index in the steps array by `run:` substring, or -1.
step_idx_by_run_substr() {
    local needle="$1"
    wfq "[$JOB_STEPS_JQ | to_entries[] | select((.value.run // \"\") | contains(\"$needle\")) | .key] | (.[0] // -1)"
}

# Helper: extract a step's index by name substring (case-insensitive), or -1.
step_idx_by_name_substr_ci() {
    local needle_lower="$1"
    wfq "[$JOB_STEPS_JQ | to_entries[] | select((.value.name // \"\" | ascii_downcase) | contains(\"$needle_lower\")) | .key] | (.[0] // -1)"
}

# ── Case M1: manual_rollback workflow_dispatch input declared ───────────────
test_case "manual_rollback_input" "workflow_dispatch.inputs.manual_rollback declared with type: boolean, default: false"

# `on` becomes the string "on" key in the parsed JSON, but PyYAML may also
# coerce the bare `on:` literal to True under YAML 1.1. Probe both.
MR_TYPE="$(wfq '(.on // .true).workflow_dispatch.inputs.manual_rollback.type // ""')"
MR_DESC="$(wfq '(.on // .true).workflow_dispatch.inputs.manual_rollback.description // ""')"
# Default needs special handling: YAML `default: false` parses to JSON
# boolean false, and `// "__missing__"` would substitute since `false` is
# falsy in jq. Use `has("default")` to distinguish missing from false.
MR_HAS_DEFAULT="$(wfq '(.on // .true).workflow_dispatch.inputs.manual_rollback | has("default")')"
MR_DEFAULT="$(wfq '(.on // .true).workflow_dispatch.inputs.manual_rollback.default')"

if [[ "$MR_TYPE" == "boolean" ]]; then
    _record_pass "manual_rollback type is boolean"
else
    _record_fail "manual_rollback type must be 'boolean' (got: '$MR_TYPE')"
fi

# Default must be present and equal to false (boolean or string form).
if [[ "$MR_HAS_DEFAULT" != "true" ]]; then
    _record_fail "manual_rollback default missing (input has no 'default' key)"
else
    case "$MR_DEFAULT" in
        false|False|FALSE) _record_pass "manual_rollback default is false" ;;
        *)                 _record_fail "manual_rollback default must be false (got: '$MR_DEFAULT')" ;;
    esac
fi

if [[ -n "$MR_DESC" && "$MR_DESC" != "null" ]]; then
    _record_pass "manual_rollback description is non-empty"
else
    _record_fail "manual_rollback description must be non-empty (got: '$MR_DESC')"
fi

# ── Case M2: Capture pre-migrate Neon LSN (prod) step ───────────────────────
test_case "capture_lsn_step" "step id capture-lsn captures LSN + branch-id, runs before migrate"

CAPTURE_IDX="$(step_idx_by_id capture-lsn)"
if [[ "$CAPTURE_IDX" -ge 0 ]]; then
    _record_pass "step id 'capture-lsn' present (index $CAPTURE_IDX)"

    CAPTURE_NAME="$(wfq "$JOB_STEPS_JQ | .[$CAPTURE_IDX].name // \"\"")"
    if [[ "$CAPTURE_NAME" == *"pre-migrate Neon LSN"* ]]; then
        _record_pass "capture-lsn step name contains 'pre-migrate Neon LSN' (operator-readable)"
    else
        _record_fail "capture-lsn step name must contain 'pre-migrate Neon LSN' (got: '$CAPTURE_NAME')"
    fi

    CAPTURE_RUN="$(wfq "$JOB_STEPS_JQ | .[$CAPTURE_IDX].run // \"\"")"
    if [[ "$CAPTURE_RUN" == *"pg_current_wal_lsn"* ]]; then
        _record_pass "capture-lsn run: references pg_current_wal_lsn"
    else
        _record_fail "capture-lsn run: must reference pg_current_wal_lsn"
    fi
    if [[ "$CAPTURE_RUN" == *"console.neon.tech/api/v2/projects"* ]]; then
        _record_pass "capture-lsn run: references console.neon.tech/api/v2/projects (branch-id resolution)"
    else
        _record_fail "capture-lsn run: must reference console.neon.tech/api/v2/projects"
    fi
    if [[ "$CAPTURE_RUN" == *"branches"* ]]; then
        _record_pass "capture-lsn run: references 'branches' (Neon API path segment)"
    else
        _record_fail "capture-lsn run: must reference 'branches' for branch-id resolution"
    fi
    if [[ "$CAPTURE_RUN" == *"lsn="* ]]; then
        _record_pass "capture-lsn run: writes lsn= to GITHUB_OUTPUT"
    else
        _record_fail "capture-lsn run: must write 'lsn=' to GITHUB_OUTPUT"
    fi
    if [[ "$CAPTURE_RUN" == *"branch-id="* ]]; then
        _record_pass "capture-lsn run: writes branch-id= to GITHUB_OUTPUT"
    else
        _record_fail "capture-lsn run: must write 'branch-id=' to GITHUB_OUTPUT"
    fi

    # env: must include DATABASE_URL (psql needs it).
    CAPTURE_ENV_DBURL="$(wfq "$JOB_STEPS_JQ | .[$CAPTURE_IDX].env.\"DATABASE_URL\" // \"__missing__\"")"
    if [[ "$CAPTURE_ENV_DBURL" == "__missing__" ]]; then
        _record_fail "capture-lsn env: must include DATABASE_URL"
    else
        _record_pass "capture-lsn env: DATABASE_URL is wired"
    fi

    # if: must reference manual_rollback (skip on manual rollback path).
    CAPTURE_IF="$(wfq "$JOB_STEPS_JQ | .[$CAPTURE_IDX].if // \"\"")"
    if [[ "$CAPTURE_IF" == *"manual_rollback"* ]]; then
        _record_pass "capture-lsn if: gates on manual_rollback (got: '$CAPTURE_IF')"
    else
        _record_fail "capture-lsn must have if: that references manual_rollback (got: '$CAPTURE_IF')"
    fi
else
    _record_fail "step id 'capture-lsn' missing — Phase 4 must add it"
fi

# ── Case M3: Migration runs inside deploy-stack.sh (not as a workflow step) ─
# Phase 7 iteration consolidated the runner-side migrate from a separate
# workflow step (`migrate-prod`) into deploy-stack.sh, right after its
# Elixir codegen and before the `fly deploy` cutover. Single compile +
# codegen instead of duplicated across the workflow and the script.
# Failure semantics unchanged: a migrate failure aborts deploy-stack.sh
# before any image swap, so the old image keeps serving traffic.
test_case "migrate_inside_deploy_stack" "deploy-stack.sh runs mix ecto.migrate before the core fly deploy"

DEPLOY_STACK_SCRIPT="$REPO_ROOT/scripts/deploy-stack.sh"
if [[ -f "$DEPLOY_STACK_SCRIPT" ]]; then
    if grep -q "mix ecto.migrate" "$DEPLOY_STACK_SCRIPT"; then
        _record_pass "deploy-stack.sh contains 'mix ecto.migrate'"
    else
        _record_fail "deploy-stack.sh must invoke 'mix ecto.migrate' as part of the prod deploy path"
    fi
    # Order inside the script: gen-ecto-proto.sh (Elixir codegen) must
    # precede mix ecto.migrate (which compiles + migrates), and both
    # must precede the core `fly deploy` cutover.
    GEN_LINE=$(grep -n "gen-ecto-proto.sh" "$DEPLOY_STACK_SCRIPT" | head -1 | cut -d: -f1)
    MIGRATE_LINE=$(grep -n "mix ecto.migrate" "$DEPLOY_STACK_SCRIPT" | head -1 | cut -d: -f1)
    # Find the CORE `fly deploy` cutover specifically — that's the one
    # migrate must precede. Other fly deploys in the script (scraper,
    # searxng, log-shipper) don't touch the schema so their ordering vs
    # migrate doesn't matter. The core deploy passes `--app "${CORE_APP}"`
    # which is the discriminator.
    FLY_DEPLOY_LINE=$(grep -nE 'fly deploy[[:space:]]*\\?$|fly deploy.*--app[[:space:]]+"\$\{CORE_APP\}"' "$DEPLOY_STACK_SCRIPT" \
                       | grep -A1 'fly deploy[[:space:]]*\\$' "$DEPLOY_STACK_SCRIPT" 2>/dev/null \
                       | head -1)
    # Simpler: find the core deploy by looking for the function that wraps
    # it (`_core_deploy_once`) — its body starts with the actual fly deploy.
    CORE_DEPLOY_FN_LINE=$(grep -n '^_core_deploy_once' "$DEPLOY_STACK_SCRIPT" | head -1 | cut -d: -f1)
    if [[ -n "$CORE_DEPLOY_FN_LINE" ]]; then
        # The fly deploy invocation lives ~1-2 lines after the function decl.
        FLY_DEPLOY_LINE=$(awk -v start="$CORE_DEPLOY_FN_LINE" 'NR>=start && /fly deploy/ {print NR; exit}' "$DEPLOY_STACK_SCRIPT")
    else
        # Fallback: first non-comment fly deploy invocation.
        FLY_DEPLOY_LINE=$(grep -nE '^[[:space:]]+(\(.*&&[[:space:]]*)?fly deploy' "$DEPLOY_STACK_SCRIPT" | head -1 | cut -d: -f1)
    fi
    if [[ -n "$GEN_LINE" && -n "$MIGRATE_LINE" && "$GEN_LINE" -lt "$MIGRATE_LINE" ]]; then
        _record_pass "deploy-stack.sh order: gen-ecto-proto (#$GEN_LINE) < mix ecto.migrate (#$MIGRATE_LINE)"
    else
        _record_fail "deploy-stack.sh order: gen-ecto-proto must precede mix ecto.migrate (gen=#$GEN_LINE migrate=#$MIGRATE_LINE)"
    fi
    if [[ -n "$MIGRATE_LINE" && -n "$FLY_DEPLOY_LINE" && "$MIGRATE_LINE" -lt "$FLY_DEPLOY_LINE" ]]; then
        _record_pass "deploy-stack.sh order: mix ecto.migrate (#$MIGRATE_LINE) < first fly deploy (#$FLY_DEPLOY_LINE)"
    else
        _record_fail "deploy-stack.sh order: mix ecto.migrate must precede the first fly deploy (migrate=#$MIGRATE_LINE fly=#$FLY_DEPLOY_LINE)"
    fi
else
    _record_fail "scripts/deploy-stack.sh not found — cannot verify migrate placement"
fi

# Negative assertion: the legacy `migrate-prod` workflow step must NOT
# exist after the consolidation. If it reappears, somebody re-added the
# duplicated path.
LEGACY_MIGRATE_IDX="$(step_idx_by_id migrate-prod)"
if [[ "$LEGACY_MIGRATE_IDX" -lt 0 ]]; then
    _record_pass "legacy 'migrate-prod' workflow step is absent (consolidated into deploy-stack.sh)"
else
    _record_fail "legacy 'migrate-prod' workflow step at index $LEGACY_MIGRATE_IDX should have been removed (migration now lives inside deploy-stack.sh)"
fi

DEPLOY_STACK_IDX="$(step_idx_by_run_substr "deploy-stack.sh")"

# ── Case M3b: Test-helper flag (Issue #124) is preview-only, never prod ─────
# GET /api/test/confirmation-token is gated by the server env
# STACKS_E2E_TEST_HELPERS; when "1" it returns an account-activation token,
# so it must NEVER be enabled in production. The preview branch of
# deploy-stack.sh sets it to "1" (the E2E confirm-email + onboarding specs
# need it live on the preview app); the --production branch forces it empty
# so it can never reach the prod app. Enforced statically here so a future
# edit that leaks the flag into prod fails CI.
test_case "e2e_test_helpers_preview_only" "deploy-stack.sh enables STACKS_E2E_TEST_HELPERS only for previews, never production"

if [[ -f "$DEPLOY_STACK_SCRIPT" ]]; then
    # Anchors that uniquely identify each branch of the prod/preview
    # conditional: NEON_STAGING_API_KEY="" lives only in the --production
    # branch; CORE_APP="${PREVIEW_CORE_APP}" only in the preview branch.
    PROD_ANCHOR=$(grep -n 'NEON_STAGING_API_KEY=""' "$DEPLOY_STACK_SCRIPT" | head -1 | cut -d: -f1)
    PREVIEW_ANCHOR=$(grep -n "CORE_APP=\"\${PREVIEW_CORE_APP}\"" "$DEPLOY_STACK_SCRIPT" | head -1 | cut -d: -f1)
    HELPERS_ENABLE_LINE=$(grep -n 'STACKS_E2E_TEST_HELPERS="1"' "$DEPLOY_STACK_SCRIPT" | head -1 | cut -d: -f1)
    HELPERS_EMPTY_LINE=$(grep -n 'STACKS_E2E_TEST_HELPERS=""' "$DEPLOY_STACK_SCRIPT" | head -1 | cut -d: -f1)

    # 1. The "1" enablement exists and sits inside the preview branch.
    if [[ -n "$HELPERS_ENABLE_LINE" && -n "$PREVIEW_ANCHOR" && "$HELPERS_ENABLE_LINE" -gt "$PREVIEW_ANCHOR" ]]; then
        _record_pass "STACKS_E2E_TEST_HELPERS=\"1\" (#$HELPERS_ENABLE_LINE) lives in the preview branch (after #$PREVIEW_ANCHOR)"
    else
        _record_fail "STACKS_E2E_TEST_HELPERS=\"1\" must be set in the preview branch (enable=#$HELPERS_ENABLE_LINE preview_anchor=#$PREVIEW_ANCHOR)"
    fi

    # 2. The prod branch forces the flag empty, BEFORE the preview branch
    #    begins — proving production cannot inherit the "1" value.
    if [[ -n "$HELPERS_EMPTY_LINE" && -n "$PROD_ANCHOR" && -n "$PREVIEW_ANCHOR" \
          && "$HELPERS_EMPTY_LINE" -gt "$PROD_ANCHOR" && "$HELPERS_EMPTY_LINE" -lt "$PREVIEW_ANCHOR" ]]; then
        _record_pass "prod branch forces STACKS_E2E_TEST_HELPERS=\"\" (#$HELPERS_EMPTY_LINE, between prod anchor #$PROD_ANCHOR and preview anchor #$PREVIEW_ANCHOR)"
    else
        _record_fail "prod branch must force STACKS_E2E_TEST_HELPERS=\"\" before the preview branch (empty=#$HELPERS_EMPTY_LINE prod_anchor=#$PROD_ANCHOR preview_anchor=#$PREVIEW_ANCHOR)"
    fi

    # 3. The core secrets-set gates the flag behind ${VAR:+...}, so an empty
    #    value in prod mode is omitted entirely (no empty secret is staged).
    if grep -q "\${STACKS_E2E_TEST_HELPERS:+STACKS_E2E_TEST_HELPERS=" "$DEPLOY_STACK_SCRIPT"; then
        _record_pass "secrets block gates the flag behind \${STACKS_E2E_TEST_HELPERS:+...} (empty → omitted)"
    else
        _record_fail "secrets block must pass the flag via \${STACKS_E2E_TEST_HELPERS:+...} so an empty prod value is omitted"
    fi

    # 4. Defense-in-depth: prod mode explicitly unsets any lingering Fly
    #    secret so a hand-set value can't survive across deploys.
    if grep -q 'fly secrets unset STACKS_E2E_TEST_HELPERS' "$DEPLOY_STACK_SCRIPT"; then
        _record_pass "prod path unsets any lingering STACKS_E2E_TEST_HELPERS Fly secret"
    else
        _record_fail "prod path should 'fly secrets unset STACKS_E2E_TEST_HELPERS' as defense-in-depth"
    fi
else
    _record_fail "scripts/deploy-stack.sh not found — cannot verify test-helper gating"
fi

# ── Case M4: Rollback step uses composite action (not inline bash) ──────────
test_case "rollback_uses_composite_action" "rollback step uses ./.github/actions/rollback-production"

ROLLBACK_IDX="$(step_idx_by_id rollback)"
if [[ "$ROLLBACK_IDX" -ge 0 ]]; then
    _record_pass "step id 'rollback' present (index $ROLLBACK_IDX)"

    ROLLBACK_USES="$(wfq "$JOB_STEPS_JQ | .[$ROLLBACK_IDX].uses // \"\"")"
    if [[ "$ROLLBACK_USES" == "./.github/actions/rollback-production" ]]; then
        _record_pass "rollback step uses ./.github/actions/rollback-production"
    else
        _record_fail "rollback step uses: must be './.github/actions/rollback-production' (got: '$ROLLBACK_USES')"
    fi

    ROLLBACK_RUN="$(wfq "$JOB_STEPS_JQ | .[$ROLLBACK_IDX].run // \"__missing__\"")"
    if [[ "$ROLLBACK_RUN" == "__missing__" ]]; then
        _record_pass "rollback step has no inline run: (action invocation only)"
    else
        _record_fail "rollback step must NOT have a run: field (got: '$(printf '%s' "$ROLLBACK_RUN" | head -c 80)…')"
    fi

    ROLLBACK_IF="$(wfq "$JOB_STEPS_JQ | .[$ROLLBACK_IDX].if // \"\"")"
    if [[ "$ROLLBACK_IF" == *"failure()"* ]]; then
        _record_pass "rollback if: contains failure()"
    else
        _record_fail "rollback if: must contain failure() (got: '$ROLLBACK_IF')"
    fi
    if [[ "$ROLLBACK_IF" == *"manual_rollback"* ]]; then
        _record_pass "rollback if: contains manual_rollback"
    else
        _record_fail "rollback if: must reference inputs.manual_rollback (got: '$ROLLBACK_IF')"
    fi
else
    _record_fail "step id 'rollback' missing — Phase 4 must rename + restructure the inline rollback step"
fi

# Old inline `bash scripts/rollback-production.sh` step must be GONE.
INLINE_ROLLBACK_RUN_IDX="$(step_idx_by_run_substr "scripts/rollback-production.sh")"
if [[ "$INLINE_ROLLBACK_RUN_IDX" -lt 0 ]]; then
    _record_pass "no step's run: directly invokes scripts/rollback-production.sh (composite action wraps it)"
else
    _record_fail "inline rollback step at index $INLINE_ROLLBACK_RUN_IDX still invokes scripts/rollback-production.sh — must be replaced by composite action"
fi

# ── Case M5: Rollback step's with: block wires all required inputs ──────────
test_case "rollback_with_inputs" "rollback step's with: block wires all 17 composite-action inputs"

# `with` value lookups for the rollback step. Each accepts varying valid forms.
_rb_with() {
    # _rb_with <input-key>: prints the value at .with.<key>, or empty.
    local key="$1"
    if [[ "$ROLLBACK_IDX" -ge 0 ]]; then
        wfq "$JOB_STEPS_JQ | .[$ROLLBACK_IDX].with.\"$key\" // \"\""
    else
        echo ""
    fi
}

# core-app: any expression containing CORE_APP (env or literal).
RB_CORE_APP="$(_rb_with core-app)"
if [[ "$RB_CORE_APP" == *"CORE_APP"* ]]; then
    _record_pass "with.core-app references CORE_APP"
else
    _record_fail "with.core-app must reference CORE_APP env (got: '$RB_CORE_APP')"
fi

# core-prev-image: env.CORE_PREV_IMAGE.
RB_CORE_PREV="$(_rb_with core-prev-image)"
if [[ "$RB_CORE_PREV" == *"CORE_PREV_IMAGE"* ]]; then
    _record_pass "with.core-prev-image references CORE_PREV_IMAGE"
else
    _record_fail "with.core-prev-image must reference env.CORE_PREV_IMAGE (got: '$RB_CORE_PREV')"
fi

# modal-app: env.MODAL_APP_NAME OR literal thestacks-vision.
RB_MODAL_APP="$(_rb_with modal-app)"
if [[ "$RB_MODAL_APP" == *"MODAL_APP_NAME"* || "$RB_MODAL_APP" == *"thestacks-vision"* ]]; then
    _record_pass "with.modal-app references MODAL_APP_NAME or thestacks-vision"
else
    _record_fail "with.modal-app must reference env.MODAL_APP_NAME or 'thestacks-vision' (got: '$RB_MODAL_APP')"
fi

# modal-prev-commit: env.MODAL_PREV_COMMIT.
RB_MODAL_PREV="$(_rb_with modal-prev-commit)"
if [[ "$RB_MODAL_PREV" == *"MODAL_PREV_COMMIT"* ]]; then
    _record_pass "with.modal-prev-commit references MODAL_PREV_COMMIT"
else
    _record_fail "with.modal-prev-commit must reference env.MODAL_PREV_COMMIT (got: '$RB_MODAL_PREV')"
fi

# modal-token-id: secrets.MODAL_TOKEN_ID.
RB_MODAL_TID="$(_rb_with modal-token-id)"
if [[ "$RB_MODAL_TID" == *"secrets."*"MODAL_TOKEN_ID"* ]]; then
    _record_pass "with.modal-token-id references secrets.MODAL_TOKEN_ID"
else
    _record_fail "with.modal-token-id must reference secrets.MODAL_TOKEN_ID (got: '$RB_MODAL_TID')"
fi

# modal-token-secret: secrets.MODAL_TOKEN_SECRET.
RB_MODAL_TSEC="$(_rb_with modal-token-secret)"
if [[ "$RB_MODAL_TSEC" == *"secrets."*"MODAL_TOKEN_SECRET"* ]]; then
    _record_pass "with.modal-token-secret references secrets.MODAL_TOKEN_SECRET"
else
    _record_fail "with.modal-token-secret must reference secrets.MODAL_TOKEN_SECRET (got: '$RB_MODAL_TSEC')"
fi

# fly-api-token: secrets.FLY_API_TOKEN.
RB_FLY="$(_rb_with fly-api-token)"
if [[ "$RB_FLY" == *"secrets."*"FLY_API_TOKEN"* ]]; then
    _record_pass "with.fly-api-token references secrets.FLY_API_TOKEN"
else
    _record_fail "with.fly-api-token must reference secrets.FLY_API_TOKEN (got: '$RB_FLY')"
fi

# rollback-reason: non-trivial expression (contains an expression delimiter).
RB_REASON="$(_rb_with rollback-reason)"
if [[ -n "$RB_REASON" && "$RB_REASON" != "null" ]] \
    && { [[ "$RB_REASON" == *"manual_rollback"* ]] || [[ "$RB_REASON" == *"\${{"* ]] || [[ "$RB_REASON" == *"format("* ]]; }; then
    _record_pass "with.rollback-reason has a non-trivial expression"
else
    _record_fail "with.rollback-reason must contain a non-trivial expression (e.g. ternary on manual_rollback) (got: '$RB_REASON')"
fi

# neon-project-id: secrets.NEON_PROJECT_ID.
RB_NEON_PID="$(_rb_with neon-project-id)"
if [[ "$RB_NEON_PID" == *"secrets."*"NEON_PROJECT_ID"* ]]; then
    _record_pass "with.neon-project-id references secrets.NEON_PROJECT_ID"
else
    _record_fail "with.neon-project-id must reference secrets.NEON_PROJECT_ID (got: '$RB_NEON_PID')"
fi

# neon-api-key: secrets.NEON_API_KEY.
RB_NEON_KEY="$(_rb_with neon-api-key)"
if [[ "$RB_NEON_KEY" == *"secrets."*"NEON_API_KEY"* ]]; then
    _record_pass "with.neon-api-key references secrets.NEON_API_KEY"
else
    _record_fail "with.neon-api-key must reference secrets.NEON_API_KEY (got: '$RB_NEON_KEY')"
fi

# neon-branch-id: steps.capture-lsn.outputs.branch-id.
RB_NEON_BID="$(_rb_with neon-branch-id)"
if [[ "$RB_NEON_BID" == *"steps.capture-lsn.outputs.branch-id"* ]]; then
    _record_pass "with.neon-branch-id references steps.capture-lsn.outputs.branch-id"
else
    _record_fail "with.neon-branch-id must reference steps.capture-lsn.outputs.branch-id (got: '$RB_NEON_BID')"
fi

# pre-migrate-lsn: steps.capture-lsn.outputs.lsn.
RB_LSN="$(_rb_with pre-migrate-lsn)"
if [[ "$RB_LSN" == *"steps.capture-lsn.outputs.lsn"* ]]; then
    _record_pass "with.pre-migrate-lsn references steps.capture-lsn.outputs.lsn"
else
    _record_fail "with.pre-migrate-lsn must reference steps.capture-lsn.outputs.lsn (got: '$RB_LSN')"
fi

# failed-sha: github.sha.
RB_FAILED_SHA="$(_rb_with failed-sha)"
if [[ "$RB_FAILED_SHA" == *"github.sha"* ]]; then
    _record_pass "with.failed-sha references github.sha"
else
    _record_fail "with.failed-sha must reference github.sha (got: '$RB_FAILED_SHA')"
fi

# triggered-by: non-trivial expression.
RB_TRIGGERED="$(_rb_with triggered-by)"
if [[ -n "$RB_TRIGGERED" && "$RB_TRIGGERED" != "null" ]] \
    && { [[ "$RB_TRIGGERED" == *"manual_rollback"* ]] || [[ "$RB_TRIGGERED" == *"\${{"* ]] || [[ "$RB_TRIGGERED" == *"&&"* ]]; }; then
    _record_pass "with.triggered-by has a non-trivial expression"
else
    _record_fail "with.triggered-by must contain a non-trivial expression (e.g. ternary on manual_rollback) (got: '$RB_TRIGGERED')"
fi

# database-url: env.DATABASE_URL OR secrets.DATABASE_URL.
RB_DBURL="$(_rb_with database-url)"
if [[ "$RB_DBURL" == *"env.DATABASE_URL"* || "$RB_DBURL" == *"secrets.DATABASE_URL"* ]]; then
    _record_pass "with.database-url references env.DATABASE_URL or secrets.DATABASE_URL"
else
    _record_fail "with.database-url must reference env.DATABASE_URL or secrets.DATABASE_URL (got: '$RB_DBURL')"
fi

# cloak-key: secrets.CLOAK_KEY.
RB_CLOAK="$(_rb_with cloak-key)"
if [[ "$RB_CLOAK" == *"secrets."*"CLOAK_KEY"* ]]; then
    _record_pass "with.cloak-key references secrets.CLOAK_KEY"
else
    _record_fail "with.cloak-key must reference secrets.CLOAK_KEY (got: '$RB_CLOAK')"
fi

# ── Case M6: Manual-rollback short-circuit gating on deploy-side steps ──────
test_case "manual_rollback_short_circuit" "deploy-side steps are gated on !inputs.manual_rollback"

# Find the deploy-stack step by run: substring (it has no id).
DEPLOY_STACK_IF="$(wfq "$JOB_STEPS_JQ | .[] | select((.run // \"\") | contains(\"deploy-stack.sh\")) | .if // \"\"" | head -n1)"
if [[ "$DEPLOY_STACK_IF" == *"manual_rollback"* ]]; then
    _record_pass "deploy-stack step if: references manual_rollback (got: '$DEPLOY_STACK_IF')"
else
    _record_fail "deploy-stack step must have if: that references manual_rollback (got: '$DEPLOY_STACK_IF')"
fi

# Find the gate step by id `gate` (canonical).
GATE_IF="$(wfq "$JOB_STEPS_JQ | .[] | select(.id == \"gate\") | .if // \"\"" | head -n1)"
if [[ "$GATE_IF" == *"manual_rollback"* ]]; then
    _record_pass "gate step if: references manual_rollback (got: '$GATE_IF')"
else
    _record_fail "gate step must have if: that references manual_rollback (got: '$GATE_IF')"
fi

# Setup steps must NOT have a manual_rollback gate (they need to run on both
# paths so the composite action's `log-audit` step can compile the Elixir
# tree). Emit one assertion per setup step we want to verify is unchanged.
_assert_setup_step_no_manual_rollback() {
    # _assert_setup_step_no_manual_rollback <name-substring-lowercase> <kind: name|run|uses>
    local needle="$1"
    local kind="$2"
    local idx
    case "$kind" in
        name) idx="$(step_idx_by_name_substr_ci "$needle")" ;;
        run)  idx="$(step_idx_by_run_substr "$needle")" ;;
        uses) idx="$(wfq "[$JOB_STEPS_JQ | to_entries[] | select((.value.uses // \"\") | contains(\"$needle\")) | .key] | (.[0] // -1)")" ;;
        *)    _record_fail "_assert_setup_step_no_manual_rollback: unknown kind '$kind'"; return ;;
    esac
    if [[ "$idx" -lt 0 ]]; then
        _record_fail "setup step matching '$needle' (kind=$kind) not found — cannot verify gating"
        return
    fi
    local step_if
    step_if="$(wfq "$JOB_STEPS_JQ | .[$idx].if // \"\"")"
    if [[ "$step_if" == *"manual_rollback"* ]]; then
        _record_fail "setup step '$needle' must NOT be gated on manual_rollback (got if: '$step_if')"
    else
        _record_pass "setup step '$needle' is not gated on manual_rollback"
    fi
}

# These setup steps must run on both paths (manual rollback still needs the
# Elixir tree compiled for the composite action's `log-audit` step).
_assert_setup_step_no_manual_rollback "actions/checkout" uses
_assert_setup_step_no_manual_rollback "erlef/setup-beam" uses
_assert_setup_step_no_manual_rollback "mix deps.get" run
_assert_setup_step_no_manual_rollback "compose database_url" name

# ════════════════════════════════════════════════════════════════════════════
# ISSUE #138 PHASE 1 CONTRACT: prober secrets wired (replace owner-leak path)
# ════════════════════════════════════════════════════════════════════════════
#
# Phase 1 of #138 introduces a dedicated `prober@thestacks.app` user so the
# probe-production.sh login no longer reuses the owner password. The workflow
# must:
#   - Surface STACKS_PROBER_EMAIL / STACKS_PROBER_PASSWORD as env vars sourced
#     from secrets of the same names.
#   - Wire PROBE_SEED_EMAIL → STACKS_PROBER_EMAIL (NOT PROD_OWNER_EMAIL).
#   - Wire PROBE_SEED_PASSWORD → STACKS_PROBER_PASSWORD (NOT PROD_OWNER_PASSWORD).
#   - Invoke `seed_prober` alongside `seed_prod` in the deploy flow (the seed
#     call lives inside scripts/deploy-stack.sh OR is invoked from the
#     workflow; either path satisfies the contract — we accept a reference
#     anywhere in the workflow text or in deploy-stack.sh).
# ────────────────────────────────────────────────────────────────────────────

test_case "prober_secrets_wired" "deploy-production.yml uses STACKS_PROBER_* secrets, not PROD_OWNER_*, for prober login"

if [[ "$WF_CONTENT" == *"secrets.STACKS_PROBER_EMAIL"* ]]; then
    _record_pass "workflow references secrets.STACKS_PROBER_EMAIL"
else
    _record_fail "workflow must reference secrets.STACKS_PROBER_EMAIL (Phase 1 of #138)"
fi

if [[ "$WF_CONTENT" == *"secrets.STACKS_PROBER_PASSWORD"* ]]; then
    _record_pass "workflow references secrets.STACKS_PROBER_PASSWORD"
else
    _record_fail "workflow must reference secrets.STACKS_PROBER_PASSWORD (Phase 1 of #138)"
fi

# PROBE_SEED_EMAIL must be wired to the prober secret, not the owner secret.
PROBE_SEED_EMAIL_LINE="$(printf '%s\n' "$WF_CONTENT" | grep -E '^\s*PROBE_SEED_EMAIL:' | head -1 || true)"
if [[ -n "$PROBE_SEED_EMAIL_LINE" ]]; then
    if [[ "$PROBE_SEED_EMAIL_LINE" == *"STACKS_PROBER_EMAIL"* ]]; then
        _record_pass "PROBE_SEED_EMAIL is wired to secrets.STACKS_PROBER_EMAIL"
    else
        _record_fail "PROBE_SEED_EMAIL must reference secrets.STACKS_PROBER_EMAIL (got: '$PROBE_SEED_EMAIL_LINE')"
    fi
    if [[ "$PROBE_SEED_EMAIL_LINE" == *"PROD_OWNER_EMAIL"* ]]; then
        _record_fail "PROBE_SEED_EMAIL must NOT reference PROD_OWNER_EMAIL — owner password leak path closed by #138 Phase 1 (got: '$PROBE_SEED_EMAIL_LINE')"
    else
        _record_pass "PROBE_SEED_EMAIL no longer references PROD_OWNER_EMAIL"
    fi
else
    _record_fail "PROBE_SEED_EMAIL env binding not found in workflow"
fi

PROBE_SEED_PASSWORD_LINE="$(printf '%s\n' "$WF_CONTENT" | grep -E '^\s*PROBE_SEED_PASSWORD:' | head -1 || true)"
if [[ -n "$PROBE_SEED_PASSWORD_LINE" ]]; then
    if [[ "$PROBE_SEED_PASSWORD_LINE" == *"STACKS_PROBER_PASSWORD"* ]]; then
        _record_pass "PROBE_SEED_PASSWORD is wired to secrets.STACKS_PROBER_PASSWORD"
    else
        _record_fail "PROBE_SEED_PASSWORD must reference secrets.STACKS_PROBER_PASSWORD (got: '$PROBE_SEED_PASSWORD_LINE')"
    fi
    if [[ "$PROBE_SEED_PASSWORD_LINE" == *"PROD_OWNER_PASSWORD"* ]]; then
        _record_fail "PROBE_SEED_PASSWORD must NOT reference PROD_OWNER_PASSWORD — owner password leak path closed by #138 Phase 1 (got: '$PROBE_SEED_PASSWORD_LINE')"
    else
        _record_pass "PROBE_SEED_PASSWORD no longer references PROD_OWNER_PASSWORD"
    fi
else
    _record_fail "PROBE_SEED_PASSWORD env binding not found in workflow"
fi

# Some `seed_prober` reference must exist somewhere in the deploy chain.
# Accept either an in-workflow invocation OR a reference in
# scripts/deploy-stack.sh (which is the existing home for `seed_prod`).
DEPLOY_STACK_SCRIPT_PHASE1="$REPO_ROOT/scripts/deploy-stack.sh"
SEED_PROBER_FOUND="no"
if [[ "$WF_CONTENT" == *"seed_prober"* ]]; then
    SEED_PROBER_FOUND="yes-workflow"
elif [[ -f "$DEPLOY_STACK_SCRIPT_PHASE1" ]] \
    && grep -q "seed_prober" "$DEPLOY_STACK_SCRIPT_PHASE1"; then
    SEED_PROBER_FOUND="yes-deploy-stack"
fi
case "$SEED_PROBER_FOUND" in
    yes-*) _record_pass "seed_prober is invoked in the deploy chain ($SEED_PROBER_FOUND)" ;;
    no)    _record_fail "seed_prober must be invoked alongside seed_prod (in deploy-production.yml or scripts/deploy-stack.sh) — Phase 1 of #138" ;;
esac

# ── Case M7: actionlint clean (best-effort) ─────────────────────────────────
test_case "actionlint_clean_phase4" "actionlint passes on deploy-production.yml when available"
if command -v actionlint >/dev/null 2>&1; then
    if AL_OUT="$(actionlint "$WF" 2>&1)"; then
        _record_pass "actionlint passed on $WF"
    else
        _record_fail "actionlint failed: $AL_OUT"
    fi
else
    _record_pass "actionlint not on PATH; skipped"
fi

summarise
