#!/usr/bin/env bash
# test/platform/schema_diff_test.sh
#
# Covers DoD: "Schema diff step fails on DROP/ALTER TYPE/RENAME without
# `db-breaking` PR label; passes with it".
#
# The check script accepts two structure.sql paths (BEFORE, AFTER) and must:
#   - exit 0 on purely additive diffs.
#   - exit non-zero when a column disappears (DROP) or gets a new name (RENAME
#     — indistinguishable at structure.sql level from drop+add).
#   - print a descriptive message naming the affected column.
#   - exit 0 regardless of diff content when DB_BREAKING_LABEL=true is in the
#     environment (simulates the `db-breaking` PR label bypass in CI).
#
# Will FAIL until Phase 2 implements scripts/check-schema-diff.sh. The stub
# `exit 0` makes the benign diffs pass trivially but the destructive diffs
# fail their non-zero assertion.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib/assert.sh
source "$HERE/lib/assert.sh"

CHECKER="$REPO_ROOT/scripts/check-schema-diff.sh"
FIXTURES="$REPO_ROOT/test/fixtures/schema"

run_checker() {
    unset DB_BREAKING_LABEL
    OUT=$("$CHECKER" "$@" 2>&1)
    RC=$?
}

run_checker_with_label() {
    OUT=$(DB_BREAKING_LABEL=true "$CHECKER" "$@" 2>&1)
    RC=$?
}

test_case "benign_diff" "additive-only structure diff exits 0"
run_checker "$FIXTURES/before_benign.dump" "$FIXTURES/after_benign.dump"
assert_exit_zero "$RC" "benign diff passes without label"

test_case "drop_diff" "diff dropping a column exits non-zero and names it"
run_checker "$FIXTURES/before_drop.dump" "$FIXTURES/after_drop.dump"
assert_exit_nonzero "$RC" "drop diff exits non-zero without db-breaking label"
assert_contains "$OUT" "cover_image_url" \
    "output names the removed column so reviewers know what broke"

test_case "rename_diff" "diff renaming a column is flagged as destructive"
run_checker "$FIXTURES/before_rename.dump" "$FIXTURES/after_rename.dump"
assert_exit_nonzero "$RC" "rename diff exits non-zero without db-breaking label"
assert_contains "$OUT" "cover_image_url" \
    "output mentions the vanished column name"

test_case "drop_diff_with_label" "DB_BREAKING_LABEL=true allows destructive diffs"
run_checker_with_label "$FIXTURES/before_drop.dump" "$FIXTURES/after_drop.dump"
assert_exit_zero "$RC" "drop diff with DB_BREAKING_LABEL=true exits 0"

test_case "rename_diff_with_label" "DB_BREAKING_LABEL=true also bypasses rename check"
run_checker_with_label "$FIXTURES/before_rename.dump" "$FIXTURES/after_rename.dump"
assert_exit_zero "$RC" "rename diff with DB_BREAKING_LABEL=true exits 0"

test_case "benign_diff_with_label" "label doesn't break benign case"
run_checker_with_label "$FIXTURES/before_benign.dump" "$FIXTURES/after_benign.dump"
assert_exit_zero "$RC" "benign diff with label still exits 0"

test_case "enum_drop" "removing an enum value is flagged as destructive"
run_checker "$FIXTURES/before_enum_drop.dump" "$FIXTURES/after_enum_drop.dump"
assert_exit_nonzero "$RC" "enum-drop diff exits non-zero without db-breaking label"
assert_contains "$OUT" "looking_for_home" \
    "output names the removed enum value"

test_case "enum_drop_with_label" "DB_BREAKING_LABEL=true allows enum value drops"
run_checker_with_label "$FIXTURES/before_enum_drop.dump" "$FIXTURES/after_enum_drop.dump"
assert_exit_zero "$RC" "enum-drop diff with DB_BREAKING_LABEL=true exits 0"

test_case "real_baseline_self_diff" "real-main structure dumped by mix ecto.dump yields no findings when diffed against itself"
run_checker "$FIXTURES/real_main_baseline.dump" "$FIXTURES/real_main_baseline.dump"
assert_exit_zero "$RC" "real baseline self-diff exits 0 (no false positives)"

summarise
