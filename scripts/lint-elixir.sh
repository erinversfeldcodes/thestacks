#!/usr/bin/env bash
set -euo pipefail

mix format --check-formatted
mix credo --strict
(cd apps/core && mix dialyzer)
(cd apps/core && mix sobelow --config)
# cowlib GHSA-g2wm-735q-3f56 (low, cookie request header injection in
# cow_cookie:cookie/1) has no patched release as of 2026-05-20 — affects
# all 2.9.0..2.16.1. We don't construct cookies via cow_cookie:cookie/1
# from untrusted input, so the advisory is non-exploitable here. Revisit
# this suppression after every cowlib bump; remove once upstream ships a
# fix.
mix deps.audit --ignore-advisory-ids GHSA-g2wm-735q-3f56
