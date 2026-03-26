#!/usr/bin/env bash
# scripts/gen-rust-proto.sh — Generate serde structs for Rust services from proto definitions.
#
# Proto is the source of truth. Rust types are generated, not hand-written.
#
# Usage:
#   scripts/gen-rust-proto.sh          # generate all Rust targets
#   scripts/gen-rust-proto.sh --check  # verify generated files match proto; exit 1 on drift

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v buf &>/dev/null; then
    echo "ERROR: buf not installed (brew install bufbuild/buf/buf)" >&2
    exit 1
fi

# Only --check is accepted; --language is fixed to this wrapper's language.
CHECK_FLAG=""
for arg in "$@"; do
    if [[ "$arg" == "--check" ]]; then
        CHECK_FLAG="--check"
    else
        echo "ERROR: Unknown argument '$arg'. Only --check is accepted by this wrapper." >&2
        exit 1
    fi
done

echo "==> Generating Rust serde structs from proto definitions..." >&2
python3 "$REPO_ROOT/scripts/gen_python_proto.py" --language rust ${CHECK_FLAG:+$CHECK_FLAG}
