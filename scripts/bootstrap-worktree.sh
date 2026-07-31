#!/usr/bin/env bash
#
# scripts/bootstrap-worktree.sh — make a fresh git worktree buildable.
#
# WHY THIS EXISTS
# ---------------
# Agents build in isolated `git worktree`s. A worktree shares git refs with the
# main checkout but NOT its untracked files — and this repo keeps a lot of
# load-bearing state untracked on purpose:
#
#   * `.env`                              (secrets; never committed)
#   * `apps/core/lib/stacks/gen/`         (proto-generated Ecto schemas + wire structs)
#   * `proto/gen/elm/`, the Python/Rust   (proto-generated, all gitignored)
#     generated artefacts
#   * `apps/core/priv/static/index.html`  (esbuild output)
#   * `deps/`, `_build/`                  (per-worktree)
#
# So a fresh worktree does not compile, and the failures are misleading:
# `Stacks.Accounts.User` "does not exist" (it is generated), or three
# PageControllerTest failures that look like a code defect but are a missing
# static asset. Every agent that hit this rediscovered the fix by hand, and the
# steps drifted between one agent's prompt and the next.
#
# THE CYCLE
# ---------
# `mix proto.sync` is a Mix task that lives inside `apps/core` — but `core`
# cannot compile without the schemas that task generates. Seeding `gen/` from
# the main checkout breaks the cycle; the regeneration afterwards proves the
# seed was not stale (`mix proto.sync --check`).
#
# USAGE
#   bash scripts/bootstrap-worktree.sh [--from /path/to/main/checkout]
#
# Idempotent: safe to re-run. Run it from inside the worktree.

set -euo pipefail

WORKTREE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_CHECKOUT=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --from)
            SOURCE_CHECKOUT="$2"
            shift 2
            ;;
        -h | --help)
            sed -n '2,32p' "${BASH_SOURCE[0]}"
            exit 0
            ;;
        *)
            echo "ERROR: unknown argument '$1'" >&2
            exit 1
            ;;
    esac
done

# Derive the main checkout from git if not supplied. `git worktree list` puts
# the main working tree first; that is where the untracked state lives.
if [[ -z "$SOURCE_CHECKOUT" ]]; then
    SOURCE_CHECKOUT="$(git -C "$WORKTREE_ROOT" worktree list --porcelain 2>/dev/null |
        awk '/^worktree /{print $2; exit}')"
fi

if [[ -z "$SOURCE_CHECKOUT" || ! -d "$SOURCE_CHECKOUT" ]]; then
    echo "ERROR: could not locate the main checkout. Pass --from /path/to/checkout." >&2
    exit 1
fi

if [[ "$SOURCE_CHECKOUT" == "$WORKTREE_ROOT" ]]; then
    echo "==> Running in the main checkout, not a worktree — nothing to seed."
    echo "    (This script copies untracked state FROM the main checkout INTO a worktree.)"
    exit 0
fi

echo "==> Bootstrapping worktree"
echo "    worktree: $WORKTREE_ROOT"
echo "    seed from: $SOURCE_CHECKOUT"

# 1. Secrets. Many mix tasks and scripts fail without CLOAK_KEY / DATABASE_URL.
if [[ -f "$SOURCE_CHECKOUT/.env" && ! -f "$WORKTREE_ROOT/.env" ]]; then
    cp "$SOURCE_CHECKOUT/.env" "$WORKTREE_ROOT/.env"
    echo "    .env copied"
else
    echo "    .env present or unavailable — skipped"
fi

# 2. Seed the generated Ecto schemas so `core` can compile at all. This is the
#    cycle-breaker; step 4 regenerates and verifies.
if [[ -d "$SOURCE_CHECKOUT/apps/core/lib/stacks/gen" ]]; then
    mkdir -p "$WORKTREE_ROOT/apps/core/lib/stacks"
    rsync -a --delete \
        "$SOURCE_CHECKOUT/apps/core/lib/stacks/gen/" \
        "$WORKTREE_ROOT/apps/core/lib/stacks/gen/"
    echo "    apps/core/lib/stacks/gen/ seeded"
else
    echo "    WARNING: no gen/ in the source checkout — run 'mix proto.sync' there first." >&2
fi

# 3. esbuild output. Without it, PageControllerTest fails 3 times in a way that
#    reads like a code defect.
if [[ -f "$SOURCE_CHECKOUT/apps/core/assets/index.html" ]]; then
    mkdir -p "$WORKTREE_ROOT/apps/core/priv/static"
    cp "$SOURCE_CHECKOUT/apps/core/assets/index.html" \
        "$WORKTREE_ROOT/apps/core/priv/static/index.html"
    echo "    priv/static/index.html copied"
fi

# 4. Dependencies BEFORE codegen — the generators run Mix tasks.
echo "==> mix deps.get"
(cd "$WORKTREE_ROOT" && mix deps.get >/dev/null)

# 5. All five codegen targets. `lint-proto.sh` checks five; generating only the
#    Elixir pair leaves the other three absent, and the gate fails on a fresh
#    worktree for reasons that have nothing to do with the change under test.
echo "==> Generating proto artefacts (all five targets)"
for gen in gen-ecto-proto gen-elixir-proto gen-elm-proto gen-python-proto gen-rust-proto; do
    if [[ -x "$WORKTREE_ROOT/scripts/${gen}.sh" || -f "$WORKTREE_ROOT/scripts/${gen}.sh" ]]; then
        echo "    ${gen}.sh"
        bash "$WORKTREE_ROOT/scripts/${gen}.sh" >/dev/null
    fi
done

# 6. Prove the seed in step 2 was not stale.
echo "==> Verifying no codegen drift"
(cd "$WORKTREE_ROOT/apps/core" && mix proto.sync --check)

echo ""
echo "==> Worktree ready."
echo "    Reminder: use 'just run mix ...' — a bare mix picks up the system Elixir"
echo "    and corrupts _build. Wrap long suites in 'caffeinate -i'."
