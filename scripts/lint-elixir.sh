#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo .)"

bash "$REPO_ROOT/scripts/check-outbound-test-default.sh"
bash "$REPO_ROOT/scripts/check-route-clients.sh"
bash "$REPO_ROOT/scripts/check-mapping-truth.sh"

mix format --check-formatted
mix credo --strict
# Build/refresh the PLT from the UMBRELLA ROOT before analysing the child.
#
# `mix dialyzer` inside an umbrella child prints "In an Umbrella child, not
# checking PLT..." and runs with `check_plt: false` — so it will happily analyse
# against a PLT built before the dependency list changed, and report functions
# from newly-added deps as though they do not exist. That is not hypothetical:
# this lane failed for over a week with `SweetXml.xpath/2 does not exist` while
# `{:sweet_xml, "~> 0.7"}` sat in apps/core/mix.exs, because the PLT predated it.
# Running `--plt` from the root is what actually refreshes it; from the child it
# is a no-op. It is fast when the PLT is already current.
mix dialyzer --plt
(cd apps/core && mix dialyzer)
(cd apps/core && mix sobelow --config)
# cowlib GHSA-g2wm-735q-3f56 (low, cookie request header injection in
# cow_cookie:cookie/1) has no patched release as of 2026-05-20 — affects
# all 2.9.0..2.16.1. We don't construct cookies via cow_cookie:cookie/1
# from untrusted input, so the advisory is non-exploitable here. Revisit
# this suppression after every cowlib bump; remove once upstream ships a
# fix.
mix deps.audit --ignore-advisory-ids GHSA-g2wm-735q-3f56
