#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ $# -ne 1 || -z "${1:-}" ]]; then
    echo "usage: scripts/generated-file-class.sh <path>" >&2
    exit 2
fi

TARGET="$1"

if git -C "$REPO_ROOT" ls-files --error-unmatch -- "$TARGET" >/dev/null 2>&1; then
    echo tracked
elif git -C "$REPO_ROOT" check-ignore -q -- "$TARGET" 2>/dev/null; then
    echo ignored
else
    echo untracked
fi
