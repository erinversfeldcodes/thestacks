#!/usr/bin/env bash
set -euo pipefail

# gen-elm-proto.sh — Generate Elm decoders/encoders from Protobuf schemas.
#
# Wraps `buf generate` for the Elm target. Generated files are checked in
# (no runtime codegen) per the project convention in CLAUDE.md.
#
# Prerequisites: buf, protoc-gen-elm (npm install -g protoc-gen-elm)

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v buf &>/dev/null; then
    echo "ERROR: 'buf' is not installed." >&2
    echo "  macOS: brew install bufbuild/buf/buf" >&2
    exit 1
fi

echo "==> Generating Elm code from proto schemas..."
(cd "$REPO_ROOT/proto" && buf generate)
echo "==> Done."
