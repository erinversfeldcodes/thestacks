#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v buf &>/dev/null; then
    echo "ERROR: 'buf' is not installed. Install it to lint proto schemas." >&2
    echo "  macOS: brew install bufbuild/buf/buf" >&2
    exit 1
fi

# Skip gracefully if no .proto files exist yet (freshly scaffolded project).
# Use an absolute path so this script is safe to invoke from any working directory.
if ! find "$REPO_ROOT/proto" -name "*.proto" -print -quit 2>/dev/null | grep -q .; then
    echo "No .proto files found in proto/ — skipping."
    exit 0
fi

# Run buf lint from inside the module directory (where buf.yaml lives).
(cd "$REPO_ROOT/proto" && buf lint)

# Backward-compatibility check — only run if origin/main already has .proto files.
# Skipped on first-commit of proto schemas (no baseline to compare against).
# Set BUF_BREAKING_SKIP=1 for branches with intentional breaking changes (e.g., proto migration).
if [[ "${BUF_BREAKING_SKIP:-}" == "1" ]]; then
    echo "BUF_BREAKING_SKIP=1 — skipping buf breaking check (intentional migration)."
elif git rev-parse --verify origin/main &>/dev/null 2>&1; then
    if git ls-tree -r origin/main --name-only 2>/dev/null | grep -q '\.proto$'; then
        (cd "$REPO_ROOT/proto" && buf breaking --against '../.git#branch=origin/main,subdir=proto')
    else
        echo "No .proto files on origin/main — skipping buf breaking check."
    fi
fi

# Proto codegen drift checks — only run locally where generated files are present.
# Generated files are gitignored so they don't exist in CI (skip silently there).
if [[ "${CI:-}" != "true" ]]; then
    if [[ -x "$REPO_ROOT/scripts/gen-elm-proto.sh" ]]; then
        bash "$REPO_ROOT/scripts/gen-elm-proto.sh" --check
    fi
    bash "$REPO_ROOT/scripts/gen-python-proto.sh" --check
    bash "$REPO_ROOT/scripts/gen-rust-proto.sh" --check
    bash "$REPO_ROOT/scripts/gen-elixir-proto.sh" --check
fi
