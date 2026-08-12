#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$DIR/../.." && pwd)"

if [[ -f "$REPO_ROOT/.env" ]]; then
  set -a
  source "$REPO_ROOT/.env"
  set +a
fi

export REPLICATE_API_TOKEN="${REPLICATE_TOKEN:-}"

exec "$DIR/.venv/bin/python" "$DIR/project_tools.py"
