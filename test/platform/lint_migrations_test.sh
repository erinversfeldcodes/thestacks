#!/usr/bin/env bash
# test/platform/lint_migrations_test.sh
#
# Covers DoD: "`scripts/lint-migrations.sh` exits non-zero on `drop_column`
# without `@breaking_ok`, zero with it, tested with fixtures".
#
# The linter must:
#   - fail on destructive Ecto DSL ops (remove/drop_column, rename, modify null:
#     false) when the migration has no `@breaking_ok "<reason>"` module
#     attribute.
#   - pass on annotated destructive ops, AND print the annotation reason to
#     stdout so reviewers see why the break is justified.
#   - pass on purely additive migrations regardless.
#   - detect destructive ops whether the call is on one line or split across
#     lines (Ecto lets you format `rename(...)` either way).
#
# Will FAIL until Phase 2 implements scripts/lint-migrations.sh for real. The
# stub `exit 0` means bad fixtures pass → assertions catch it.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib/assert.sh
source "$HERE/lib/assert.sh"

LINTER="$REPO_ROOT/scripts/lint-migrations.sh"
FIXTURES="$REPO_ROOT/test/fixtures/migrations/elixir"

run_linter() {
    OUT=$("$LINTER" "$@" 2>&1)
    RC=$?
}

test_case "drop_column_bad" "destructive remove/drop_column without @breaking_ok fails"
run_linter "$FIXTURES/drop_column_bad.exs"
assert_exit_nonzero "$RC" "drop_column_bad.exs causes linter to exit non-zero"
assert_contains "$OUT" "drop_column_bad.exs" "output names the offending file"
assert_contains "$OUT" "breaking_ok" "output explains the missing annotation"

test_case "drop_column_ok" "annotated drop_column passes and reason is echoed"
run_linter "$FIXTURES/drop_column_ok.exs"
assert_exit_zero "$RC" "drop_column_ok.exs exits 0 (annotation present)"
assert_contains "$OUT" "cover_image_url superseded" \
    "linter prints the @breaking_ok reason to stdout"

test_case "rename_bad_multiline" "rename split across lines is still detected"
run_linter "$FIXTURES/rename_bad.exs"
assert_exit_nonzero "$RC" "rename_bad.exs causes linter to exit non-zero"
assert_contains "$OUT" "rename_bad.exs" "output names the offending file"
assert_contains "$OUT" "rename" "output mentions the rename op"

test_case "modify_not_null_bad" "modify ..., null: false without annotation fails"
run_linter "$FIXTURES/modify_not_null_bad.exs"
assert_exit_nonzero "$RC" "modify_not_null_bad.exs causes linter to exit non-zero"
assert_contains "$OUT" "modify_not_null_bad.exs" "output names the offending file"

test_case "safe_additive" "add_column (nullable) passes cleanly"
run_linter "$FIXTURES/safe.exs"
assert_exit_zero "$RC" "safe.exs exits 0"

test_case "create_table_with_down" "drop table inside def down is not destructive"
run_linter "$FIXTURES/create_table_with_down.exs"
assert_exit_zero "$RC" "create_table_with_down.exs exits 0 (drop only in down)"

# The two shapes the SQL extraction was blind to until 2026-10-16. Both were
# found the same way: a real migration converting every timestamp column in the
# database had its `@breaking_ok` removed, and the gate still exited 0.
test_case "helper_built_sql" "SQL assembled in a private helper is still inspected"
run_linter "$FIXTURES/helper_built_sql_bad.exs"
assert_exit_nonzero "$RC" "helper_built_sql_bad.exs exits non-zero"
assert_contains "$OUT" "DROP COLUMN" \
    "the op is named even though no SQL literal sits at the execute call site"

test_case "interpolated_sql" "SQL carrying interpolation is still inspected"
run_linter "$FIXTURES/interpolated_sql_bad.exs"
assert_exit_nonzero "$RC" "interpolated_sql_bad.exs exits non-zero"
assert_contains "$OUT" "ALTER COLUMN" \
    "interpolation does not exempt the statement around it"

# The negative half. Widening the extraction is only worth having if the match
# still means something, so prose that merely NAMES a destructive operation must
# not demand an attestation.
test_case "prose_only" "docs and comments naming destructive ops do not trip the gate"
run_linter "$FIXTURES/prose_only_safe.exs"
assert_exit_zero "$RC" "prose_only_safe.exs exits 0 despite naming DROP COLUMN in its docs"

test_case "multiple_files" "argv with >1 file exits non-zero if ANY is bad"
run_linter \
    "$FIXTURES/safe.exs" \
    "$FIXTURES/drop_column_bad.exs"
assert_exit_nonzero "$RC" "mixed argv exits non-zero"
assert_contains "$OUT" "drop_column_bad.exs" "bad file is called out"

summarise
