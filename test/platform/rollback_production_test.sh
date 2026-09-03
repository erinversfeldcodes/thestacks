#!/usr/bin/env bash
# test/platform/rollback_production_test.sh
#
# Covers Phase 3 DoD: "Rollback helper executes core-before-vision, verified
# against a forced-rollback fixture".
#
# The rollback helper must:
#   - take CORE_PREV_IMAGE and MODAL_PREV_COMMIT from env (or args — contract
#     TBD by implementer). Missing CORE_PREV_IMAGE → non-zero exit with a
#     clear error. Missing MODAL_PREV_COMMIT → proceed with core rollback,
#     warn about skipping modal.
#   - invoke `fly deploy --image <sha>` BEFORE `modal deploy`
#     (ordering rule from docs/runbooks/vision-service-rollback.md).
#   - if `fly deploy` fails, NOT attempt `modal deploy`.
#   - record the rollback reason to stdout (so CI logs capture it) and include
#     it in any emitted structured output.
#
# We shell out to `fly` and `modal` stubs placed at the front of PATH. Each
# stub logs its invocation to a file so the test can inspect order / args.
#
# Will FAIL until the rollback script is implemented — the stub exits 0 and
# does nothing, so the `fly` and `modal` invocation logs will be empty.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib/assert.sh
source "$HERE/lib/assert.sh"

ROLLBACK="$REPO_ROOT/scripts/rollback-production.sh"

STUB_DIR="$(mktemp -d)"
INVOCATION_LOG="$STUB_DIR/invocations.log"
trap 'rm -rf "$STUB_DIR"' EXIT

cat > "$STUB_DIR/fly" <<'STUB'
#!/usr/bin/env bash
echo "$(date +%s.%N) fly $*" >> "$INVOCATION_LOG"
if [[ "${1:-}" == "image" && "${2:-}" == "show" ]]; then
    printf '{"reference": "%s"}\n' "${FLY_CURRENT_IMAGE_STUB:-registry.fly.io/stacks-core:deployment-current-stub}"
    exit 0
fi
exit "${FLY_STUB_EXIT:-0}"
STUB
cat > "$STUB_DIR/modal" <<'STUB'
#!/usr/bin/env bash
echo "$(date +%s.%N) modal $*" >> "$INVOCATION_LOG"
exit "${MODAL_STUB_EXIT:-0}"
STUB
cat > "$STUB_DIR/curl" <<'STUB'
#!/usr/bin/env bash
echo "$(date +%s.%N) curl $*" >> "$INVOCATION_LOG"
_OUT_PATH=""
_BODY=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--data|--data-raw|--data-binary)
            _BODY="$2"
            shift 2
            ;;
        -o)
            _OUT_PATH="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done
if [[ -n "$_BODY" ]]; then
    printf 'BODY: %s\n' "$_BODY" >> "$INVOCATION_LOG"
fi
if [[ -n "$_OUT_PATH" ]]; then
    printf '{}' > "$_OUT_PATH" 2>/dev/null || true
fi
printf '200'
exit "${CURL_STUB_EXIT:-0}"
STUB
chmod +x "$STUB_DIR/fly" "$STUB_DIR/modal" "$STUB_DIR/curl"

export PATH="$STUB_DIR:$PATH"
export INVOCATION_LOG

# Every case below states the variables it wants as prefix assignments, so
# anything inherited from the caller is contamination. That matters now the
# suite runs from `scripts/ci.sh`, which sources `.env` first: a developer with
# a real NEON_API_KEY in `.env` would hand this suite a key the
# missing-Neon-var cases assume is absent, and those cases would assert
# fail-fast behaviour against an input that is not missing at all.
unset CORE_PREV_IMAGE MODAL_PREV_COMMIT ROLLBACK_REASON PRE_MIGRATE_LSN
unset NEON_API_KEY NEON_PROJECT_ID NEON_BRANCH_ID GITHUB_SHA
unset CORE_APP MODAL_APP_NAME ORIGIN_REMOTE
unset FLY_CURRENT_IMAGE_STUB FLY_STUB_EXIT MODAL_STUB_EXIT CURL_STUB_EXIT

run_rollback() {
    : > "$INVOCATION_LOG"
    OUT="$("$ROLLBACK" "$@" 2>&1)"
    RC=$?
}

test_case "happy_path_order" "CORE_PREV_IMAGE + MODAL_PREV_COMMIT → core deploy before modal deploy"
CORE_PREV_IMAGE="registry.fly.io/stacks-core:deployment-01abc" \
MODAL_PREV_COMMIT="deadbeefcafef00d" \
ROLLBACK_REASON="SLO breach: upload p95 > 2000ms" \
    run_rollback
assert_exit_zero "$RC" "rollback exits 0 when both stubs succeed"
assert_contains "$OUT" "SLO breach" "rollback reason is echoed to stdout"
FLY_LINE=$(grep -n ' fly ' "$INVOCATION_LOG" | head -1 | cut -d: -f1 || echo 0)
MODAL_LINE=$(grep -n ' modal ' "$INVOCATION_LOG" | head -1 | cut -d: -f1 || echo 0)
if [[ "$FLY_LINE" -gt 0 && "$MODAL_LINE" -gt 0 && "$FLY_LINE" -lt "$MODAL_LINE" ]]; then
    _record_pass "fly invoked before modal (fly line $FLY_LINE < modal line $MODAL_LINE)"
else
    _record_fail "fly/modal ordering incorrect (fly=$FLY_LINE modal=$MODAL_LINE, log=$(cat "$INVOCATION_LOG"))"
fi
assert_contains "$(cat "$INVOCATION_LOG")" "deployment-01abc" "fly deploy carries the prev image sha"
assert_contains "$(cat "$INVOCATION_LOG")" "deadbeef" "modal deploy carries the prev commit"

# The rollback must deploy the old image WITHOUT the current release_command —
# the old image may not implement it (a real rollback aborted on
# UndefinedFunctionError for exactly this). Assert the deploy passes an
# explicit config and that the config carries no release_command.
assert_contains "$(cat "$INVOCATION_LOG")" "--config" "fly deploy passes an explicit rollback config"
ROLLBACK_CFG=$(grep -o '\-\-config [^ ]*' "$INVOCATION_LOG" | head -1 | awk '{print $2}')
if [[ -n "$ROLLBACK_CFG" && -f "$ROLLBACK_CFG" ]] && ! grep -q 'release_command' "$ROLLBACK_CFG"; then
    _record_pass "rollback config exists and strips release_command"
else
    _record_fail "rollback config missing or still carries release_command (cfg=$ROLLBACK_CFG)"
fi

test_case "missing_core_prev_image" "no CORE_PREV_IMAGE → exit non-zero with clear error"
unset CORE_PREV_IMAGE
MODAL_PREV_COMMIT="deadbeefcafef00d" \
ROLLBACK_REASON="test" \
    run_rollback
assert_exit_nonzero "$RC" "rollback exits non-zero without CORE_PREV_IMAGE"
assert_contains "$OUT" "CORE_PREV_IMAGE" "error message names the missing variable"

test_case "missing_modal_prev_commit" "no MODAL_PREV_COMMIT → core rolls back, modal skipped with warning"
CORE_PREV_IMAGE="registry.fly.io/stacks-core:deployment-01abc" \
ROLLBACK_REASON="test" \
    run_rollback
assert_exit_zero "$RC" "rollback still exits 0 when only modal is missing"
assert_contains "$(cat "$INVOCATION_LOG")" "fly" "fly deploy ran against core"
if grep -q ' modal ' "$INVOCATION_LOG"; then
    _record_fail "modal was invoked despite missing MODAL_PREV_COMMIT"
else
    _record_pass "modal was NOT invoked (correct — MODAL_PREV_COMMIT unset)"
fi
assert_contains "$OUT" "MODAL_PREV_COMMIT" "output warns about the missing modal commit"

test_case "fly_fail_halts_pipeline" "fly deploy failure halts before modal deploy"
CORE_PREV_IMAGE="registry.fly.io/stacks-core:deployment-01abc" \
MODAL_PREV_COMMIT="deadbeefcafef00d" \
ROLLBACK_REASON="test" \
FLY_STUB_EXIT=1 \
    run_rollback
assert_exit_nonzero "$RC" "rollback exits non-zero when fly deploy fails"
if grep -q ' modal ' "$INVOCATION_LOG"; then
    _record_fail "modal was invoked even though fly deploy failed (ordering safety violation)"
else
    _record_pass "modal was NOT invoked after fly deploy failure"
fi

test_case "lsn_restore_happy_path" "PRE_MIGRATE_LSN set → core deploy, Neon restore, then modal"
CORE_PREV_IMAGE="registry.fly.io/stacks-core:deployment-01abc" \
MODAL_PREV_COMMIT="deadbeefcafef00d" \
ROLLBACK_REASON="SLO breach: LSN restore happy path" \
PRE_MIGRATE_LSN="0/16E8090" \
NEON_PROJECT_ID="stale-cherry-12345" \
NEON_API_KEY="neon_api_xxx" \
NEON_BRANCH_ID="br-prod-default-uuid" \
GITHUB_SHA="deadbeefcafebabe1234567890abcdef12345678" \
    run_rollback
assert_exit_zero "$RC" "rollback exits 0 when fly + curl + modal all succeed"

FLY_LINE=$(grep -n ' fly deploy ' "$INVOCATION_LOG" | head -1 | cut -d: -f1 || echo 0)
CURL_LINE=$(grep -n ' curl ' "$INVOCATION_LOG" | head -1 | cut -d: -f1 || echo 0)
MODAL_LINE=$(grep -n ' modal ' "$INVOCATION_LOG" | head -1 | cut -d: -f1 || echo 0)
if [[ "$FLY_LINE" -gt 0 && "$CURL_LINE" -gt 0 && "$MODAL_LINE" -gt 0 \
      && "$FLY_LINE" -lt "$CURL_LINE" && "$CURL_LINE" -lt "$MODAL_LINE" ]]; then
    _record_pass "fly($FLY_LINE) < curl($CURL_LINE) < modal($MODAL_LINE) — ordering correct"
else
    _record_fail "ordering wrong (fly=$FLY_LINE curl=$CURL_LINE modal=$MODAL_LINE, log=$(cat "$INVOCATION_LOG"))"
fi

LOG_CONTENTS="$(cat "$INVOCATION_LOG")"
assert_contains "$LOG_CONTENTS" "console.neon.tech/api/v2/projects/stale-cherry-12345/branches/br-prod-default-uuid/restore" \
    "curl URL targets the Neon restore endpoint with project_id + branch_id"

assert_contains "$LOG_CONTENTS" "Authorization: Bearer neon_api_xxx" \
    "curl carries the Authorization: Bearer header with the API key"

BODY_LINE="$(grep '^BODY: ' "$INVOCATION_LOG" | head -1 || true)"
assert_contains "$BODY_LINE" "source_branch_id" \
    "request body names source_branch_id (self-restore)"
assert_contains "$BODY_LINE" "br-prod-default-uuid" \
    "request body's source_branch_id is the prod branch (self-restore)"
assert_contains "$BODY_LINE" "0/16E8090" \
    "request body's source_lsn matches PRE_MIGRATE_LSN"
assert_contains "$BODY_LINE" "preserve_under_name" \
    "request body names preserve_under_name (required by Neon for self-restore)"
assert_contains "$BODY_LINE" "pre-rollback-deadbee-" \
    "preserve_under_name is prefixed with pre-rollback-<short-sha>- (first 7 chars of GITHUB_SHA)"

assert_contains "$OUT" "PASS rollback: Neon prod branch restored" \
    "stdout shows PASS rollback: Neon prod branch restored"
assert_contains "$OUT" "pre-rollback state preserved as branch:" \
    "stdout surfaces the preserved-branch name for operator inspection"

test_case "lsn_restore_without_github_sha" \
    "operator-run rollback (no GITHUB_SHA) still restores the DB — must not abort between the core and DB legs"
CORE_PREV_IMAGE="registry.fly.io/stacks-core:deployment-01abc" \
MODAL_PREV_COMMIT="deadbeefcafef00d" \
ROLLBACK_REASON="operator-run rollback, no workflow context" \
PRE_MIGRATE_LSN="0/16E8090" \
NEON_PROJECT_ID="stale-cherry-12345" \
NEON_API_KEY="neon_api_xxx" \
NEON_BRANCH_ID="br-prod-default-uuid" \
    run_rollback
assert_exit_zero "$RC" "rollback exits 0 when GITHUB_SHA is unset (runbook path, not a workflow)"
if grep -q ' curl ' "$INVOCATION_LOG"; then
    _record_pass "Neon restore still ran without GITHUB_SHA (core and DB legs stay in step)"
else
    _record_fail "core was rolled back but the Neon restore never ran — production left on old code against new schema"
fi
if grep -q ' modal ' "$INVOCATION_LOG"; then
    _record_pass "modal rollback still ran without GITHUB_SHA"
else
    _record_fail "modal rollback never ran without GITHUB_SHA"
fi
assert_not_contains "$OUT" "unbound variable" \
    "no unbound-variable abort partway through the rollback"
assert_contains "$(grep '^BODY: ' "$INVOCATION_LOG" | head -1 || true)" "pre-rollback-manual-" \
    "preserve_under_name falls back to the 'manual' tag when there is no workflow sha"

test_case "lsn_unset_skips_db_rollback" "PRE_MIGRATE_LSN empty → WARN, no curl, fly + modal still run"
CORE_PREV_IMAGE="registry.fly.io/stacks-core:deployment-01abc" \
MODAL_PREV_COMMIT="deadbeefcafef00d" \
ROLLBACK_REASON="LSN-unset bootstrap path" \
PRE_MIGRATE_LSN="" \
    run_rollback
assert_exit_zero "$RC" "rollback still exits 0 when LSN unset (skip is a designed branch)"
if grep -q ' curl ' "$INVOCATION_LOG"; then
    _record_fail "curl was invoked despite empty PRE_MIGRATE_LSN (DB rollback should be skipped)"
else
    _record_pass "curl was NOT invoked (DB rollback correctly skipped)"
fi
assert_contains "$(cat "$INVOCATION_LOG")" "fly deploy" \
    "fly deploy still invoked (image rollback unaffected by LSN skip)"
assert_contains "$(cat "$INVOCATION_LOG")" "modal" \
    "modal deploy still invoked (vision rollback unaffected by LSN skip)"
assert_contains "$OUT" "WARN rollback: PRE_MIGRATE_LSN unset" \
    "stdout/stderr surfaces a WARN about the skipped DB rollback"

test_case "migration_failure_skips_core_runs_neon" "currently-serving == CORE_PREV_IMAGE → skip fly deploy, still run Neon + modal"
CORE_PREV_IMAGE="registry.fly.io/stacks-core:deployment-01abc" \
MODAL_PREV_COMMIT="deadbeefcafef00d" \
ROLLBACK_REASON="migration failure: schema half-applied" \
PRE_MIGRATE_LSN="0/16E8090" \
NEON_PROJECT_ID="stale-cherry-12345" \
NEON_API_KEY="neon_api_xxx" \
NEON_BRANCH_ID="br-prod-default-uuid" \
GITHUB_SHA="deadbeefcafebabe1234567890abcdef12345678" \
FLY_CURRENT_IMAGE_STUB="registry.fly.io/stacks-core:deployment-01abc" \
    run_rollback
assert_exit_zero "$RC" "rollback exits 0 on the migration-failure branch (skip-core, run-DB, run-vision)"

if grep -q ' fly deploy ' "$INVOCATION_LOG"; then
    _record_fail "fly deploy was invoked despite currently-serving image already matching CORE_PREV_IMAGE"
else
    _record_pass "fly deploy was NOT invoked (correctly skipped — image unchanged)"
fi

assert_contains "$OUT" "core rollback skipped" \
    "stdout announces 'core rollback skipped' on the migration-failure branch"

if grep -q ' curl ' "$INVOCATION_LOG"; then
    _record_pass "curl to Neon WAS invoked (DB rollback fires even when core image is unchanged)"
else
    _record_fail "curl to Neon was NOT invoked (migration-failure path must still reset the LSN)"
fi
assert_contains "$(cat "$INVOCATION_LOG")" "console.neon.tech/api/v2/projects/stale-cherry-12345/branches/br-prod-default-uuid/restore" \
    "Neon restore URL is well-formed on the migration-failure branch"

assert_contains "$(cat "$INVOCATION_LOG")" "modal" \
    "modal deploy still invoked (vision rollback independent of image state)"

test_case "neon_failure_halts_rollback" "curl failure on Neon restore → non-zero exit, modal not invoked"
CORE_PREV_IMAGE="registry.fly.io/stacks-core:deployment-01abc" \
MODAL_PREV_COMMIT="deadbeefcafef00d" \
ROLLBACK_REASON="Neon API failure test" \
PRE_MIGRATE_LSN="0/16E8090" \
NEON_PROJECT_ID="stale-cherry-12345" \
NEON_API_KEY="neon_api_xxx" \
NEON_BRANCH_ID="br-prod-default-uuid" \
GITHUB_SHA="deadbeefcafebabe1234567890abcdef12345678" \
CURL_STUB_EXIT=22 \
    run_rollback
assert_exit_nonzero "$RC" "rollback exits non-zero when Neon restore fails"
if grep -q ' curl ' "$INVOCATION_LOG"; then
    _record_pass "curl WAS invoked (the failure occurred on the Neon call as expected)"
else
    _record_fail "curl was NOT invoked (test setup wrong — should still attempt the call)"
fi
if grep -q ' modal ' "$INVOCATION_LOG"; then
    _record_fail "modal was invoked despite Neon restore failure (ordering safety violation — schema state unknown)"
else
    _record_pass "modal was NOT invoked after Neon restore failure (correct halt)"
fi
assert_contains "$OUT" "FAIL rollback: Neon restore" \
    "stdout/stderr includes a FAIL rollback: Neon restore error line"

test_case "missing_neon_api_key_fails_fast" "PRE_MIGRATE_LSN set + NEON_API_KEY unset → exit non-zero before any rollback"
CORE_PREV_IMAGE="registry.fly.io/stacks-core:deployment-01abc" \
MODAL_PREV_COMMIT="deadbeefcafef00d" \
ROLLBACK_REASON="missing Neon API key validation test" \
PRE_MIGRATE_LSN="0/16E8090" \
NEON_PROJECT_ID="stale-cherry-12345" \
NEON_BRANCH_ID="br-prod-default-uuid" \
    run_rollback
assert_exit_nonzero "$RC" "rollback exits non-zero when NEON_API_KEY is unset"
assert_contains "$OUT" "NEON_API_KEY" \
    "error message names the missing variable (NEON_API_KEY)"
if grep -q ' fly deploy ' "$INVOCATION_LOG"; then
    _record_fail "fly deploy was invoked before validation failure (must validate before any rollback work)"
else
    _record_pass "fly deploy was NOT invoked (validation failed fast as required)"
fi
if grep -q ' curl ' "$INVOCATION_LOG"; then
    _record_fail "curl was invoked before validation failure (must validate before any rollback work)"
else
    _record_pass "curl was NOT invoked (validation failed fast as required)"
fi
if grep -q ' modal ' "$INVOCATION_LOG"; then
    _record_fail "modal was invoked before validation failure (must validate before any rollback work)"
else
    _record_pass "modal was NOT invoked (validation failed fast as required)"
fi

summarise
