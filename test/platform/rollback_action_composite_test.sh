#!/usr/bin/env bash

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib/assert.sh
source "$HERE/lib/assert.sh"

ACTION_DIR="$REPO_ROOT/.github/actions/rollback-production"
ACTION_YML="$ACTION_DIR/action.yml"
ACTION_README="$ACTION_DIR/README.md"

_pick_yaml_python() {
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
    local fallback_venv="${TMPDIR:-/tmp}/stacks-rollback-action-test-venv"
    if [[ ! -x "$fallback_venv/bin/python3" ]] \
        || ! "$fallback_venv/bin/python3" -c "import yaml" >/dev/null 2>&1; then
        python3 -m venv "$fallback_venv" >/dev/null 2>&1 || return 1
        "$fallback_venv/bin/pip" install --quiet pyyaml >/dev/null 2>&1 || return 1
    fi
    echo "$fallback_venv/bin/python3"
    return 0
}

YAML_PYTHON="$(_pick_yaml_python || true)"
if [[ -z "$YAML_PYTHON" ]]; then
    echo "FATAL: no Python interpreter with pyyaml available; cannot parse action.yml" >&2
    echo "       (tried .venv-tools, scripts/mcp/.venv, system python3, and an ephemeral venv)" >&2
    exit 2
fi

yaml_to_json() {
    local file="$1"
    if [[ ! -f "$file" ]]; then
        echo "{}"
        return 0
    fi
    "$YAML_PYTHON" - "$file" <<'PY'
import json, sys, yaml
with open(sys.argv[1]) as f:
    data = yaml.safe_load(f)
print(json.dumps(data if data is not None else {}))
PY
}

yaml_query() {
    local filter="$1"
    local file="$2"
    yaml_to_json "$file" | jq -r "$filter"
}

test_case "file_layout_exists" "action.yml + README.md must exist at .github/actions/rollback-production/"
assert_path_exists "$ACTION_YML" "action.yml exists at .github/actions/rollback-production/action.yml"
assert_path_exists "$ACTION_README" "README.md exists at .github/actions/rollback-production/README.md"

test_case "top_level_structure" "action.yml declares using:composite, name, description, and >=4 steps"
USING="$(yaml_query '.runs.using // ""' "$ACTION_YML")"
assert_contains "$USING" "composite" "runs.using is 'composite' (got: '$USING')"

NAME="$(yaml_query '.name // ""' "$ACTION_YML")"
if [[ -n "$NAME" && "$NAME" != "null" ]]; then
    _record_pass "name field is non-empty (got: '$NAME')"
else
    _record_fail "name field missing or empty"
fi

DESCRIPTION="$(yaml_query '.description // ""' "$ACTION_YML")"
if [[ -n "$DESCRIPTION" && "$DESCRIPTION" != "null" ]]; then
    _record_pass "description field is non-empty"
else
    _record_fail "description field missing or empty"
fi

STEP_COUNT="$(yaml_query '(.runs.steps // []) | length' "$ACTION_YML")"
if [[ "$STEP_COUNT" =~ ^[0-9]+$ ]] && [[ "$STEP_COUNT" -ge 4 ]]; then
    _record_pass "runs.steps has >=4 entries (got: $STEP_COUNT)"
else
    _record_fail "runs.steps must have at least 4 entries (got: '$STEP_COUNT')"
fi

test_case "required_inputs" "all 15 contract inputs declared with correct required-ness and defaults"
INPUT_CONTRACT=(
    "core-app|false|thestacks-core"
    "core-prev-image|true|__none__"
    "modal-app|false|thestacks-vision"
    "modal-prev-commit|false|"
    "modal-token-id|false|"
    "modal-token-secret|false|"
    "fly-api-token|true|__none__"
    "rollback-reason|true|__none__"
    "origin-remote|false|https://github.com/erinversfeld/thestacks.git"
    "neon-project-id|false|"
    "neon-api-key|false|"
    "neon-branch-id|false|"
    "pre-migrate-lsn|false|"
    "failed-sha|true|__none__"
    "triggered-by|true|__none__"
)

for entry in "${INPUT_CONTRACT[@]}"; do
    IFS='|' read -r INPUT_NAME EXPECTED_REQUIRED EXPECTED_DEFAULT <<< "$entry"

    EXISTS="$(yaml_query "(.inputs[\"$INPUT_NAME\"] // null) | (. != null)" "$ACTION_YML")"
    if [[ "$EXISTS" == "true" ]]; then
        _record_pass "input '$INPUT_NAME' is declared"
    else
        _record_fail "input '$INPUT_NAME' is missing from inputs:"
        continue
    fi

    ACTUAL_REQUIRED_RAW="$(yaml_query ".inputs[\"$INPUT_NAME\"].required // false" "$ACTION_YML")"
    case "$ACTUAL_REQUIRED_RAW" in
        true|True|TRUE) ACTUAL_REQUIRED="true" ;;
        *)              ACTUAL_REQUIRED="false" ;;
    esac
    if [[ "$ACTUAL_REQUIRED" == "$EXPECTED_REQUIRED" ]]; then
        _record_pass "input '$INPUT_NAME' required=$EXPECTED_REQUIRED"
    else
        _record_fail "input '$INPUT_NAME' required mismatch (expected: $EXPECTED_REQUIRED, got: $ACTUAL_REQUIRED_RAW)"
    fi

    if [[ "$EXPECTED_DEFAULT" != "__none__" ]]; then
        ACTUAL_DEFAULT="$(yaml_query ".inputs[\"$INPUT_NAME\"].default // \"__missing__\"" "$ACTION_YML")"
        if [[ "$ACTUAL_DEFAULT" == "__missing__" && "$EXPECTED_DEFAULT" != "" ]]; then
            _record_fail "input '$INPUT_NAME' default missing (expected: '$EXPECTED_DEFAULT')"
        elif [[ "$ACTUAL_DEFAULT" == "__missing__" && "$EXPECTED_DEFAULT" == "" ]]; then
            _record_fail "input '$INPUT_NAME' default missing (contract requires explicit default: \"\")"
        elif [[ "$ACTUAL_DEFAULT" == "$EXPECTED_DEFAULT" ]]; then
            _record_pass "input '$INPUT_NAME' default='$EXPECTED_DEFAULT'"
        else
            _record_fail "input '$INPUT_NAME' default mismatch (expected: '$EXPECTED_DEFAULT', got: '$ACTUAL_DEFAULT')"
        fi
    fi
done

test_case "required_outputs" "core-rolled-back, modal-rolled-back, db-rolled-back declared with non-empty descriptions and step-output values"
for OUTPUT_NAME in core-rolled-back modal-rolled-back db-rolled-back; do
    EXISTS="$(yaml_query "(.outputs[\"$OUTPUT_NAME\"] // null) | (. != null)" "$ACTION_YML")"
    if [[ "$EXISTS" == "true" ]]; then
        _record_pass "output '$OUTPUT_NAME' is declared"
    else
        _record_fail "output '$OUTPUT_NAME' is missing from outputs:"
        continue
    fi

    DESC="$(yaml_query ".outputs[\"$OUTPUT_NAME\"].description // \"\"" "$ACTION_YML")"
    if [[ -n "$DESC" && "$DESC" != "null" ]]; then
        _record_pass "output '$OUTPUT_NAME' has a non-empty description"
    else
        _record_fail "output '$OUTPUT_NAME' description missing or empty"
    fi

    VALUE="$(yaml_query ".outputs[\"$OUTPUT_NAME\"].value // \"\"" "$ACTION_YML")"
    if [[ "$VALUE" == \$\{\{*"steps."* ]]; then
        _record_pass "output '$OUTPUT_NAME' value references a step output (got: '$VALUE')"
    else
        _record_fail "output '$OUTPUT_NAME' value must reference a step output (\${{ steps.* }}, got: '$VALUE')"
    fi
done

test_case "step_ids_and_gating" "validate-inputs, run-rollback, log-audit, emit-outputs in order with correct if: gating"
STEP_IDS_JSON="$(yaml_query '[.runs.steps[]?.id // empty]' "$ACTION_YML")"
mapfile -t STEP_IDS < <(printf '%s' "$STEP_IDS_JSON" | jq -r '.[]?')

_idx_of() {
    local target="$1"
    local i
    for i in "${!STEP_IDS[@]}"; do
        if [[ "${STEP_IDS[$i]}" == "$target" ]]; then
            echo "$i"
            return 0
        fi
    done
    echo "-1"
}

IDX_VALIDATE="$(_idx_of validate-inputs)"
IDX_RUN="$(_idx_of run-rollback)"
IDX_AUDIT="$(_idx_of log-audit)"
IDX_EMIT="$(_idx_of emit-outputs)"

for pair in "validate-inputs:$IDX_VALIDATE" "run-rollback:$IDX_RUN" "log-audit:$IDX_AUDIT" "emit-outputs:$IDX_EMIT"; do
    STEP_NAME="${pair%%:*}"
    STEP_IDX="${pair##*:}"
    if [[ "$STEP_IDX" -ge 0 ]]; then
        _record_pass "step id '$STEP_NAME' present (index $STEP_IDX)"
    else
        _record_fail "step id '$STEP_NAME' missing from runs.steps"
    fi
done

if [[ "$IDX_VALIDATE" -ge 0 && "$IDX_RUN" -ge 0 && "$IDX_AUDIT" -ge 0 && "$IDX_EMIT" -ge 0 ]]; then
    if [[ "$IDX_VALIDATE" -lt "$IDX_RUN" \
        && "$IDX_RUN" -lt "$IDX_AUDIT" \
        && "$IDX_AUDIT" -lt "$IDX_EMIT" ]]; then
        _record_pass "step order: validate-inputs < run-rollback < log-audit < emit-outputs"
    else
        _record_fail "step order wrong (got: validate=$IDX_VALIDATE run=$IDX_RUN audit=$IDX_AUDIT emit=$IDX_EMIT)"
    fi
fi

AUDIT_IF="$(yaml_query '.runs.steps[]? | select(.id == "log-audit") | .if // ""' "$ACTION_YML")"
if [[ -z "$AUDIT_IF" || "$AUDIT_IF" == "null" ]]; then
    _record_fail "log-audit step must have a non-empty if: expression (got: empty)"
elif [[ "$AUDIT_IF" == *"success"* ]]; then
    _record_pass "log-audit step gates on success (if: $AUDIT_IF)"
else
    _record_fail "log-audit step's if: expression must reference success (got: '$AUDIT_IF')"
fi

EMIT_IF="$(yaml_query '.runs.steps[]? | select(.id == "emit-outputs") | .if // "__missing__"' "$ACTION_YML")"
if [[ "$EMIT_IF" == "__missing__" || "$EMIT_IF" == "null" || "$EMIT_IF" == "" ]]; then
    _record_pass "emit-outputs has no restrictive if: (will run unconditionally)"
elif [[ "$EMIT_IF" == *"always()"* ]]; then
    _record_pass "emit-outputs uses if: always() (got: '$EMIT_IF')"
else
    _record_fail "emit-outputs has a restrictive if: (must be missing or always(); got: '$EMIT_IF')"
fi

test_case "script_env_wiring" "run-rollback step env: maps every script env var to the correct input"
ENV_CONTRACT=(
    "CORE_APP|core-app"
    "CORE_PREV_IMAGE|core-prev-image"
    "MODAL_APP_NAME|modal-app"
    "MODAL_PREV_COMMIT|modal-prev-commit"
    "MODAL_TOKEN_ID|modal-token-id"
    "MODAL_TOKEN_SECRET|modal-token-secret"
    "FLY_API_TOKEN|fly-api-token"
    "ROLLBACK_REASON|rollback-reason"
    "ORIGIN_REMOTE|origin-remote"
    "NEON_PROJECT_ID|neon-project-id"
    "NEON_API_KEY|neon-api-key"
    "NEON_BRANCH_ID|neon-branch-id"
    "PRE_MIGRATE_LSN|pre-migrate-lsn"
)

for entry in "${ENV_CONTRACT[@]}"; do
    IFS='|' read -r ENV_VAR INPUT_NAME <<< "$entry"
    STEP_PRESENT="$(yaml_query '[.runs.steps[]? | select(.id == "run-rollback")] | length' "$ACTION_YML")"
    if [[ "$STEP_PRESENT" != "1" ]]; then
        _record_fail "run-rollback step missing — cannot check env wiring for '$ENV_VAR'"
        continue
    fi
    ACTUAL="$(yaml_query ".runs.steps[]? | select(.id == \"run-rollback\") | .env[\"$ENV_VAR\"] // \"__missing__\"" "$ACTION_YML")"
    if [[ "$ACTUAL" == "__missing__" || -z "$ACTUAL" ]]; then
        _record_fail "run-rollback env: missing key '$ENV_VAR' (should map to inputs.$INPUT_NAME)"
    elif [[ "$ACTUAL" == *"inputs.$INPUT_NAME"* ]]; then
        _record_pass "run-rollback env: $ENV_VAR -> inputs.$INPUT_NAME"
    else
        _record_fail "run-rollback env: '$ENV_VAR' wired wrong (expected: \${{ inputs.$INPUT_NAME }}, got: '$ACTUAL')"
    fi
done

RUN_BLOCK="$(yaml_query '.runs.steps[]? | select(.id == "run-rollback") | .run // ""' "$ACTION_YML")"
assert_contains "$RUN_BLOCK" "rollback-production.sh" \
    "run-rollback step's run: shells to scripts/rollback-production.sh"

test_case "audit_helper_invocation" "log-audit step invokes Stacks.Audit.log_rollback via mix run with DATABASE_URL + CLOAK_KEY in env"
AUDIT_RUN="$(yaml_query '.runs.steps[]? | select(.id == "log-audit") | .run // ""' "$ACTION_YML")"
assert_contains "$AUDIT_RUN" "Stacks.Audit.log_rollback" \
    "log-audit step's run: invokes Stacks.Audit.log_rollback"
assert_contains "$AUDIT_RUN" "mix run" \
    "log-audit step's run: uses 'mix run' (canonical invocation)"

AUDIT_STEP_PRESENT="$(yaml_query '[.runs.steps[]? | select(.id == "log-audit")] | length' "$ACTION_YML")"
for ENV_KEY in DATABASE_URL CLOAK_KEY; do
    if [[ "$AUDIT_STEP_PRESENT" != "1" ]]; then
        _record_fail "log-audit step missing — cannot check env wiring for '$ENV_KEY'"
        continue
    fi
    ACTUAL="$(yaml_query ".runs.steps[]? | select(.id == \"log-audit\") | .env[\"$ENV_KEY\"] // \"__missing__\"" "$ACTION_YML")"
    if [[ "$ACTUAL" == "__missing__" || -z "$ACTUAL" ]]; then
        _record_fail "log-audit env: missing key '$ENV_KEY'"
    else
        _record_pass "log-audit env: '$ENV_KEY' is wired (value: $ACTUAL)"
    fi
done

test_case "actionlint_clean" "actionlint passes on the workflow that consumes action.yml"
DEPLOY_YML="$REPO_ROOT/.github/workflows/deploy-production.yml"
if command -v actionlint >/dev/null 2>&1; then
    if [[ -f "$ACTION_YML" && -f "$DEPLOY_YML" ]]; then
        if ACTIONLINT_OUT="$(actionlint "$DEPLOY_YML" 2>&1)"; then
            _record_pass "actionlint passed on $DEPLOY_YML (validates composite action via uses:)"
        else
            _record_fail "actionlint failed: $ACTIONLINT_OUT"
        fi
    else
        _record_pass "actionlint skipped (action.yml not present yet — Case 1 covers existence)"
    fi
else
    _record_pass "actionlint not on PATH; skipped (Phase 5 adds it to CI)"
fi

summarise
