#!/usr/bin/env bash
# test/platform/squawk_worktree_selection_test.sh
#
# Covers Issue #337: "the squawk gate passes without reading anything when
# migrations are uncommitted."
#
# `security-squawk.sh` used to select its input with a committed-tree diff
# (`origin/main...HEAD`) only. A migration that existed on disk but not yet in a
# commit was invisible, and the empty file list printed "skipping squawk" and
# exited 0 — which `just ci` rendered as PASS. So the order everyone actually
# works in (write migration → run gate → commit) produced a green migration
# safety gate that had inspected zero migrations.
#
# These are counterfactual tests in the #330 sense: each one plants a migration
# that squawk MUST reject and asserts the gate rejects it. If the selection
# regresses to committed-only, the "uncommitted" cases go green and fail here.
#
# Method: build a throwaway git repo in $TMPDIR containing copies of the three
# scripts under test. `security-squawk.sh` derives REPO_ROOT from its own
# location, so the copy operates on the sandbox repo and never touches this one.
# That lets us control the commit graph exactly — including a base branch that
# already carries a hazardous migration, which must stay unlinted.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib/assert.sh
source "$HERE/lib/assert.sh"

if ! command -v squawk &>/dev/null; then
    echo "# SKIP: squawk not installed — CI's migration-safety job enforces this"
    exit 0
fi

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

MIGRATIONS="$SANDBOX/apps/core/priv/repo/migrations"
mkdir -p "$MIGRATIONS" "$SANDBOX/scripts"
cp "$REPO_ROOT/scripts/security-squawk.sh" "$SANDBOX/scripts/"
cp "$REPO_ROOT/scripts/extract-migration-sql.py" "$SANDBOX/scripts/"

git -C "$SANDBOX" init -q
git -C "$SANDBOX" config user.email "platform-test@thestacks.invalid"
git -C "$SANDBOX" config user.name "platform test"
git -C "$SANDBOX" add -A
git -C "$SANDBOX" commit -qm "scripts"

# ── Migration bodies ─────────────────────────────────────────────────────────
# Hazardous: a non-concurrent index on a table that already exists. Blocks
# writes for the whole build → require-concurrent-index-creation.
write_bad_migration() {
    cat > "$1" <<'EOF'
defmodule Core.Repo.Migrations.Bad do
  use Ecto.Migration

  def change do
    create index(:users, [:email], prefix: "op", concurrently: false)
  end
end
EOF
}

# Hazardous, written with the IDEMPOTENT form. `create_if_not_exists index(...)`
# was not matched by the DSL translator's regex, so the #219 blind spot was
# still wide open for anyone who reached for it — including one of Wave 4's own
# migrations, from which the gate extracted zero statements.
write_bad_if_not_exists_migration() {
    cat > "$1" <<'EOF'
defmodule Core.Repo.Migrations.BadIdempotent do
  use Ecto.Migration

  def up do
    create_if_not_exists index(:users, [:email], prefix: "op", concurrently: false)
  end
end
EOF
}

# Neither safe nor unsafe as far as squawk is concerned: pure Ecto DSL with no
# execute() and no index, so the extractor yields nothing at all. The gate used
# to report these as "all migrations clean", which reads as approval of a file
# it never looked at.
write_unanalysable_migration() {
    cat > "$1" <<'EOF'
defmodule Core.Repo.Migrations.Unanalysable do
  use Ecto.Migration

  def change do
    alter table(:users, prefix: "op") do
      add :nickname, :string
    end
  end
end
EOF
}

# Safe: the same index, built concurrently.
write_good_migration() {
    cat > "$1" <<'EOF'
defmodule Core.Repo.Migrations.Good do
  use Ecto.Migration
  @disable_ddl_transaction true

  def change do
    create index(:users, [:email], prefix: "op", concurrently: true, name: :users_email_idx)
  end
end
EOF
}

# Safe despite the non-concurrent index: the table is created by this very
# migration, so there is nothing live to lock. This is the false positive that
# put 32 historical migrations in the red (#339) and would have got the gate
# switched off if the fix had widened scope instead of extending the diff.
write_new_table_migration() {
    cat > "$1" <<'EOF'
defmodule Core.Repo.Migrations.NewTable do
  use Ecto.Migration

  def change do
    create table(:widgets, prefix: "op") do
      add :name, :string
      timestamps()
    end

    create unique_index(:widgets, [:name], prefix: "op", concurrently: false)
  end
end
EOF
}

run_gate() {
    OUT="$(bash "$SANDBOX/scripts/security-squawk.sh" "$@" 2>&1)"
    RC=$?
}

# `assert_exit_nonzero` is too weak here: exit 2 (SKIP — inspected nothing) is
# also non-zero, so a gate that silently stopped reading files would satisfy it.
# The whole point of this suite is telling 1 (violation found) from 2 (nothing
# read), so assert the exact code.
assert_exit_code() {
    local expected="$1" actual="$2" msg="$3"
    if [[ "$actual" -eq "$expected" ]]; then
        _record_pass "$msg"
    else
        _record_fail "$msg (expected exit $expected, got $actual)"
    fi
}

# The base branch deliberately carries a hazardous migration. It stands in for
# the 105 migrations already in this repo's history: real, already deployed, and
# none of the gate's business on a branch that did not touch them. It also
# carries a safe one, used later to prove that editing a migration inherited
# from the base — which the committed diff cannot see at all — is still caught.
write_bad_migration "$MIGRATIONS/20260101000000_historical_bad.exs"
write_good_migration "$MIGRATIONS/20260102000000_inherited_safe.exs"
git -C "$SANDBOX" add -A
git -C "$SANDBOX" commit -qm "historical migrations that predate the gate"
git -C "$SANDBOX" branch -q base
git -C "$SANDBOX" checkout -qb feature

# ── 1. Empty case: SKIP, not PASS ────────────────────────────────────────────
test_case "empty_reports_skip" "no changed migrations → exit 2 (SKIP), never exit 0"
run_gate base
assert_contains "$OUT" "SKIP" "output leads with SKIP, not silence"
assert_contains "$OUT" "not a pass" "output states in words that this is not a pass"
if [[ "$RC" -eq 2 ]]; then
    _record_pass "exit code is 2 (nothing inspected), distinct from 0"
else
    _record_fail "exit code is 2 (nothing inspected), distinct from 0 (got $RC)"
fi

# ── 1b. …and the historical hazard on the base branch stays unlinted ─────────
test_case "historical_noise_suppressed" "a hazard already on the base branch is not linted"
assert_not_contains "$OUT" "historical_bad" \
    "the pre-existing bad migration is not in the file list"
assert_not_contains "$OUT" "require-concurrent-index-creation" \
    "no violation is reported for history the branch never touched"

# ── 2. UNTRACKED bad migration → gate fails ──────────────────────────────────
# The #337 headline: git has never seen this file. Before the fix the gate
# printed "No changed migration files to lint" and exited 0.
test_case "untracked_bad_fails" "an untracked hazardous migration is caught"
write_bad_migration "$MIGRATIONS/20260202000000_untracked_bad.exs"
run_gate base
assert_exit_code 1 "$RC" "gate exits 1 (violation), not 2 (nothing read)"
assert_contains "$OUT" "untracked_bad" "the untracked file is named in the lint list"
assert_contains "$OUT" "require-concurrent-index-creation" "the rule that fired is named"

# ── 3. STAGED bad migration → gate fails ─────────────────────────────────────
test_case "staged_bad_fails" "a staged-but-uncommitted hazardous migration is caught"
git -C "$SANDBOX" add -A
run_gate base
assert_exit_code 1 "$RC" "gate exits 1 (violation) on a staged hazardous migration"
assert_contains "$OUT" "untracked_bad" "the staged file is named in the lint list"
git -C "$SANDBOX" reset -q
rm -f "$MIGRATIONS/20260202000000_untracked_bad.exs"

# ── 4. UNSTAGED edit to a migration INHERITED from the base → gate fails ─────
# The strict discriminator. `20260102000000_inherited_safe.exs` exists on the
# base branch, so `base...HEAD` never mentions it no matter what we do to the
# working copy. Only `git diff HEAD` can see the edit. Editing a migration the
# branch itself added is NOT a discriminator: the committed diff already names
# that path, and the gate reads the file from disk, so the old form caught it
# by accident.
test_case "unstaged_edit_fails" "an unstaged edit to an inherited migration is caught"
write_bad_migration "$MIGRATIONS/20260102000000_inherited_safe.exs"
run_gate base
assert_exit_code 1 "$RC" "gate exits 1 on an unstaged hazardous edit"
assert_contains "$OUT" "inherited_safe" "the edited inherited file is named in the lint list"
assert_contains "$OUT" "require-concurrent-index-creation" "the rule that fired is named"
write_good_migration "$MIGRATIONS/20260102000000_inherited_safe.exs"

# ── 5. Regression: the committed path still works ────────────────────────────
test_case "committed_bad_still_fails" "a committed hazardous migration is still caught"
write_bad_migration "$MIGRATIONS/20260303000000_edited.exs"
git -C "$SANDBOX" add -A
git -C "$SANDBOX" commit -qm "committed hazard"
run_gate base
assert_exit_code 1 "$RC" "gate exits 1 on a committed hazardous migration"
assert_contains "$OUT" "edited" "the committed file is named in the lint list"

# ── 6. Regression: a clean branch passes, and says how much it read ──────────
test_case "committed_good_passes" "a committed safe migration passes and reports its count"
write_good_migration "$MIGRATIONS/20260303000000_edited.exs"
git -C "$SANDBOX" add -A
git -C "$SANDBOX" commit -qm "make it safe again"
run_gate base
assert_exit_code 0 "$RC" "gate exits 0 when the changed migrations are safe"
assert_contains "$OUT" "squawk: clean" "success line is printed"
assert_contains "$OUT" "analysable SQL" "success line states how many files were analysed"
assert_not_contains "$OUT" "historical_bad" "history is still not linted on a passing run"

# ── 7. No false positive: non-concurrent index on a table this migration creates ──
test_case "new_table_index_passes" "a non-concurrent index on a brand-new table is not a hazard"
write_new_table_migration "$MIGRATIONS/20260404000000_new_table.exs"
run_gate base
assert_exit_code 0 "$RC" "gate exits 0 — nothing exists yet to lock"
assert_not_contains "$OUT" "require-concurrent-index-creation" \
    "the concurrent-index rule does not fire on a same-migration table"
rm -f "$MIGRATIONS/20260404000000_new_table.exs"

# ── 7a. A changed migration squawk cannot read is a SKIP, not a pass ─────────
test_case "unanalysable_reports_skip" "selected-but-unreadable migrations do not report clean"
write_unanalysable_migration "$MIGRATIONS/20260404050000_unanalysable.exs"
# Base HEAD, not `base`: this asserts the state where EVERY selected file is
# unreadable. Against `base` the branch's own analysable migration is also
# selected and the run is a legitimate pass — which is correct, and is why the
# counter is `ANALYSED`, not "did any file get skipped".
run_gate HEAD
assert_exit_code 2 "$RC" "exit 2 — a file was selected but nothing was asserted about it"
assert_contains "$OUT" "asserted nothing" "output says squawk asserted nothing"
assert_not_contains "$OUT" "squawk: clean" "the success line is NOT printed"
rm -f "$MIGRATIONS/20260404050000_unanalysable.exs"

# ── 7b. The idempotent DSL form is not an escape hatch ───────────────────────
test_case "create_if_not_exists_caught" "create_if_not_exists index(...) is translated too"
write_bad_if_not_exists_migration "$MIGRATIONS/20260404100000_idempotent_bad.exs"
run_gate base
assert_exit_code 1 "$RC" "gate exits 1 — the idempotent form is not a way around squawk"
assert_contains "$OUT" "require-concurrent-index-creation" "the rule that fired is named"
rm -f "$MIGRATIONS/20260404100000_idempotent_bad.exs"

# ── 8. Missing base ref degrades to the working tree, not to linting history ──
test_case "missing_base_ref" "an unresolvable base still lints the working tree, never history"
write_bad_migration "$MIGRATIONS/20260505000000_worktree_only.exs"
run_gate refs/heads/does-not-exist
assert_exit_code 1 "$RC" "gate still catches the working-tree hazard without a base ref"
assert_contains "$OUT" "not found" "the missing base ref is reported, not swallowed"
assert_contains "$OUT" "worktree_only" "the working-tree migration is linted"
assert_not_contains "$OUT" "historical_bad" \
    "a missing base ref does NOT fall back to linting all of history"

summarise
