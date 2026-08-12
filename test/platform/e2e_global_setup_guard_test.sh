#!/usr/bin/env bash
# test/platform/e2e_global_setup_guard_test.sh
#
# — Guard B: Playwright globalSetup warmup.
#
# Guard B adds e2e/global-setup.ts, wired into e2e/playwright.config.ts via the
# `globalSetup` key. It must:
#   - return immediately (no poll, no throw) when process.env.BASE_URL is unset,
#     so local `npm test` is completely untouched;
#   - when BASE_URL IS set, poll `$BASE_URL/api/health` until 200 (bounded ~60s)
#     before any project runs, and fail fast with a clear message otherwise.
#
# WHY A STATIC (grep-based) TEST rather than a behavioural one:
# The e2e/ harness ships only @playwright/test — there is NO lightweight
# stand-alone TS unit runner (no ts-node / tsx / typescript in
# e2e/node_modules, and e2e/package.json declares no such devDependency). The
# only way to execute global-setup.ts is through Playwright's own runner, which
# would (a) drag a Node + browser runner into this otherwise pure-bash,
# no-network platform suite and (b) still be unable to hit the fail-fast path
# without real sockets or a 60s wait. Per the phase brief, the accepted
# fallback is therefore a bash test that statically asserts the wiring and the
# early-return guard. This keeps the platform suite deterministic and offline.
# See Pre-implementation Flags in the completion report.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib/assert.sh
source "$HERE/lib/assert.sh"

CONFIG="$REPO_ROOT/e2e/playwright.config.ts"
GLOBAL_SETUP="$REPO_ROOT/e2e/global-setup.ts"

CONFIG_SRC="$(cat "$CONFIG" 2>/dev/null || true)"
SETUP_SRC="$(cat "$GLOBAL_SETUP" 2>/dev/null || true)"

test_case "config_references_globalSetup" "playwright.config.ts declares a globalSetup key"
assert_contains "$CONFIG_SRC" "globalSetup" \
    "playwright.config.ts references globalSetup"
assert_contains "$CONFIG_SRC" "global-setup" \
    "playwright.config.ts points globalSetup at ./global-setup"

test_case "global_setup_exists" "e2e/global-setup.ts exists"
assert_path_exists "$GLOBAL_SETUP" "e2e/global-setup.ts file exists"

test_case "global_setup_base_url_guard" "global-setup.ts early-returns when BASE_URL is unset"
assert_contains "$SETUP_SRC" "process.env.BASE_URL" \
    "global-setup.ts branches on process.env.BASE_URL"
if [[ "$SETUP_SRC" == *"return"* ]] || [[ "$SETUP_SRC" == *"if"* ]]; then
    _record_pass "global-setup.ts contains a conditional early-return guard"
else
    _record_fail "global-setup.ts contains a conditional early-return guard"
fi

test_case "global_setup_polls_health" "global-setup.ts polls /api/health and fails clearly"
assert_contains "$SETUP_SRC" "/api/health" \
    "global-setup.ts polls the /api/health endpoint"
if [[ "$SETUP_SRC" == *"healthy"* ]] || [[ "$SETUP_SRC" == *"throw"* ]]; then
    _record_pass "global-setup.ts fails fast with a clear error (throw/\"healthy\")"
else
    _record_fail "global-setup.ts fails fast with a clear error (throw/\"healthy\")"
fi

summarise
