#!/usr/bin/env bash
set -euo pipefail

if ! command -v buf &>/dev/null; then
    echo "ERROR: 'buf' is not installed. Install it to lint proto schemas." >&2
    echo "  macOS: brew install bufbuild/buf/buf" >&2
    exit 1
fi

# Skip gracefully if no .proto files exist yet (freshly scaffolded project).
if ! find proto/ -name "*.proto" -print -quit 2>/dev/null | grep -q .; then
    echo "No .proto files found in proto/ — skipping."
    exit 0
fi

# buf v2 requires running from inside the module directory (where buf.yaml lives).
(cd proto && buf lint)

# Backward-compatibility check — only run if origin/main already has .proto files.
# Skipped on first-commit of proto schemas (no baseline to compare against).
# Set BUF_BREAKING_SKIP=1 for branches with intentional breaking changes (e.g., proto migration).
if [[ "${BUF_BREAKING_SKIP:-}" == "1" ]]; then
    echo "BUF_BREAKING_SKIP=1 — skipping buf breaking check (intentional migration)."
elif git rev-parse --verify origin/main &>/dev/null 2>&1; then
    if git ls-tree -r origin/main --name-only 2>/dev/null | grep -q '\.proto$'; then
        (cd proto && buf breaking --against '../.git#branch=origin/main,subdir=proto')
    else
        echo "No .proto files on origin/main — skipping buf breaking check."
    fi
fi

# Proto-to-schema drift check — ensures generated Ecto schemas and dbt models
# match the proto definitions in proto/persisted.exs.
if [ -f proto/persisted.exs ]; then
    (cd apps/core && mix proto.sync --check)
fi

# Elm proto decoder drift check — ensures generated Elm modules match proto specs.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -x "$REPO_ROOT/scripts/gen-elm-proto.sh" ]]; then
    bash "$REPO_ROOT/scripts/gen-elm-proto.sh" --check
fi
