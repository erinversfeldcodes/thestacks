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
# ⚠️ WHAT THIS PROVES AND DOES NOT, and the first version of this paragraph was
# read too generously — by its own author, in a review of this very suite.
#
# It proves four things: the three lists name the same buckets; no default can be
# reached by omission; every FIGURE the moduledoc advertises matches the module
# attribute that supplies it; and every advertised window matches `@window_ms`.
#
# It does NOT prove a ceiling is the RIGHT number — whether 60/60s is adequate
# protection for `/api/auth/login` is a policy judgement no guard can make. And
# it does not check that a route which ought to be limited has opted into a
# pipeline; an unlimited route is invisible here, by design, because that too is
# a judgement about the route rather than a drift.
#
# ⛔ The distinction matters because the first version said only "it does NOT
# prove any ceiling is the RIGHT number", two lines above a check that also did
# not compare the documented figure against the coded one. Those are different
# claims — one is policy, the other is pure drift — and the sentence collapsed
# into the weaker reading. MEASURED: with the figures unchecked, the moduledoc
# could advertise `:auth` at 9999/60s against `@auth_limit 60` and this suite
# passed 12/0 while the unit suite passed 29/0. A reader acting on that sentence
# would conclude brute-force protection was effectively absent — the identical
# mistake the `global 1000/60s` claim invited, in the value rather than the key.

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

# ⛔ FLATTENED TO ONE LINE BEFORE THE PAIRS ARE READ, and this is not a
# stylistic choice — a line-oriented extractor is WRONG here and was measured
# wrong before it shipped. The moduledoc paragraph wraps mid-entry:
#
#     `:public` 200/60s per IP; `:admin`
#     30/60s per IP; `:e2e_helper` 10/60s per IP;
#
# so `grep -oE '`:x` N/Ns'` per line finds 7 pairs for 8 buckets and drops
# `:admin` in silence. That is the fourth instance in this one guard of a
# pattern that made two sets look comparable when one was short, which is why
# the count assertion below exists rather than being implied.
DOC_ONE_LINE="$(printf '%s\n' "$DOC_PARA" | tr '\n' ' ' | tr -s ' ')"
DOC_PAIRS="$(printf '%s' "$DOC_ONE_LINE" | grep -oE '`:[a-z0-9_]+` [0-9]+/[0-9]+s' | sed 's/`//g; s/^://; s|/| |; s/s$//' | sort -u)"

DOC_PAIR_COUNT="$(printf '%s\n' "$DOC_PAIRS" | grep -c . || true)"
DOC_NAME_COUNT="$(printf '%s\n' "$DOC_BUCKETS" | grep -c . || true)"

test_case "every_documented_bucket_carries_a_readable_figure" \
    "a pair this extractor cannot read is a figure that goes unchecked, silently"
assert_contains "PAIRS:${DOC_PAIR_COUNT} NAMES:${DOC_NAME_COUNT}" \
    "PAIRS:${DOC_NAME_COUNT} NAMES:${DOC_NAME_COUNT}" \
    "every bucket named in the paragraph also yielded a figure the comparison can use"

# The attributes that supply those figures. `@window_ms` is deliberately NOT
# matched here — it does not end in `_limit`, and it is compared separately
# below because every entry shares it.
# ⚠️ The underscore is stripped from the NUMBER only. The first version of this
# line ran `tr -d '_'` over the whole pair, which turned `password_change 20`
# into `passwordchange 20` and `e2e_helper 10` into `e 2ehelper` — so every
# multi-word bucket reported as drift and the comparison was unusable. Two of
# the eight bucket names contain an underscore and one contains a digit; both
# have now broken an extractor in this file.
ATTR_PAIRS="$(grep -oE '^[[:space:]]*@[a-z0-9_]+_limit [0-9_]+' "$PLUG" |
    sed -E 's/^[[:space:]]*@//; s/_limit +/ /' |
    awk '{ gsub(/_/, "", $2); print $1, $2 }' |
    sort -u)"

test_case "the_documented_figures_are_the_coded_figures" \
    "a moduledoc advertising a ceiling the code does not set is this suite's founding defect, in the value instead of the key"
doc_figures="$(printf '%s\n' "$DOC_PAIRS" | awk 'NF{print $1, $2}' | sort -u)"
attr_figures="$(printf '%s\n' "$ATTR_PAIRS" | awk 'NF{print $1, $2}' | sort -u)"

doc_fig_only="$(comm -23 <(printf '%s\n' "$doc_figures") <(printf '%s\n' "$attr_figures"))"
attr_fig_only="$(comm -13 <(printf '%s\n' "$doc_figures") <(printf '%s\n' "$attr_figures"))"

assert_contains "DOCUMENTED_BUT_NOT_CODED:[${doc_fig_only//$'\n'/ }]" "DOCUMENTED_BUT_NOT_CODED:[]" \
    "every bucket/limit pair in the moduledoc matches a module attribute"
assert_contains "CODED_BUT_NOT_DOCUMENTED:[${attr_fig_only//$'\n'/ }]" "CODED_BUT_NOT_DOCUMENTED:[]" \
    "every bucket/limit module attribute matches what the moduledoc advertises"

test_case "the_documented_window_is_the_coded_window" \
    "every entry says /60s, and one number decides whether that is true"
# ⚠️ The prefix comes off BEFORE the underscores do. Reversed, `tr -d '_'` turns
# `@window_ms` into `@windowms` and the sed that strips it no longer matches —
# which left `WINDOW_MS` holding the whole line and `$(( ))` reporting an
# arithmetic syntax error. Measured, not reasoned: that is what this line did
# on its first run.
#
# ⛔ THE FIRST `@window_ms` LINE, MATCHED WITHOUT REGARD TO ITS VALUE, and this
# is the correction of a hole in the first version of this check.
#
# `RateLimiter.Server` further down the same file declares its own
# `@window_ms 60_000`, so there are two. The first version grepped for
# `@window_ms [0-9_]+` and took `head -1` — which means that when the PLUG's
# attribute stopped being a bare number, the pattern skipped it and `head -1`
# silently returned the SERVER's. MEASURED: planting
# `@window_ms :timer.minutes(1)` in the plug left this suite passing 16/0,
# comparing the moduledoc against a different module's window.
#
# So the line is selected by NAME and the value is validated afterwards. An
# unreadable value now refuses instead of falling through to the next
# declaration — the distinction between "I read it and it disagrees" and "I
# could not read it", which this repository has paid for six times.
WINDOW_MS="$(grep -nE '^[[:space:]]*@window_ms ' "$PLUG" | head -1 |
    sed -E 's/^[0-9]+:[[:space:]]*@window_ms +//' | tr -d '_')"

if [[ ! "$WINDOW_MS" =~ ^[0-9]+$ ]]; then
    echo "FAIL: could not read @window_ms from $PLUG (got '${WINDOW_MS}'), so the" >&2
    echo "      window comparison below would be against nothing." >&2
    exit 1
fi

WINDOW_S="$((WINDOW_MS / 1000))"
doc_windows="$(printf '%s\n' "$DOC_PAIRS" | awk 'NF{print $3}' | sort -u)"
assert_contains "WINDOWS:[${doc_windows//$'\n'/ }] CODED:[${WINDOW_S}]" \
    "WINDOWS:[${WINDOW_S}] CODED:[${WINDOW_S}]" \
    "the moduledoc advertises exactly one window and it is @window_ms"

test_case "omission_cannot_reach_a_bucket" \
    'the defect was reachable only by leaving the bucket out, so leaving it out must fail'
assert_not_contains "$(cat "$PLUG")" "defp get_limit(_)" \
    "get_limit/1 has no catch-all clause to answer for an undefined bucket"
assert_contains "$(cat "$PLUG")" "Keyword.fetch!(opts, :bucket)" \
    "call/2 fetches the bucket rather than defaulting it"
assert_contains "$(cat "$PLUG")" "requires an explicit" \
    "init/1 refuses a plug site that names no bucket"

summarise
