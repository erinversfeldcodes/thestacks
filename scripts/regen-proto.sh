#!/usr/bin/env bash
#
# scripts/regen-proto.sh — regenerate every proto codegen target, then prove it.
#
# WHY THIS EXISTS (Issue #354)
# ----------------------------
# After merging a branch that touched a `.proto` file, a checkout's generated
# artefacts are stale. Most of them are gitignored, so `git status` is clean and
# nothing tells you — until a gate fails, and it fails in three places at once
# (`proto: lint`, plus `elixir: test` and `python: test`, which compile against
# the stale code). That happened in Wave 4 and again in Wave 5, costing a full
# `just ci` re-run each time.
#
# `just bootstrap-worktree` closes this for worktrees. Both incidents happened
# in the MAIN checkout, which had no equivalent step. This is that step.
#
# ⚠️ THERE ARE FIVE TARGETS, NOT TWO. `mix proto.sync` (Ecto schemas, dbt models,
# migrations) and `scripts/gen-elixir-proto.sh` (inter-service wire structs and
# the closed enum contracts) are DIFFERENT generators. Regenerating only the
# Ecto half leaves the wire structs adrift, which has bitten this project twice
# independently. The list below is the single source of truth for "all of them"
# — bootstrap-worktree.sh and `just proto-sync-all` both defer to it.
#
# USAGE
#   just run just regen-proto        # preferred: pinned toolchain
#   bash scripts/regen-proto.sh
#
# Bare `mix` picks up a system Elixir and corrupts `_build`, and this script
# runs Mix tasks — so route it through `just run` outside a direnv shell.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "==> 1/5  Ecto schemas, dbt models, migrations (mix proto.sync)"
bash "$REPO_ROOT/scripts/gen-ecto-proto.sh"

echo "==> 2/5  Elixir inter-service structs + enum contracts"
bash "$REPO_ROOT/scripts/gen-elixir-proto.sh"

echo "==> 3/5  Python Pydantic models"
bash "$REPO_ROOT/scripts/gen-python-proto.sh"

echo "==> 4/5  Rust serde structs"
bash "$REPO_ROOT/scripts/gen-rust-proto.sh"

echo "==> 5/5  Elm decoders"
bash "$REPO_ROOT/scripts/gen-elm-proto.sh"

# A generated migration is UNTRACKED, and `mix test` deletes untracked
# `_add_*_to_*` migrations. Staging immediately is the only reliable protection.
# The pathspec is explicit per file so this can never sweep up someone else's
# staged work.
while IFS= read -r migration; do
    [[ -n "$migration" ]] || continue
    git -C "$REPO_ROOT" add -- "$migration"
    echo "    staged generated migration: $migration"
done < <(git -C "$REPO_ROOT" status --porcelain -- apps/core/priv/repo/migrations/ |
    awk '/^\?\?/ {print $2}')

# Prove it. This is the same check the gate runs, so a green line here means the
# gate cannot fail for staleness.
echo "==> Verifying no codegen drift"
(cd "$REPO_ROOT/apps/core" && mix proto.sync --check)
bash "$REPO_ROOT/scripts/gen-elixir-proto.sh" --check
bash "$REPO_ROOT/scripts/gen-python-proto.sh" --check
bash "$REPO_ROOT/scripts/gen-rust-proto.sh" --check
bash "$REPO_ROOT/scripts/gen-elm-proto.sh" --check

echo ""
echo "==> All five codegen targets are current."
