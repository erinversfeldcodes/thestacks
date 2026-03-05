#!/usr/bin/env bash
set -euo pipefail

# Ensure pip-installed tools (sqlfluff) are on PATH.
for pybin in "$HOME"/Library/Python/*/bin; do
    [[ -d "$pybin" ]] && export PATH="$pybin:$PATH"
done

# Default to jinja templater (offline-friendly, no dbt profile/DB required).
# CI sets SQLFLUFF_TEMPLATER=dbt for full macro resolution against a live database.
TEMPLATER="${SQLFLUFF_TEMPLATER:-jinja}"

(cd dbt && sqlfluff lint models/ --templater "$TEMPLATER")
