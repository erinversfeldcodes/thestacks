#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v buf &>/dev/null; then
    echo "ERROR: 'buf' is not installed. Install it to lint proto schemas." >&2
    echo "  macOS: brew install bufbuild/buf/buf" >&2
    exit 1
fi

# `find … -quit | grep -q .` is safe only because `-quit` makes find exit after
# the first path, so it is never still writing when grep leaves. That is a
# property of the flags rather than of the form, and the next edit to this line
# will not know it — so capture instead, and the safety stops depending on a
# reader noticing `-quit`.
_first_proto="$(find "$REPO_ROOT/proto" -name "*.proto" -print -quit 2>/dev/null || true)"
if [[ -z "$_first_proto" ]]; then
    echo "No .proto files found in proto/ — skipping."
    exit 0
fi

(cd "$REPO_ROOT/proto" && buf lint)

if [[ "${BUF_BREAKING_SKIP:-}" == "1" ]]; then
    echo "BUF_BREAKING_SKIP=1 — skipping buf breaking check (intentional migration)."
elif git rev-parse --verify origin/main &>/dev/null 2>&1; then
    # Captured first: `git ls-tree | grep -q` returns 141 under `pipefail` once
    # the tree listing is bigger than the pipe buffer and a .proto path matches
    # before git finishes writing. That would take the else branch and SKIP
    # `buf breaking` — losing contract protection without saying so.
    _main_tree="$(git ls-tree -r origin/main --name-only 2>/dev/null || true)"
    if grep -q '\.proto$' <<< "${_main_tree}"; then
        (cd "$REPO_ROOT/proto" && buf breaking --against '../.git#branch=origin/main,subdir=proto')
    else
        echo "No .proto files on origin/main — skipping buf breaking check."
    fi
fi

python3 "$REPO_ROOT/scripts/check-enum-coverage.py"

if [[ "${CI:-}" != "true" ]]; then
    if [[ -x "$REPO_ROOT/scripts/gen-elm-proto.sh" ]]; then
        bash "$REPO_ROOT/scripts/gen-elm-proto.sh" --check
    fi
    bash "$REPO_ROOT/scripts/gen-python-proto.sh" --check
    bash "$REPO_ROOT/scripts/gen-rust-proto.sh" --check
    bash "$REPO_ROOT/scripts/gen-elixir-proto.sh" --check
fi
