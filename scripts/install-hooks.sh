#!/usr/bin/env bash
# Installs git hooks by symlinking scripts/hooks/* into .git/hooks/.
# Idempotent — safe to run multiple times.
#
# Usage: bash scripts/install-hooks.sh
#        just install-hooks

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOKS_SRC="$REPO_ROOT/scripts/hooks"
HOOKS_DST="$REPO_ROOT/.git/hooks"

if [[ ! -d "$HOOKS_DST" ]]; then
    echo "ERROR: .git/hooks directory not found. Are you in a git repository?" >&2
    exit 1
fi

install_hook() {
    local name="$1"
    local src="$HOOKS_SRC/$name"
    local dst="$HOOKS_DST/$name"

    if [[ ! -f "$src" ]]; then
        echo "  skip  $name (not found in scripts/hooks/)"
        return
    fi

    chmod +x "$src"

    if [[ -L "$dst" && "$(readlink "$dst")" == "$src" ]]; then
        echo "  ok    $name (already linked)"
    elif [[ -f "$dst" && ! -L "$dst" ]]; then
        echo "  skip  $name (.git/hooks/$name exists and is not a symlink — remove it manually to install)"
    else
        ln -sf "$src" "$dst"
        echo "  link  $name -> scripts/hooks/$name"
    fi
}

echo "Installing git hooks..."
install_hook "pre-push"
echo "Done. Use 'git push --no-verify' to skip hooks on a push."
