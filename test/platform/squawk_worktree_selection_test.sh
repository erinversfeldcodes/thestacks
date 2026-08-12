#!/usr/bin/env bash

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

assert_exit_code() {
    local expected="$1" actual="$2" msg="$3"
    if [[ "$actual" -eq "$expected" ]]; then
        _record_pass "$msg"
    else
        _record_fail "$msg (expected exit $expected, got $actual)"
    fi
}

write_bad_migration "$MIGRATIONS/20260101000000_historical_bad.exs"
write_good_migration "$MIGRATIONS/20260102000000_inherited_safe.exs"
git -C "$SANDBOX" add -A
git -C "$SANDBOX" commit -qm "historical migrations that predate the gate"
git -C "$SANDBOX" branch -q base
git -C "$SANDBOX" checkout -qb feature

test_case "empty_reports_skip" "no changed migrations → exit 2 (SKIP), never exit 0"
run_gate base
assert_contains "$OUT" "SKIP" "output leads with SKIP, not silence"
assert_contains "$OUT" "not a pass" "output states in words that this is not a pass"
if [[ "$RC" -eq 2 ]]; then
    _record_pass "exit code is 2 (nothing inspected), distinct from 0"
else
    _record_fail "exit code is 2 (nothing inspected), distinct from 0 (got $RC)"
fi

test_case "historical_noise_suppressed" "a hazard already on the base branch is not linted"
assert_not_contains "$OUT" "historical_bad" \
    "the pre-existing bad migration is not in the file list"
assert_not_contains "$OUT" "require-concurrent-index-creation" \
    "no violation is reported for history the branch never touched"

test_case "untracked_bad_fails" "an untracked hazardous migration is caught"
write_bad_migration "$MIGRATIONS/20260202000000_untracked_bad.exs"
run_gate base
assert_exit_code 1 "$RC" "gate exits 1 (violation), not 2 (nothing read)"
assert_contains "$OUT" "untracked_bad" "the untracked file is named in the lint list"
assert_contains "$OUT" "require-concurrent-index-creation" "the rule that fired is named"

test_case "staged_bad_fails" "a staged-but-uncommitted hazardous migration is caught"
git -C "$SANDBOX" add -A
run_gate base
assert_exit_code 1 "$RC" "gate exits 1 (violation) on a staged hazardous migration"
assert_contains "$OUT" "untracked_bad" "the staged file is named in the lint list"
git -C "$SANDBOX" reset -q
rm -f "$MIGRATIONS/20260202000000_untracked_bad.exs"

test_case "unstaged_edit_fails" "an unstaged edit to an inherited migration is caught"
write_bad_migration "$MIGRATIONS/20260102000000_inherited_safe.exs"
run_gate base
assert_exit_code 1 "$RC" "gate exits 1 on an unstaged hazardous edit"
assert_contains "$OUT" "inherited_safe" "the edited inherited file is named in the lint list"
assert_contains "$OUT" "require-concurrent-index-creation" "the rule that fired is named"
write_good_migration "$MIGRATIONS/20260102000000_inherited_safe.exs"

test_case "committed_bad_still_fails" "a committed hazardous migration is still caught"
write_bad_migration "$MIGRATIONS/20260303000000_edited.exs"
git -C "$SANDBOX" add -A
git -C "$SANDBOX" commit -qm "committed hazard"
run_gate base
assert_exit_code 1 "$RC" "gate exits 1 on a committed hazardous migration"
assert_contains "$OUT" "edited" "the committed file is named in the lint list"

test_case "committed_good_passes" "a committed safe migration passes and reports its count"
write_good_migration "$MIGRATIONS/20260303000000_edited.exs"
git -C "$SANDBOX" add -A
git -C "$SANDBOX" commit -qm "make it safe again"
run_gate base
assert_exit_code 0 "$RC" "gate exits 0 when the changed migrations are safe"
assert_contains "$OUT" "squawk: clean" "success line is printed"
assert_contains "$OUT" "analysable SQL" "success line states how many files were analysed"
assert_not_contains "$OUT" "historical_bad" "history is still not linted on a passing run"

test_case "new_table_index_passes" "a non-concurrent index on a brand-new table is not a hazard"
write_new_table_migration "$MIGRATIONS/20260404000000_new_table.exs"
run_gate base
assert_exit_code 0 "$RC" "gate exits 0 — nothing exists yet to lock"
assert_not_contains "$OUT" "require-concurrent-index-creation" \
    "the concurrent-index rule does not fire on a same-migration table"
rm -f "$MIGRATIONS/20260404000000_new_table.exs"

test_case "unanalysable_reports_skip" "selected-but-unreadable migrations do not report clean"
write_unanalysable_migration "$MIGRATIONS/20260404050000_unanalysable.exs"
run_gate HEAD
assert_exit_code 2 "$RC" "exit 2 — a file was selected but nothing was asserted about it"
assert_contains "$OUT" "asserted nothing" "output says squawk asserted nothing"
assert_not_contains "$OUT" "squawk: clean" "the success line is NOT printed"
rm -f "$MIGRATIONS/20260404050000_unanalysable.exs"

test_case "create_if_not_exists_caught" "create_if_not_exists index(...) is translated too"
write_bad_if_not_exists_migration "$MIGRATIONS/20260404100000_idempotent_bad.exs"
run_gate base
assert_exit_code 1 "$RC" "gate exits 1 — the idempotent form is not a way around squawk"
assert_contains "$OUT" "require-concurrent-index-creation" "the rule that fired is named"
rm -f "$MIGRATIONS/20260404100000_idempotent_bad.exs"

test_case "missing_base_ref" "an unresolvable base still lints the working tree, never history"
write_bad_migration "$MIGRATIONS/20260505000000_worktree_only.exs"
run_gate refs/heads/does-not-exist
assert_exit_code 1 "$RC" "gate still catches the working-tree hazard without a base ref"
assert_contains "$OUT" "not found" "the missing base ref is reported, not swallowed"
assert_contains "$OUT" "worktree_only" "the working-tree migration is linted"
assert_not_contains "$OUT" "historical_bad" \
    "a missing base ref does NOT fall back to linting all of history"

summarise
