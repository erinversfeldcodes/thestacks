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

buf lint proto/
