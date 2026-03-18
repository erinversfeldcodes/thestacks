#!/usr/bin/env bash
# Launches the project-tools MCP server using the local venv.
# Registered as the command in .claude/settings.json mcpServers.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$DIR/../.." && pwd)"

# Load .env for API tokens (e.g. REPLICATE_TOKEN)
if [[ -f "$REPO_ROOT/.env" ]]; then
  set -a
  source "$REPO_ROOT/.env"
  set +a
fi

# Map env vars to names expected by libraries
export REPLICATE_API_TOKEN="${REPLICATE_TOKEN:-}"

exec "$DIR/.venv/bin/python" "$DIR/project_tools.py"
