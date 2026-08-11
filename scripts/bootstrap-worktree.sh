#!/usr/bin/env bash

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
    echo "    Regenerating the proto artefacts instead, which is the step that"
    echo "    does apply here. (Same as: just regen-proto)"
    echo ""
    exec bash "$WORKTREE_ROOT/scripts/regen-proto.sh"
fi

echo "==> Bootstrapping worktree"
echo "    worktree: $WORKTREE_ROOT"
echo "    seed from: $SOURCE_CHECKOUT"

if [[ -f "$SOURCE_CHECKOUT/.env" && ! -f "$WORKTREE_ROOT/.env" ]]; then
    cp "$SOURCE_CHECKOUT/.env" "$WORKTREE_ROOT/.env"
    echo "    .env copied"
else
    echo "    .env present or unavailable — skipped"
fi

if [[ -d "$SOURCE_CHECKOUT/apps/core/lib/stacks/gen" ]]; then
    mkdir -p "$WORKTREE_ROOT/apps/core/lib/stacks"
    rsync -a --delete \
        "$SOURCE_CHECKOUT/apps/core/lib/stacks/gen/" \
        "$WORKTREE_ROOT/apps/core/lib/stacks/gen/"
    echo "    apps/core/lib/stacks/gen/ seeded"
else
    echo "    WARNING: no gen/ in the source checkout — run 'mix proto.sync' there first." >&2
fi

if [[ -f "$SOURCE_CHECKOUT/apps/core/assets/index.html" ]]; then
    mkdir -p "$WORKTREE_ROOT/apps/core/priv/static"
    cp "$SOURCE_CHECKOUT/apps/core/assets/index.html" \
        "$WORKTREE_ROOT/apps/core/priv/static/index.html"
    echo "    priv/static/index.html copied"
fi

for dir in frontend apps/core/assets; do
    if [[ -d "$SOURCE_CHECKOUT/$dir/node_modules" && ! -e "$WORKTREE_ROOT/$dir/node_modules" ]]; then
        ln -s "$SOURCE_CHECKOUT/$dir/node_modules" "$WORKTREE_ROOT/$dir/node_modules"
        echo "    $dir/node_modules linked"
    fi
done

echo "==> mix deps.get"
(cd "$WORKTREE_ROOT" && mix deps.get >/dev/null)

echo "==> Generating proto artefacts (all five targets)"
bash "$WORKTREE_ROOT/scripts/regen-proto.sh"

echo ""
echo "==> Worktree ready."
echo "    Reminder: use 'just run mix ...' — a bare mix picks up the system Elixir"
echo "    and corrupts _build. Wrap long suites in 'caffeinate -i'."
