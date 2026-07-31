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
    # Nothing to SEED here — there is no other checkout to copy untracked state
    # from. But the main checkout has the other half of the same problem: after
    # merging a branch that touched a .proto file its generated artefacts are
    # stale, most of them are gitignored so `git status` stays clean, and the
    # first thing that notices is a gate failing in three places (Issue #354).
    # Exiting 0 with advice was a dead end, so do the part that does apply.
    echo "==> Running in the main checkout, not a worktree — nothing to seed."
    echo "    Regenerating the proto artefacts instead, which is the step that"
    echo "    does apply here. (Same as: just regen-proto)"
    echo ""
    exec bash "$WORKTREE_ROOT/scripts/regen-proto.sh"
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

# 3b. Frontend node_modules. Without these, `npx elm-test`, `elm-review` and
#     `elm-format` cannot run in a worktree at all — every Elm agent so far has
#     hand-rolled a link or an install to get around it (#332 reported it).
#     Symlinked rather than installed: it is ~200 MB of identical dependencies,
#     and a worktree is short-lived.
#
#     ⚠️ The link is deliberately NOT left for `git add -A` to find. `.gitignore`
#     carries `frontend/node_modules/` and `node_modules/` — both DIRECTORY-only
#     patterns, which do not match a symlink, so a linked node_modules shows as
#     untracked and a sweeping `git add -A` would commit it. The trailing-slash-
#     free rule below is what makes the link ignorable; verify with
#     `git check-ignore -v` rather than by reading .gitignore (#348's lesson).
for dir in frontend apps/core/assets; do
    if [[ -d "$SOURCE_CHECKOUT/$dir/node_modules" && ! -e "$WORKTREE_ROOT/$dir/node_modules" ]]; then
        ln -s "$SOURCE_CHECKOUT/$dir/node_modules" "$WORKTREE_ROOT/$dir/node_modules"
        echo "    $dir/node_modules linked"
    fi
done

# 4. Dependencies BEFORE codegen — the generators run Mix tasks.
echo "==> mix deps.get"
(cd "$WORKTREE_ROOT" && mix deps.get >/dev/null)

# 5. All five codegen targets, and the drift verification that proves the seed
#    in step 2 was not stale. Delegated so there is ONE list of generators —
#    generating only the Elixir pair leaves the other three absent and the gate
#    fails for reasons unrelated to the change under test.
echo "==> Generating proto artefacts (all five targets)"
bash "$WORKTREE_ROOT/scripts/regen-proto.sh"

echo ""
echo "==> Worktree ready."
echo "    Reminder: use 'just run mix ...' — a bare mix picks up the system Elixir"
echo "    and corrupts _build. Wrap long suites in 'caffeinate -i'."
