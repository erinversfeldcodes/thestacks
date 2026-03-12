#!/usr/bin/env bash
# Installs git hooks and ensures Claude Code hook scripts are executable.
# Idempotent — safe to run multiple times.
#
# Git hooks:    symlinks scripts/hooks/* into .git/hooks/
# Claude hooks: .claude/settings.json is auto-loaded by Claude Code;
#               this script just ensures the hook scripts are executable.
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

# ── Claude Code hooks ──────────────────────────────────────────────────────────
# .claude/settings.json is checked in and auto-loaded by Claude Code when it
# opens this project — no registration step needed. We just ensure the hook
# scripts are executable (git preserves this on Unix, but not always on Windows
# or after certain git operations).
echo ""
echo "Ensuring Claude Code hook scripts are executable..."
CLAUDE_HOOK_SCRIPTS=(
    "$REPO_ROOT/.claude/hooks/post-tool-lint.sh"
    "$REPO_ROOT/scripts/hooks/lib/pre-stop-lint.sh"
)
for hook in "${CLAUDE_HOOK_SCRIPTS[@]}"; do
    if [[ -f "$hook" ]]; then
        chmod +x "$hook"
        echo "  ok    $(basename "$hook")"
    else
        echo "  miss  $(basename "$hook") (not found — run git pull?)"
    fi
done
echo "Claude Code hooks active. They fire automatically in every Claude Code session for this project."
