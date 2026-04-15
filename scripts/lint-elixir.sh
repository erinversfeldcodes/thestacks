#!/usr/bin/env bash
set -euo pipefail

mix format --check-formatted
mix credo --strict
mix dialyzer
env MIX_ENV=dev mix sobelow --config
mix deps.audit
