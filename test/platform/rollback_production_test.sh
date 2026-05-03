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

# ── Stub directory: fake `fly` and `modal` commands that log invocations ────
STUB_DIR="$(mktemp -d)"
INVOCATION_LOG="$STUB_DIR/invocations.log"
trap 'rm -rf "$STUB_DIR"' EXIT

cat > "$STUB_DIR/fly" <<'STUB'
#!/usr/bin/env bash
echo "$(date +%s.%N) fly $*" >> "$INVOCATION_LOG"
# Sub-command dispatch: `fly image show ...` is used by the rollback script
# to detect the currently-serving image (migration-failure path). Emit a JSON
# blob so the script's parser sees a deterministic image reference. The SHA
# emitted is controlled by FLY_CURRENT_IMAGE_STUB; when unset we default to
# a value that intentionally does NOT match any plausible CORE_PREV_IMAGE so
# pre-existing tests stay on the "core rollback proceeds normally" branch.
if [[ "${1:-}" == "image" && "${2:-}" == "show" ]]; then
    printf '{"reference": "%s"}\n' "${FLY_CURRENT_IMAGE_STUB:-registry.fly.io/stacks-core:deployment-current-stub}"
    # `fly image show` is read-only — never honour FLY_STUB_EXIT, so a
    # forced fly-deploy failure (Case 4) doesn't accidentally fail the
    # currently-serving lookup as well.
    exit 0
fi
# Exit code controlled by FLY_STUB_EXIT env var (default 0).
exit "${FLY_STUB_EXIT:-0}"
STUB
cat > "$STUB_DIR/modal" <<'STUB'
#!/usr/bin/env bash
echo "$(date +%s.%N) modal $*" >> "$INVOCATION_LOG"
exit "${MODAL_STUB_EXIT:-0}"
STUB
# curl stub for the Neon restore POST. The production script will invoke
# curl with -w "%{http_code}" and -o <path> capturing the response body.
# Strategy: the stub writes "200" (or "201") to stdout for the http_code
# capture, writes a fixed JSON blob to the -o path so any downstream parse
# step succeeds, and exits with $CURL_STUB_EXIT (default 0). Setting
# CURL_STUB_EXIT=22 simulates a curl-level transport failure (per the
# `--fail`/`-f` curl convention, exit 22 = HTTP 4xx/5xx). The full
# invocation (including -d body) is captured to INVOCATION_LOG so tests
# can assert on URL, headers, and JSON body shape via grep.
cat > "$STUB_DIR/curl" <<'STUB'
#!/usr/bin/env bash
echo "$(date +%s.%N) curl $*" >> "$INVOCATION_LOG"
# Walk argv to find the -d / --data body (locks the request shape so tests
# can assert on source_branch_id, source_lsn, preserve_under_name).
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
# stdout = http_code (matches `curl -w "%{http_code}" -o <path>` shape).
printf '200'
exit "${CURL_STUB_EXIT:-0}"
STUB
chmod +x "$STUB_DIR/fly" "$STUB_DIR/modal" "$STUB_DIR/curl"

# Prepend stubs to PATH so the helper picks them up.
export PATH="$STUB_DIR:$PATH"
export INVOCATION_LOG

run_rollback() {
    : > "$INVOCATION_LOG"
    OUT="$("$ROLLBACK" "$@" 2>&1)"
    RC=$?
}

# ── Case 1: happy path, both env vars set → core first, then modal ───────────
test_case "happy_path_order" "CORE_PREV_IMAGE + MODAL_PREV_COMMIT → core deploy before modal deploy"
CORE_PREV_IMAGE="registry.fly.io/stacks-core:deployment-01abc" \
MODAL_PREV_COMMIT="deadbeefcafef00d" \
ROLLBACK_REASON="SLO breach: upload p95 > 2000ms" \
    run_rollback
assert_exit_zero "$RC" "rollback exits 0 when both stubs succeed"
assert_contains "$OUT" "SLO breach" "rollback reason is echoed to stdout"
# Inspect invocation log: fly must appear BEFORE modal.
FLY_LINE=$(grep -n ' fly ' "$INVOCATION_LOG" | head -1 | cut -d: -f1 || echo 0)
MODAL_LINE=$(grep -n ' modal ' "$INVOCATION_LOG" | head -1 | cut -d: -f1 || echo 0)
if [[ "$FLY_LINE" -gt 0 && "$MODAL_LINE" -gt 0 && "$FLY_LINE" -lt "$MODAL_LINE" ]]; then
    _record_pass "fly invoked before modal (fly line $FLY_LINE < modal line $MODAL_LINE)"
else
    _record_fail "fly/modal ordering incorrect (fly=$FLY_LINE modal=$MODAL_LINE, log=$(cat "$INVOCATION_LOG"))"
fi
assert_contains "$(cat "$INVOCATION_LOG")" "deployment-01abc" "fly deploy carries the prev image sha"
assert_contains "$(cat "$INVOCATION_LOG")" "deadbeef" "modal deploy carries the prev commit"

# ── Case 2: missing CORE_PREV_IMAGE → non-zero, clear error ──────────────────
test_case "missing_core_prev_image" "no CORE_PREV_IMAGE → exit non-zero with clear error"
unset CORE_PREV_IMAGE
MODAL_PREV_COMMIT="deadbeefcafef00d" \
ROLLBACK_REASON="test" \
    run_rollback
assert_exit_nonzero "$RC" "rollback exits non-zero without CORE_PREV_IMAGE"
assert_contains "$OUT" "CORE_PREV_IMAGE" "error message names the missing variable"

# ── Case 3: missing MODAL_PREV_COMMIT → core rolls back, modal skipped ───────
test_case "missing_modal_prev_commit" "no MODAL_PREV_COMMIT → core rolls back, modal skipped with warning"
CORE_PREV_IMAGE="registry.fly.io/stacks-core:deployment-01abc" \
ROLLBACK_REASON="test" \
    run_rollback
# Exit code: must succeed (or at least not hard-fail on missing modal only —
# core was the critical step). Assert fly was invoked but modal was not.
assert_exit_zero "$RC" "rollback still exits 0 when only modal is missing"
assert_contains "$(cat "$INVOCATION_LOG")" "fly" "fly deploy ran against core"
if grep -q ' modal ' "$INVOCATION_LOG"; then
    _record_fail "modal was invoked despite missing MODAL_PREV_COMMIT"
else
    _record_pass "modal was NOT invoked (correct — MODAL_PREV_COMMIT unset)"
fi
assert_contains "$OUT" "MODAL_PREV_COMMIT" "output warns about the missing modal commit"

# ── Case 4: fly deploy fails → do NOT invoke modal ───────────────────────────
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

# ── Case 5: happy-path with LSN → core, then Neon restore, then modal ────────
# Locks the Phase 2 wire shape: between the existing core rollback and modal
# rollback, the script must POST to Neon's branches/{id}/restore endpoint with
# {source_branch_id (self), source_lsn, preserve_under_name: pre-rollback-<sha7>-<ts>}
# and then proceed to vision rollback. Ordering: fly < curl < modal.
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

# Ordering: fly invoked BEFORE curl BEFORE modal in the invocation log.
FLY_LINE=$(grep -n ' fly deploy ' "$INVOCATION_LOG" | head -1 | cut -d: -f1 || echo 0)
CURL_LINE=$(grep -n ' curl ' "$INVOCATION_LOG" | head -1 | cut -d: -f1 || echo 0)
MODAL_LINE=$(grep -n ' modal ' "$INVOCATION_LOG" | head -1 | cut -d: -f1 || echo 0)
if [[ "$FLY_LINE" -gt 0 && "$CURL_LINE" -gt 0 && "$MODAL_LINE" -gt 0 \
      && "$FLY_LINE" -lt "$CURL_LINE" && "$CURL_LINE" -lt "$MODAL_LINE" ]]; then
    _record_pass "fly($FLY_LINE) < curl($CURL_LINE) < modal($MODAL_LINE) — ordering correct"
else
    _record_fail "ordering wrong (fly=$FLY_LINE curl=$CURL_LINE modal=$MODAL_LINE, log=$(cat "$INVOCATION_LOG"))"
fi

# Neon URL must contain project_id and branch_id from env.
LOG_CONTENTS="$(cat "$INVOCATION_LOG")"
assert_contains "$LOG_CONTENTS" "console.neon.tech/api/v2/projects/stale-cherry-12345/branches/br-prod-default-uuid/restore" \
    "curl URL targets the Neon restore endpoint with project_id + branch_id"

# Authorization header carries the API key.
assert_contains "$LOG_CONTENTS" "Authorization: Bearer neon_api_xxx" \
    "curl carries the Authorization: Bearer header with the API key"

# JSON body must contain self-restore source_branch_id, the LSN, and a
# preserve_under_name prefixed pre-rollback-<sha7>-.
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

# Stdout must mark the Neon step as PASS and surface the preserved-branch name.
assert_contains "$OUT" "PASS rollback: Neon prod branch restored" \
    "stdout shows PASS rollback: Neon prod branch restored"
assert_contains "$OUT" "pre-rollback state preserved as branch:" \
    "stdout surfaces the preserved-branch name for operator inspection"

# ── Case 6: empty PRE_MIGRATE_LSN → skip DB rollback with WARN ───────────────
# Bootstrap / operator-suppressed path: when PRE_MIGRATE_LSN is empty, the
# script must NOT attempt a Neon restore (no curl), but core + modal rollback
# must still proceed. The existing 4 cases already exercise this path
# implicitly — this test makes the WARN and the no-curl invariant explicit.
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

# ── Case 7: migration-failure path → image unchanged → skip core, run Neon ───
# When a migration failed before the deploy step, the currently-serving Fly
# image is still CORE_PREV_IMAGE. The script must detect this via
# `fly image show` and skip `fly deploy --image` (it would be a no-op anyway
# but the audit trail is cleaner without the extra cutover line). Neon
# restore is exactly the case where Postgres-level rollback earns its keep —
# it must still fire. Modal is independent of the image state.
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

# `fly deploy` must NOT be invoked — the `fly image show` lookup may still
# happen (that's the detection mechanism), but the actual cutover is skipped.
if grep -q ' fly deploy ' "$INVOCATION_LOG"; then
    _record_fail "fly deploy was invoked despite currently-serving image already matching CORE_PREV_IMAGE"
else
    _record_pass "fly deploy was NOT invoked (correctly skipped — image unchanged)"
fi

# Stdout must announce the skip clearly (so operators reading Actions logs
# can distinguish this branch from a normal rollback).
assert_contains "$OUT" "core rollback skipped" \
    "stdout announces 'core rollback skipped' on the migration-failure branch"

# Neon restore still fires.
if grep -q ' curl ' "$INVOCATION_LOG"; then
    _record_pass "curl to Neon WAS invoked (DB rollback fires even when core image is unchanged)"
else
    _record_fail "curl to Neon was NOT invoked (migration-failure path must still reset the LSN)"
fi
assert_contains "$(cat "$INVOCATION_LOG")" "console.neon.tech/api/v2/projects/stale-cherry-12345/branches/br-prod-default-uuid/restore" \
    "Neon restore URL is well-formed on the migration-failure branch"

# Modal still rolls back (independent of image state).
assert_contains "$(cat "$INVOCATION_LOG")" "modal" \
    "modal deploy still invoked (vision rollback independent of image state)"

# ── Case 8: Neon API failure halts the rollback before vision ────────────────
# A failed DB restore is unsafe to ignore — the schema/data is in an unknown
# state. The script must exit non-zero AND must NOT proceed to modal (the
# vision sidecar's wire format depends on the schema version, and we can't
# verify which schema is now serving).
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

# ── Case 9: missing NEON_API_KEY when LSN is set → fail-fast ────────────
# When PRE_MIGRATE_LSN is set, the three Neon vars (PROJECT_ID, API_KEY,
# BRANCH_ID) are required. Validate-fast: error before any rollback work
# starts so we don't half-roll-back the image and then realise we can't
# restore the DB. We lock NEON_API_KEY here as the canonical case;
# implementer should apply the same shape to PROJECT_ID and BRANCH_ID.
test_case "missing_neon_api_key_fails_fast" "PRE_MIGRATE_LSN set + NEON_API_KEY unset → exit non-zero before any rollback"
CORE_PREV_IMAGE="registry.fly.io/stacks-core:deployment-01abc" \
MODAL_PREV_COMMIT="deadbeefcafef00d" \
ROLLBACK_REASON="missing Neon API key validation test" \
PRE_MIGRATE_LSN="0/16E8090" \
NEON_PROJECT_ID="stale-cherry-12345" \
NEON_BRANCH_ID="br-prod-default-uuid" \
    run_rollback
# NEON_API_KEY explicitly NOT set above ↑
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
