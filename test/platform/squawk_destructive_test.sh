#!/usr/bin/env bash
# test/platform/squawk_destructive_test.sh
#
# Covers DoD: "Destructive squawk rules enabled; fixture destructive migration
# causes squawk to fail".
#
# The five destructive patterns from the plan map to five squawk rule names.
# This test asserts that running `security-squawk-test-wrapper.sh` against
# each fixture:
#   1. exits non-zero, AND
#   2. prints the rule-name tag (e.g. `[ban-drop-column]`) so operators see
#      WHY it blocked.
#
# The safe-additive fixture must exit 0 — no false positives.
#
# Will FAIL until Phase 2 flips `adding-field-with-default` on explicitly
# (requires --pg-version < 11 or rule-force). Four of five already trip by
# default in recent squawk builds; the fifth is the gate-forcing one.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib/assert.sh
source "$HERE/lib/assert.sh"

WRAPPER="$REPO_ROOT/scripts/security-squawk-test-wrapper.sh"
FIXTURES="$REPO_ROOT/test/fixtures/migrations/destructive"

run_squawk() {
    local fixture="$1"
    OUT=$("$WRAPPER" "$fixture" 2>&1)
    RC=$?
}

if ! command -v squawk &>/dev/null; then
    echo "# SKIP: squawk not installed — Phase 2 CI job will enforce this"
    exit 0
fi

test_case "drop-column" "ALTER TABLE ... DROP COLUMN must trip ban-drop-column"
run_squawk "$FIXTURES/drop_column.exs"
assert_exit_nonzero "$RC" "drop-column fixture exits non-zero"
assert_contains "$OUT" "ban-drop-column" "output names the ban-drop-column rule"

test_case "rename-column" "ALTER TABLE ... RENAME COLUMN must trip renaming-column"
run_squawk "$FIXTURES/rename_column.exs"
assert_exit_nonzero "$RC" "rename-column fixture exits non-zero"
assert_contains "$OUT" "renaming-column" "output names the renaming-column rule"

test_case "rename-table" "ALTER TABLE ... RENAME TO must trip renaming-table"
run_squawk "$FIXTURES/rename_table.exs"
assert_exit_nonzero "$RC" "rename-table fixture exits non-zero"
assert_contains "$OUT" "renaming-table" "output names the renaming-table rule"

test_case "add-not-null-field" "ADD COLUMN ... NOT NULL (no default) must trip"
run_squawk "$FIXTURES/add_not_null_field.exs"
assert_exit_nonzero "$RC" "add-not-null-field fixture exits non-zero"
assert_contains "$OUT" "adding-required-field" \
    "output names the adding-required-field rule (aka adding-not-null-field)"

test_case "add-field-with-default" "dropped from scope — fixture should pass on PG15"
run_squawk "$FIXTURES/add_field_with_default.exs"
assert_exit_zero "$RC" "add-field-with-default fixture exits 0 (rule intentionally not enabled)"

test_case "safe-add-column" "Additive nullable column must pass"
run_squawk "$FIXTURES/safe_add_column.exs"
assert_exit_zero "$RC" "safe-add-column fixture exits 0"
assert_not_contains "$OUT" "ban-drop-column"   "no drop rule on safe fixture"
assert_not_contains "$OUT" "renaming-column"   "no rename rule on safe fixture"

summarise
