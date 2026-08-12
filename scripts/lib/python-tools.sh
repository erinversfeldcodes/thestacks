#!/usr/bin/env bash

ensure_python_tools_path() {
    if [[ -n "${STACKS_DEV_SHELL:-}" ]]; then
        return 0
    fi

    local repo_root
    repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

    local user_base
    user_base="$(python3 -m site --user-base 2>/dev/null || true)"
    if [[ -n "$user_base" && -d "$user_base/bin" ]]; then
        export PATH="$user_base/bin:$PATH"
    fi

    if [[ -d "$repo_root/.venv-tools/bin" ]]; then
        export PATH="$repo_root/.venv-tools/bin:$PATH"
    fi
}

require_dbt_core() {
    if ! command -v dbt &>/dev/null; then
        echo "ERROR: dbt not found on PATH." >&2
        echo "       Enter the nix dev shell (pinned dbt-core in .venv-tools/), or install it:" >&2
        echo "       pip3 install dbt-postgres  (the 'dbt: deps' lane in scripts/ci.sh does this)" >&2
        exit 1
    fi
    if dbt --version 2>/dev/null | grep -q "dbt Cloud CLI"; then
        echo "ERROR: dbt resolves to the dbt Cloud CLI at $(command -v dbt); the project needs dbt-core." >&2
        echo "       Run inside the nix dev shell, or ensure the dbt-core entrypoint dir" >&2
        echo "       ($(python3 -m site --user-base 2>/dev/null)/bin or .venv-tools/bin) precedes it on PATH." >&2
        exit 1
    fi
}

require_sqlfluff() {
    if ! command -v sqlfluff &>/dev/null; then
        echo "ERROR: sqlfluff not found on PATH." >&2
        echo "       Enter the nix dev shell (pinned sqlfluff in .venv-tools/), or install it:" >&2
        echo "       pip3 install sqlfluff sqlfluff-templater-dbt  (the 'dbt: deps' lane in scripts/ci.sh does this)" >&2
        exit 1
    fi
}
