#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# sqlfluff lives in .venv-tools/ — flake.nix shellHook prepends that to PATH
# inside the dev shell. Outside it, python-tools.sh surfaces .venv-tools/bin
# and the active interpreter's pip --user bin (see that file for rationale;
# it intentionally avoids the old ~/Library/Python/*/bin glob that surfaced
# stale wrappers).
# shellcheck source=scripts/lib/python-tools.sh
source "$REPO_ROOT/scripts/lib/python-tools.sh"
ensure_python_tools_path
require_sqlfluff

TEMPLATER="${SQLFLUFF_TEMPLATER:-jinja}"

(cd dbt && sqlfluff lint models/ --templater "$TEMPLATER")
