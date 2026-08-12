#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v buf &>/dev/null; then
    echo "ERROR: buf not installed (brew install bufbuild/buf/buf)" >&2
    exit 1
fi

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
