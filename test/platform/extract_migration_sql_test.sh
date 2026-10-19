#!/usr/bin/env bash
# test/platform/extract_migration_sql_test.sh
#
# scripts/extract-migration-sql.py turns an Ecto migration into the SQL stream
# squawk analyses. This suite pins the property that stream has to have and did
# not: **the statements come out in the order the migration runs them.**
#
# The extractor used to scan the two `execute` forms in separate passes — every
# `execute("""…""")` heredoc first, then every `execute("…")` single-line one —
# and then append the DSL-derived index DDL after both. So a migration whose
# first statement was a single-line `execute("SET lock_timeout = '5s'")`
# followed by a heredoc `ALTER TABLE` handed squawk the ALTER first and the SET
# last.
#
# That is not cosmetic. squawk's analysis is order-sensitive in both directions:
#   - a `SET lock_timeout` only covers statements that FOLLOW it, so hoisting the
#     ALTER above it makes a correctly written migration look unguarded;
#   - `CREATE TABLE t` earlier in the stream tells squawk that operations on `t`
#     are safe (nothing can read it yet), so sinking a create below an ALTER
#     makes a safe migration look dangerous — and floating one above an ALTER on
#     a DIFFERENT, live table would do the reverse.
#
# A reordering extractor can therefore both manufacture a finding and hide one,
# which is why the ordering is asserted here rather than left to the gate's
# end-to-end result.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib/assert.sh
source "$HERE/lib/assert.sh"

EXTRACTOR="$REPO_ROOT/scripts/extract-migration-sql.py"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# A migration that interleaves all three statement sources, in an order that the
# old two-pass scan could not reproduce: single-line, heredoc, single-line,
# index DSL, heredoc.
cat > "$WORKDIR/mixed.exs" <<'FIXTURE'
defmodule Core.Repo.Migrations.Mixed do
  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout = '5s'")

    execute("""
    ALTER TABLE op.widgets
      ADD CONSTRAINT widgets_name_present
      CHECK (name IS NOT NULL)
      NOT VALID
    """)

    execute("SET LOCAL statement_timeout = '30s'")

    create index(:widgets, [:name], prefix: "op", name: :widgets_name_idx)

    execute("""
    ALTER TABLE op.widgets VALIDATE CONSTRAINT widgets_name_present
    """)
  end
end
FIXTURE

OUT="$(python3 "$EXTRACTOR" "$WORKDIR/mixed.exs" 2>&1)"
RC=$?

test_case "mixed_extracts" "the extractor reads a mixed-form migration"
assert_exit_zero "$RC" "extractor exits 0 on a mixed-form migration"

# Collapse to one token per statement so the order can be asserted as a single
# string. Blank-line-free, and immune to how the heredocs happen to wrap.
order() {
    printf '%s\n' "$OUT" \
        | grep -oE "SET LOCAL lock_timeout|SET LOCAL statement_timeout|ADD CONSTRAINT|CREATE INDEX|VALIDATE CONSTRAINT" \
        | paste -sd'|' -
}
ORDER="$(order)"

test_case "source_order" "statements come out in source order, not grouped by form"
assert_contains "$ORDER" \
    "SET LOCAL lock_timeout|ADD CONSTRAINT|SET LOCAL statement_timeout|CREATE INDEX|VALIDATE CONSTRAINT" \
    "the five statements appear in the order the migration writes them"

# The property the squawk gate actually rests on, stated on its own: the
# timeout preamble is the FIRST statement in the stream. `require-timeout-settings`
# only credits a `SET` that precedes the operation it is meant to guard, so a
# stream that opens with the ALTER reports a correctly written migration as
# unguarded. This is asserted separately from the full ordering above because it
# is the single thing whose breakage is silent — the gate stays green and the
# red appears on the author's migration instead.
#
# An earlier version of this case asserted the ABSENCE of one guessed inversion
# instead, and stayed green under both probes of the real defect. Asserting the
# property rather than a particular way of violating it is what makes it able to
# fail.
test_case "timeout_preamble_first" "the timeout preamble leads the stream"
assert_contains "$(printf '%s\n' "$ORDER" | cut -d'|' -f1)" "SET LOCAL lock_timeout" \
    "the lock_timeout SET is the first statement squawk sees"

# CREATE TABLE stubs are the one deliberate exception to source order: they are
# context declarations for squawk rather than statements under analysis, so they
# are emitted first regardless of where the create sits in the file.
cat > "$WORKDIR/create_then_alter.exs" <<'FIXTURE'
defmodule Core.Repo.Migrations.CreateThenAlter do
  use Ecto.Migration

  def up do
    execute("ALTER TABLE op.gadgets ADD COLUMN note text")

    create table(:gadgets, prefix: "op") do
      add :note, :text
    end
  end
end
FIXTURE

OUT="$(python3 "$EXTRACTOR" "$WORKDIR/create_then_alter.exs" 2>&1)"
FIRST_LINE="$(printf '%s\n' "$OUT" | head -1)"

test_case "create_table_stub_first" "CREATE TABLE stubs precede the statements"
assert_contains "$FIRST_LINE" "CREATE TABLE op.gadgets" \
    "the table stub is emitted before the ALTER that references it"

# ⛔ PARTIAL EXTRACTION MUST DECLARE ITSELF.
#
# A migration that yields NOTHING makes `security-squawk.sh` print
# "(no raw SQL — skipping)", so a reader can see it was not analysed. A
# migration that yields SOME statements was analysed, found clean, and counted
# toward the coverage number — so the summary claimed a file had been inspected
# when only part of its SQL had been.
#
# Measured when this was found: 7 of 13 changed migrations on this branch
# extracted only partially, and two of them yielded nothing but their `SET LOCAL`
# timeout declarations — the one kind of statement that cannot itself be unsafe.
# squawk reported "Found 0 issues" for both.
cat > "$WORKDIR/partial.exs" <<'FIXTURE'
defmodule Core.Repo.Migrations.Partial do
  use Ecto.Migration

  @role "stacks_app"

  def up do
    execute("SET LOCAL lock_timeout = '5s'")

    # Discarded: Elixir interpolation.
    execute("GRANT SELECT ON op.widgets TO #{@role}")

    # Discarded: anonymous procedure.
    execute("""
    DO $$ BEGIN
      IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'x') THEN
        GRANT INSERT ON op.widgets TO x;
      END IF;
    END $$;
    """)

    # Never matched at all: the argument is not a literal.
    execute(grants_up(), grants_down())
  end

  def down do
    execute("SET LOCAL lock_timeout = '9s'")
  end

  defp grants_up, do: "GRANT UPDATE ON op.widgets TO x"
  defp grants_down, do: "REVOKE UPDATE ON op.widgets FROM x"
end
FIXTURE

PARTIAL_OUT="$(python3 "$EXTRACTOR" "$WORKDIR/partial.exs" 2>&1)"

test_case "partial_extraction_declares_itself" \
    "a migration whose SQL was only partly extracted says so"
assert_contains "$PARTIAL_OUT" "-- UNANALYSABLE" \
    "the stream carries a marker naming the gap"
assert_contains "$PARTIAL_OUT" "Elixir interpolation" \
    "an interpolated statement is counted as dropped"
assert_contains "$PARTIAL_OUT" "DO \$\$ block" \
    "a DO block is counted as dropped"
assert_contains "$PARTIAL_OUT" "non-literal argument" \
    "⛔ execute(helper()) is counted — the one variant that left no trace, because the regex never matched it at all"

test_case "the_marker_is_a_sql_comment" "declaring the gap changes nothing squawk analyses"
# If the marker were not a comment it would alter the statements under analysis,
# which would be a worse cure than the disease.
MARKER_LINE="$(printf '%s\n' "$PARTIAL_OUT" | grep -- '-- UNANALYSABLE' | head -1)"
case "$MARKER_LINE" in
    "--"*) _record_pass "the marker is a SQL comment, so squawk ignores it" ;;
    *) _record_fail "the marker is not a comment: $MARKER_LINE" ;;
esac

test_case "def_down_is_stripped" "only the forward migration reaches squawk"
# ⚠️ `lint-migrations.sh` has always stripped `down`; this extractor did not, so
# the stream carried up and down interleaved. That contradicts this file's own
# header: the reason both execute forms share one alternation is that squawk's
# analysis is ORDER-SENSITIVE, and a rollback's `SET lock_timeout` appearing
# mid-stream can look like it covers a forward statement it will never precede.
assert_not_contains "$PARTIAL_OUT" "lock_timeout = '9s'" \
    "the down/0 statement is not in the stream"
assert_contains "$PARTIAL_OUT" "lock_timeout = '5s'" \
    "while the up/0 statement still is"

test_case "a_fully_extracted_migration_carries_no_marker" "the signal is not always on"
# Anti-vacuity for the assertions above: a marker that appeared unconditionally
# would satisfy every `assert_contains` while meaning nothing.
CLEAN_OUT="$(python3 "$EXTRACTOR" "$WORKDIR/mixed.exs" 2>&1)"
assert_not_contains "$CLEAN_OUT" "-- UNANALYSABLE" \
    "a migration whose SQL extracts completely says nothing about gaps"

summarise
