#!/usr/bin/env bash
# scripts/lib/python-tools.sh — sourced helper; do not execute directly.
#
# Exports: ensure_python_tools_path, require_dbt_core, require_sqlfluff
#
# Inside the nix dev shell the flake shellHook sets STACKS_DEV_SHELL=1 and
# prepends .venv-tools/bin (pinned dbt-core, sqlfluff, dbt-checkpoint), so
# PATH is left untouched there — the pinned tools must keep winning.
#
# Outside the shell, two things go wrong on a stock macOS setup:
#   1. `pip3 install --user` (the ci.sh "dbt: deps" self-bootstrap) drops
#      entrypoints into the Python user base (~/Library/Python/X.Y/bin),
#      which is not on PATH — `sqlfluff` is simply not found.
#   2. A Homebrew-installed *dbt Cloud CLI* also names its binary `dbt`,
#      so a bare `dbt` silently resolves to the wrong product and tries
#      to send the project to dbt Cloud.
#
# ensure_python_tools_path fixes (1) by prepending .venv-tools/bin (if
# provisioned by ./setup.sh) and the *active* interpreter's user base via
# `python3 -m site --user-base` — deliberately not globbing
# ~/Library/Python/*/bin, which previously surfaced stale wrappers from
# old toolchains that import-failed at runtime.
# require_dbt_core fixes (2) by failing fast when `dbt` is the Cloud CLI.

ensure_python_tools_path() {
    # Inside the dev shell the shellHook already exposes the pinned tools;
    # prepending anything here could shadow them.
    if [[ -n "${STACKS_DEV_SHELL:-}" ]]; then
        return 0
    fi

    local repo_root
    repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

    # Python user base first (lower priority — prepended first).
    local user_base
    user_base="$(python3 -m site --user-base 2>/dev/null || true)"
    if [[ -n "$user_base" && -d "$user_base/bin" ]]; then
        export PATH="$user_base/bin:$PATH"
    fi

    # Pinned .venv-tools/ wins over the user base when provisioned.
    if [[ -d "$repo_root/.venv-tools/bin" ]]; then
        export PATH="$repo_root/.venv-tools/bin:$PATH"
    fi
}

# Fail fast unless `dbt` resolves to dbt-core (not the dbt Cloud CLI, whose
# Homebrew binary shares the same name and identifies itself as
# "dbt Cloud CLI" in --version output; dbt-core prints "Core: / installed:").
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
