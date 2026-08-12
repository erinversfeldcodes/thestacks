#!/usr/bin/env bash
# test/platform/parse_rollback_output_test.sh
#
# Covers the grep-classification parser at
# `scripts/parse-rollback-output.sh`, which is invoked by the
# `emit-outputs` step of `.github/actions/rollback-production/action.yml`.
#
# The parser reads a single positional arg (path to the rollback output log)
# and writes three lines to stdout in `key=value` form:
#   core-rolled-back=<true|false|error>
#   modal-rolled-back=<true|false|error>
#   db-rolled-back=<true|false|error>
#
# The parser must:
#   - exit 0 always (parsing failure is signalled via output values)
#   - emit `error` for every leg when the log file does not exist
#   - use exact-string (`grep -F`) matching against marker substrings
#
# A separate "live marker check" iterates the marker list and verifies each
# pattern still appears verbatim in `scripts/rollback-production.sh` — this
# is the test that catches "someone changed a script marker without updating
# the parser".
#
# Will FAIL until `scripts/parse-rollback-output.sh` exists; the failure mode
# is `bash: .../parse-rollback-output.sh: No such file or directory` from
# `run_parser_with_fixture`. That's the equivalent of "function not found"
# in a Bash test suite.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib/assert.sh
source "$HERE/lib/assert.sh"

PARSER="$REPO_ROOT/scripts/parse-rollback-output.sh"
SCRIPT="$REPO_ROOT/scripts/rollback-production.sh"

OUT=""
RC=0

run_parser_with_fixture() {
    local fixture_content="$1"
    local fixture_file
    fixture_file=$(mktemp)
    printf '%s\n' "$fixture_content" > "$fixture_file"
    OUT="$(bash "$PARSER" "$fixture_file" 2>&1)"
    RC=$?
    rm -f "$fixture_file"
}

test_case "core_rolled_back_true" "PASS rollback: core rolled back → core-rolled-back=true"
run_parser_with_fixture "==> Rolling core back to image registry.fly.io/stacks-core:deployment-01abc...
PASS rollback: core rolled back"
assert_exit_zero "$RC" "parser exits 0"
assert_contains "$OUT" "core-rolled-back=true" "core-rolled-back=true emitted"

test_case "core_rolled_back_false" "==> core rollback skipped … → core-rolled-back=false"
run_parser_with_fixture "==> core rollback skipped — currently-serving image already matches abc123
    (migration-failure path: image was never cut over; DB + vision legs still run)"
assert_exit_zero "$RC" "parser exits 0"
assert_contains "$OUT" "core-rolled-back=false" "core-rolled-back=false emitted"

test_case "core_rolled_back_error" "FAIL rollback: fly deploy (core) failed → core-rolled-back=error"
run_parser_with_fixture "==> Rolling core back to image registry.fly.io/stacks-core:deployment-01abc...
FAIL rollback: fly deploy (core) failed — NOT attempting modal rollback"
assert_exit_zero "$RC" "parser exits 0"
assert_contains "$OUT" "core-rolled-back=error" "core-rolled-back=error emitted"

test_case "db_rolled_back_true" "PASS rollback: Neon prod branch restored … → db-rolled-back=true"
run_parser_with_fixture "PASS rollback: Neon prod branch restored to LSN 0/16E8090
  pre-rollback state preserved as branch: pre-rollback-deadbee-20260429T000000Z"
assert_exit_zero "$RC" "parser exits 0"
assert_contains "$OUT" "db-rolled-back=true" "db-rolled-back=true emitted"

test_case "db_rolled_back_false_skip" "WARN rollback: PRE_MIGRATE_LSN unset → db-rolled-back=false"
run_parser_with_fixture "WARN rollback: PRE_MIGRATE_LSN unset — skipping Neon DB rollback (image-only)"
assert_exit_zero "$RC" "parser exits 0"
assert_contains "$OUT" "db-rolled-back=false" "db-rolled-back=false emitted"

test_case "db_rolled_back_error_http" "FAIL rollback: Neon restore returned HTTP 500 → db-rolled-back=error"
run_parser_with_fixture "FAIL rollback: Neon restore returned HTTP 500"
assert_exit_zero "$RC" "parser exits 0"
assert_contains "$OUT" "db-rolled-back=error" "db-rolled-back=error emitted"

test_case "db_rolled_back_error_transport" "FAIL rollback: Neon restore curl call failed → db-rolled-back=error"
run_parser_with_fixture "FAIL rollback: Neon restore curl call failed (transport-level)"
assert_exit_zero "$RC" "parser exits 0"
assert_contains "$OUT" "db-rolled-back=error" "db-rolled-back=error emitted (transport-level FAIL form)"

test_case "modal_rolled_back_true" "PASS rollback: vision rolled back → modal-rolled-back=true"
run_parser_with_fixture "PASS rollback: vision rolled back to deadbeef"
assert_exit_zero "$RC" "parser exits 0"
assert_contains "$OUT" "modal-rolled-back=true" "modal-rolled-back=true emitted"

test_case "modal_rolled_back_false_skip" "WARN rollback: MODAL_PREV_COMMIT is unset → modal-rolled-back=false"
run_parser_with_fixture "WARN rollback: MODAL_PREV_COMMIT is unset — skipping modal vision rollback.
  Core is the critical path; vision rollback is partial-success here.
PASS rollback: core-only rollback complete (modal skipped)"
assert_exit_zero "$RC" "parser exits 0"
assert_contains "$OUT" "modal-rolled-back=false" "modal-rolled-back=false emitted"

test_case "modal_rolled_back_error_deploy" "FAIL rollback: modal deploy (vision rollback) failed → modal-rolled-back=error"
run_parser_with_fixture "FAIL rollback: modal deploy (vision rollback) failed at deadbeef"
assert_exit_zero "$RC" "parser exits 0"
assert_contains "$OUT" "modal-rolled-back=error" "modal-rolled-back=error emitted (deploy failure)"

test_case "modal_rolled_back_error_clone" "FAIL rollback: could not check out … → modal-rolled-back=error"
run_parser_with_fixture "FAIL rollback: could not check out deadbeef from origin"
assert_exit_zero "$RC" "parser exits 0"
assert_contains "$OUT" "modal-rolled-back=error" "modal-rolled-back=error emitted (clone failure)"

test_case "happy_path_full" "all three PASS markers present → all three outputs =true"
run_parser_with_fixture "==> Rolling back production core + vision
PASS rollback: core rolled back
PASS rollback: Neon prod branch restored to LSN 0/16E8090
  pre-rollback state preserved as branch: pre-rollback-deadbee-20260429T000000Z
PASS rollback: vision rolled back to deadbeefcafef00d"
assert_exit_zero "$RC" "parser exits 0"
assert_contains "$OUT" "core-rolled-back=true" "core-rolled-back=true on happy path"
assert_contains "$OUT" "db-rolled-back=true" "db-rolled-back=true on happy path"
assert_contains "$OUT" "modal-rolled-back=true" "modal-rolled-back=true on happy path"

test_case "migration_failure_path" "core skipped, db+modal succeed → core=false, db=true, modal=true"
run_parser_with_fixture "==> core rollback skipped — currently-serving image already matches abc123
PASS rollback: Neon prod branch restored to LSN 0/16E8090
  pre-rollback state preserved as branch: pre-rollback-deadbee-20260429T000000Z
PASS rollback: vision rolled back to deadbeefcafef00d"
assert_exit_zero "$RC" "parser exits 0"
assert_contains "$OUT" "core-rolled-back=false" "core-rolled-back=false on migration-failure path"
assert_contains "$OUT" "db-rolled-back=true" "db-rolled-back=true on migration-failure path"
assert_contains "$OUT" "modal-rolled-back=true" "modal-rolled-back=true on migration-failure path"

test_case "missing_log_file" "non-existent log path → all three legs =error, parser exits 0"
MISSING_LOG="/tmp/no-such-file-$$.log"
rm -f "$MISSING_LOG"
OUT="$(bash "$PARSER" "$MISSING_LOG" 2>&1)"
RC=$?
assert_exit_zero "$RC" "parser exits 0 even when log file does not exist (parse failure ≠ exit nonzero)"
assert_contains "$OUT" "core-rolled-back=error" "core-rolled-back=error on missing log"
assert_contains "$OUT" "modal-rolled-back=error" "modal-rolled-back=error on missing log"
assert_contains "$OUT" "db-rolled-back=error" "db-rolled-back=error on missing log"

test_case "live_marker_check" "every parser marker substring still appears verbatim in scripts/rollback-production.sh"
LIVE_MARKERS=(
    "PASS rollback: core rolled back"
    "core rollback skipped"
    "FAIL rollback: fly deploy (core) failed"
    "PASS rollback: Neon prod branch restored"
    "WARN rollback: PRE_MIGRATE_LSN unset"
    "FAIL rollback: Neon"
    "PASS rollback: vision rolled back"
    "WARN rollback: MODAL_PREV_COMMIT is unset"
    "FAIL rollback: modal deploy"
    "FAIL rollback: could not check out"
    "FAIL rollback: modal deploy stub"
)

for marker in "${LIVE_MARKERS[@]}"; do
    if grep -q -F -- "$marker" "$SCRIPT"; then
        _record_pass "marker '$marker' found in scripts/rollback-production.sh"
    else
        _record_fail "marker '$marker' NOT found in scripts/rollback-production.sh — update the parser or add the marker back"
    fi
done

summarise
