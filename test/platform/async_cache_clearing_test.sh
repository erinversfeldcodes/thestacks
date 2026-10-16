#!/usr/bin/env bash
# test/platform/async_cache_clearing_test.sh
#
# A test that clears a process-wide cache must not run concurrently with others.
#
# `invalidate_all/0` on each of the four caches is `:ets.delete_all_objects` on
# a `:named_table, :public` table shared by the entire run. Called from an
# `async: true` file's `setup`, it wipes that table out from under any
# concurrent test that had put something in it.
#
# That was the cause of a race recorded as unexplained:
# `CacheInvalidationHandlerTest` "ignores unrelated events" failed once under
# seed 564411 and then PASSED on a re-run of the same seed — the signature of
# concurrency, not of ordering. The investigation correctly ruled out a key
# collision (the handler test uniquifies its ids) and expiry (the cache's 300s
# TTL and 60s sweep both outlast a whole suite run), and stopped there.
#
# ⚠️ What makes this worth a gate rather than a one-line fix: eleven of the
# twelve files that clear a shared cache were ALREADY `async: false`. The
# convention existed and was followed almost everywhere, which is exactly the
# situation where the single exception goes unnoticed — it looks like the
# others, and the failure it causes lands in a different file.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib/assert.sh
source "$HERE/lib/assert.sh"

TEST_ROOT="$REPO_ROOT/apps/core/test"

test_case "inputs_exist" "the Elixir test tree is present"
assert_path_exists "$TEST_ROOT" "apps/core/test exists"

# Files that call `invalidate_all()` AND declare `async: true`. Both facts are
# read from each file, so neither the roster of caches nor the list of callers
# is written down here — a new cache, or a new caller, is covered.
OFFENDERS=""
CLEARING_FILES=0

while IFS= read -r file; do
    [[ -z "$file" ]] && continue
    CLEARING_FILES=$((CLEARING_FILES + 1))
    # ⚠️ Matched on the `use` LINE, not on the first `async:` in the file.
    #
    # Reading the first occurrence anywhere is what a careless version did, and
    # it silently stopped working the moment the fixed file gained a moduledoc
    # explaining why it is `async: false` — the prose matched first, the gate
    # reported compliance, and a planted `async: true` went undetected. The
    # declaration lives on a `use` line; nothing else is the declaration.
    async="$(grep -oE '^[[:space:]]*use [A-Za-z0-9_.]+,[[:space:]]*async:[[:space:]]*(true|false)' "$file" |
        head -1 | grep -oE '(true|false)$')"
    if [[ "$async" == "true" ]]; then
        OFFENDERS="${OFFENDERS}${file#"$REPO_ROOT/"}"$'\n'
    fi
done < <(grep -rl "invalidate_all()" "$TEST_ROOT" --include="*.exs" 2>/dev/null | sort)

test_case "the_sweep_found_the_callers" "the search actually located the cache-clearing tests"
# Anti-vacuity: the assertion below is a list-is-empty, which an empty sweep
# satisfies. If `invalidate_all` is ever renamed, this fails rather than
# reporting that every file complies.
if [[ "$CLEARING_FILES" -ge 8 ]]; then
    _record_pass "found $CLEARING_FILES test file(s) that clear a shared cache"
else
    _record_fail "only $CLEARING_FILES file(s) appear to clear a shared cache — expected at least eight, so this sweep is not finding the callers it is written for (was invalidate_all/0 renamed?)"
fi

test_case "no_async_file_clears_a_shared_cache" "clearing a global table forces async: false"
if [[ -z "${OFFENDERS//[$'\n']/}" ]]; then
    _record_pass "every cache-clearing test file is async: false"
else
    _record_fail "these test file(s) call invalidate_all() while async: true, so they wipe a shared ETS table out from under concurrent tests — the cause of the 'ignores unrelated events' race: ${OFFENDERS//$'\n'/ }"
fi

summarise
