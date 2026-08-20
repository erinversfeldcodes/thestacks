#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo .)"

bash "$REPO_ROOT/scripts/check-outbound-test-default.sh"
bash "$REPO_ROOT/scripts/check-route-clients.sh"
bash "$REPO_ROOT/scripts/check-mapping-truth.sh"
bash "$REPO_ROOT/scripts/check-public-route-metering.sh"
bash "$REPO_ROOT/scripts/check-oban-queue-drift.sh"
bash "$REPO_ROOT/scripts/check-dbt-model-drift.sh"
bash "$REPO_ROOT/scripts/check-phase-scheme.sh"

mix format --check-formatted
mix credo --strict

# The resolver eval replays recorded cases through the real pick logic and exits
# 1 on a regression against its pinned expectations. It has been able to gate
# since it was written; until now nothing called it, so it gated nothing — the
# same shape as a scanner that runs and whose result no one reads. It is offline
# and sub-second, so there is no reason for it not to be here.
mix eval.resolver
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
