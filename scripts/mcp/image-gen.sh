#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Load .env to get REPLICATE_TOKEN
if [[ -f "$REPO_ROOT/.env" ]]; then
  set -a
  source "$REPO_ROOT/.env"
  set +a
fi

# Map to the env var the server expects
export REPLICATE_API_TOKEN="${REPLICATE_TOKEN:-}"

exec npx @gongrzhe/image-gen-server
