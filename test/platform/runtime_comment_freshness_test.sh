#!/usr/bin/env bash
# test/platform/runtime_comment_freshness_test.sh
#
# Phase 3 fold-in: lock out stale 6PN-allowlist prose in config/runtime.exs.
# MetricsAuth is bearer-only (per StacksWeb.Plugs.MetricsAuth @moduledoc);
# the old comment near `metrics_scrape_token` still claimed 6PN callers
# bypass the check. This test FAILS until that comment is refreshed.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib/assert.sh
source "$HERE/lib/assert.sh"

RUNTIME_EXS="$REPO_ROOT/config/runtime.exs"

test_case "runtime_exs_exists" "config/runtime.exs must be present"
if [[ -f "$RUNTIME_EXS" ]]; then
    _record_pass "runtime.exs exists"
else
    _record_fail "runtime.exs not found at $RUNTIME_EXS"
    summarise
    exit $?
fi

CONTENT="$(cat "$RUNTIME_EXS")"

STALE_SNIPPETS=(
    "6PN callers"
    "only 6PN callers can scrape"
    "Fly 6PN callers bypass"
)

test_case "no_stale_6pn_prose" "stale 6PN-bypass phrases must be gone"
for snippet in "${STALE_SNIPPETS[@]}"; do
    if [[ "$CONTENT" == *"$snippet"* ]]; then
        _record_fail "stale snippet present: '$snippet'"
    else
        _record_pass "no stale snippet: '$snippet'"
    fi
done

summarise
