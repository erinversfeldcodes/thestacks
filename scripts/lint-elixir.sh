#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo .)"

# Every outbound HTTP transport must be seam-selected with a :test default (#381e) —
# the class behind #377/#379: "flaky" tests that were actually dialling the internet.
bash "$REPO_ROOT/scripts/check-outbound-test-default.sh"

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
