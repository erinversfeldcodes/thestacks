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
# Exit code controlled by FLY_STUB_EXIT env var (default 0).
exit "${FLY_STUB_EXIT:-0}"
STUB
cat > "$STUB_DIR/modal" <<'STUB'
#!/usr/bin/env bash
echo "$(date +%s.%N) modal $*" >> "$INVOCATION_LOG"
exit "${MODAL_STUB_EXIT:-0}"
STUB
chmod +x "$STUB_DIR/fly" "$STUB_DIR/modal"

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

summarise
