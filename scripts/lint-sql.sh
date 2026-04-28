#!/usr/bin/env bash
set -euo pipefail

# sqlfluff lives in .venv-tools/ — flake.nix shellHook prepends that to PATH.
# (Earlier versions of this script also globbed ~/Library/Python/*/bin onto
# PATH to surface user-site --user installs; that path now contains stale
# wrappers from a previous toolchain that import-fail at runtime, so it
# beat the venv to the punch and broke the lint. Trust shellHook to
# expose the venv and don't second-guess PATH here.)

# Default to jinja templater (offline-friendly, no dbt profile/DB required).
# CI sets SQLFLUFF_TEMPLATER=dbt for full macro resolution against a live database.
TEMPLATER="${SQLFLUFF_TEMPLATER:-jinja}"

(cd dbt && sqlfluff lint models/ --templater "$TEMPLATER")
