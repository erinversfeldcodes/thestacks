#!/usr/bin/env bash
# Run the project-tools MCP server's own test suite.
#
# This suite existed for months with NO caller — on its first-ever run, three
# tests failed, one because a repo-wide sweep had mutilated its fixtures and
# nothing noticed. A test file nothing runs is documentation that lies.
#
# Runs from scripts/mcp/ (the modules import each other by sibling name) in the
# venv the MCP server itself uses, creating it if absent (fresh clone / CI).
set -euo pipefail
cd "$(git rev-parse --show-toplevel)/scripts/mcp"
if [ ! -x .venv/bin/python ]; then
    python3 -m venv .venv
    .venv/bin/pip install --quiet -r requirements.txt
fi
exec .venv/bin/python -m unittest test_project_tools "$@"
