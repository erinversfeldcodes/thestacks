#!/usr/bin/env bash
# test/platform/migration_gate_syntax_test.sh
#
# Covers Issue #219: "Harden migration-safety gates — close the DSL/raw-execute
# blind spot." The two gates (`lint-migrations.sh` @breaking_ok enforcement and
# `security-squawk.sh` hazard linting) previously had a hole exactly at the
# DSL/raw-execute boundary:
#
#   * A NOT NULL tighten written as raw `execute("ALTER … SET NOT NULL")` evaded
#     lint-migrations.sh, which only matched the `modify … null: false` DSL.
#   * A `create unique_index(..., concurrently: false)` DSL call evaded squawk,
#     which only linted SQL inside execute() strings.
#
# This suite asserts neither gate can be bypassed by choice of syntax, and that
# the real annotated migration + a genuinely-safe concurrent index still pass.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib/assert.sh
source "$HERE/lib/assert.sh"

LINTER="$REPO_ROOT/scripts/lint-migrations.sh"
WRAPPER="$REPO_ROOT/scripts/security-squawk-test-wrapper.sh"
ELIXIR_FIXTURES="$REPO_ROOT/test/fixtures/migrations/elixir"
DSL_FIXTURES="$REPO_ROOT/test/fixtures/migrations/destructive"
REAL_MIGRATIONS="$REPO_ROOT/apps/core/priv/repo/migrations"

run_linter() {
    OUT=$("$LINTER" "$@" 2>&1)
    RC=$?
}

run_squawk() {
    OUT=$("$WRAPPER" "$1" 2>&1)
    RC=$?
}

# ── AC1: raw execute() SET NOT NULL without @breaking_ok fails ────────────────
test_case "raw_set_not_null_bad" "raw execute(SET NOT NULL) without @breaking_ok fails lint"
run_linter "$ELIXIR_FIXTURES/execute_set_not_null_bad.exs"
assert_exit_nonzero "$RC" "execute_set_not_null_bad.exs exits non-zero"
assert_contains "$OUT" "execute_set_not_null_bad.exs" "output names the offending file"
assert_contains "$OUT" "SET NOT NULL" "output names the raw SET NOT NULL op"
assert_contains "$OUT" "breaking_ok" "output explains the missing annotation"

# ── AC1: same raw op WITH @breaking_ok passes ────────────────────────────────
test_case "raw_set_not_null_ok" "annotated raw execute(SET NOT NULL) passes, reason echoed"
run_linter "$ELIXIR_FIXTURES/execute_set_not_null_ok.exs"
assert_exit_zero "$RC" "execute_set_not_null_ok.exs exits 0 (annotation present)"
assert_contains "$OUT" "raw-execute NOT NULL tighten fixture" \
    "linter echoes the @breaking_ok reason to stdout"

# ── AC2: DSL create unique_index(concurrently: false) is caught by squawk ─────
test_case "dsl_unique_index_bad" "non-concurrent index DSL is translated + caught by squawk"
if command -v squawk &>/dev/null; then
    run_squawk "$DSL_FIXTURES/dsl_unique_index.exs"
    assert_exit_nonzero "$RC" "dsl_unique_index.exs exits non-zero"
    assert_contains "$OUT" "require-concurrent-index-creation" \
        "output names the require-concurrent-index-creation rule"
else
    echo "# SKIP: squawk not installed — CI migration-safety job will enforce this"
fi

# ── AC2 no-false-positive: safe concurrent named index passes squawk ─────────
test_case "dsl_unique_index_concurrent" "safe concurrent named index DSL passes squawk"
if command -v squawk &>/dev/null; then
    run_squawk "$DSL_FIXTURES/dsl_unique_index_concurrent.exs"
    assert_exit_zero "$RC" "dsl_unique_index_concurrent.exs exits 0 (no false positive)"
else
    echo "# SKIP: squawk not installed"
fi

# ── AC3: the REAL annotated handle-tighten migration still passes lint ────────
# These two real migrations were introduced on a sibling epic branch and are not
# present on every lineage. Guard on existence so the regression suite is green
# wherever this gate lives, but still validates the "must not break the real,
# correctly-annotated migration" requirement on branches that carry them.
REAL_TIGHTEN="$REAL_MIGRATIONS/20260714200500_backfill_and_constrain_user_handles.exs"
REAL_INDEX="$REAL_MIGRATIONS/20260714200520_create_handle_lower_unique_index.exs"

test_case "real_handle_migration_still_passes" "real 20260714200500 migration still passes lint"
if [[ -f "$REAL_TIGHTEN" ]]; then
    run_linter "$REAL_TIGHTEN"
    assert_exit_zero "$RC" "real handle-tighten migration exits 0 (has @breaking_ok)"
    assert_contains "$OUT" "@breaking_ok" "linter echoes the real migration's annotation"
else
    echo "# SKIP: $REAL_TIGHTEN not present on this branch"
fi

# ── AC3: the REAL concurrent handle index migration still passes squawk ──────
test_case "real_handle_index_still_passes" "real 20260714200520 concurrent index passes squawk"
if [[ -f "$REAL_INDEX" ]] && command -v squawk &>/dev/null; then
    run_squawk "$REAL_INDEX"
    assert_exit_zero "$RC" "real concurrent index migration exits 0 (no false positive)"
else
    echo "# SKIP: real concurrent index migration absent or squawk not installed"
fi

summarise
