#!/usr/bin/env bash
# test/platform/rate_limiter_bucket_drift_test.sh
#
# The rate limiter's moduledoc lists its buckets, the router requests them at
# its plug sites, and `get_limit/1` prices them. Those are three lists of the
# same set, kept in three files, and nothing compared them.
#
# ⛔ WHAT THIS SUITE EXISTS BECAUSE OF. The moduledoc's first clause advertised
# a `global` bucket at 1000/60s. All eight plug sites passed an explicit
# `bucket:`, so the default clause that served `:global` was dead code and the
# advertised limit had never applied to a single request. It was not a typo
# that survived: a reader deciding whether a new route needed a rate-limit
# pipeline would read that sentence, conclude a floor of 1000/60s sat
# underneath everything, and be wrong.
#
# ⚖️ A coverage-shaped question ("is the global bucket tested?") answered yes —
# there was a `describe` block for it. A caller-shaped question ("what in the
# application requests it?") answered nothing. The test suite was the bucket's
# only caller, which is why every gate stayed green.
#
# The same sweep found the moduledoc omitting two buckets that DO have plug
# sites, so the drift ran in both directions and only one of them was visible
# as a false claim. Hence: compare all three sets, both ways, every time.
#
# ⚠️ WHAT THIS PROVES AND DOES NOT. It proves the three lists name the same
# buckets and that no default can be reached by omission. It does NOT prove any
# ceiling is the RIGHT number, and it does not check that a route which ought to
# be limited has opted into a pipeline — an unlimited route is invisible here,
# by design, because that is a judgement about the route and not a drift.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib/assert.sh
source "$HERE/lib/assert.sh"

PLUG="$REPO_ROOT/apps/core/lib/stacks_web/plugs/rate_limiter.ex"
ROUTER="$REPO_ROOT/apps/core/lib/core_web/router.ex"

test_case "inputs_exist" "both files this suite relates are where it expects"
assert_path_exists "$PLUG" "the rate limiter plug exists"
assert_path_exists "$ROUTER" "the router exists"

# The moduledoc's bucket list is its first paragraph: from the line naming
# "Buckets:" to the first blank line. Scoping it this tightly is deliberate —
# the prose BELOW that paragraph discusses the removed default by name, and a
# whole-moduledoc grep would read that explanation as a live claim. This
# repository has made that mistake in five other guards.
DOC_PARA="$(awk '/Buckets:/{f=1} f{if (/^[[:space:]]*$/) exit; print}' "$PLUG")"
DOC_BUCKETS="$(printf '%s\n' "$DOC_PARA" | grep -oE '`:[a-z0-9_]+`' | tr -d '`:' | sort -u)"

# Every plug site in the router, and every bucket `get_limit/1` prices.
# ⚠️ The character class MUST allow digits: `:e2e_helper` contains one, and a
# `[a-z_]+` pattern silently drops it — which it did, on the first run of this
# very comparison, making the sets look equal when they were not.
ROUTER_BUCKETS="$(grep -oE 'bucket: :[a-z0-9_]+' "$ROUTER" | sed 's/.*: ://' | sort -u)"
LIMIT_BUCKETS="$(grep -oE 'defp get_limit\(:[a-z0-9_]+\)' "$PLUG" | sed 's/.*(://; s/)//' | sort -u)"

test_case "every_list_is_non_empty" \
    "a comparison of two empty sets passes while proving nothing"
assert_exit_zero "$([[ -n "$DOC_BUCKETS" ]] && echo 0 || echo 1)" \
    "the moduledoc's bucket paragraph was found and names at least one bucket"
assert_exit_zero "$([[ -n "$ROUTER_BUCKETS" ]] && echo 0 || echo 1)" \
    "the router names at least one bucket at a plug site"
assert_exit_zero "$([[ -n "$LIMIT_BUCKETS" ]] && echo 0 || echo 1)" \
    "get_limit/1 prices at least one bucket"

doc_only="$(comm -23 <(printf '%s\n' "$DOC_BUCKETS") <(printf '%s\n' "$ROUTER_BUCKETS"))"
router_only="$(comm -13 <(printf '%s\n' "$DOC_BUCKETS") <(printf '%s\n' "$ROUTER_BUCKETS"))"

test_case "the_moduledoc_lists_exactly_what_the_router_requests" \
    "a bucket named in prose and requested by nothing is a documented control that does not exist"
assert_contains "ONLY_IN_MODULEDOC:[${doc_only//$'\n'/ }]" "ONLY_IN_MODULEDOC:[]" \
    "no bucket is advertised in the moduledoc that no plug site requests"
assert_contains "ONLY_IN_ROUTER:[${router_only//$'\n'/ }]" "ONLY_IN_ROUTER:[]" \
    "no bucket is requested by a plug site that the moduledoc omits"

limit_only="$(comm -23 <(printf '%s\n' "$LIMIT_BUCKETS") <(printf '%s\n' "$ROUTER_BUCKETS"))"
unpriced="$(comm -13 <(printf '%s\n' "$LIMIT_BUCKETS") <(printf '%s\n' "$ROUTER_BUCKETS"))"

test_case "every_priced_bucket_is_requested_and_every_requested_bucket_is_priced" \
    "a priced bucket nobody requests is the dead clause this suite was written for"
assert_contains "PRICED_BUT_UNREQUESTED:[${limit_only//$'\n'/ }]" "PRICED_BUT_UNREQUESTED:[]" \
    "get_limit/1 prices no bucket that the router never asks for"
assert_contains "REQUESTED_BUT_UNPRICED:[${unpriced//$'\n'/ }]" "REQUESTED_BUT_UNPRICED:[]" \
    "every bucket the router asks for has a get_limit/1 clause"

test_case "omission_cannot_reach_a_bucket" \
    'the defect was reachable only by leaving the bucket out, so leaving it out must fail'
assert_not_contains "$(cat "$PLUG")" "defp get_limit(_)" \
    "get_limit/1 has no catch-all clause to answer for an undefined bucket"
assert_contains "$(cat "$PLUG")" "Keyword.fetch!(opts, :bucket)" \
    "call/2 fetches the bucket rather than defaulting it"
assert_contains "$(cat "$PLUG")" "requires an explicit" \
    "init/1 refuses a plug site that names no bucket"

summarise
