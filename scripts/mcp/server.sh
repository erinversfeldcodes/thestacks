#!/usr/bin/env bash
# Launches the project-tools MCP server using the local venv.
# Registered as the command in .claude/settings.json mcpServers.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$DIR/.venv/bin/python" "$DIR/project_tools.py"
