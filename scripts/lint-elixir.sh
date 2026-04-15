#!/usr/bin/env bash
set -euo pipefail

mix format --check-formatted
mix credo --strict
mix dialyzer
(cd apps/core && mix sobelow --config)
mix deps.audit
