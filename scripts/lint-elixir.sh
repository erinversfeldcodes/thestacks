#!/usr/bin/env bash
set -euo pipefail

mix format --check-formatted
mix credo --strict
mix dialyzer
# Sobelow exit 2 = warnings (not vulnerabilities). In CI, a cached _build/test
# from gen-ecto-proto.sh includes compiled test/support/ modules that trigger
# "unknown function" warnings for ExUnit refs. ignore_files in .sobelow-conf
# handles this on clean builds; the exit code guard handles cached builds.
sobelow_rc=0
(cd apps/core && mix sobelow --config) || sobelow_rc=$?
if [[ $sobelow_rc -eq 1 ]]; then exit 1; fi
mix deps.audit
