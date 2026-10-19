#!/usr/bin/env bash
# test/platform/deployed_posture_test.sh
#
# `scripts/check-deployed-posture.sh`: the invariants a per-diff gate cannot see.
#
# ⚠️ Everything this checks was found by hand on 2026-10-19, and every one had
# been true for months with all existing gates green: 6,655 images past their
# expiry (oldest by 151 days) against a 30-day promise, all 91 `oban_jobs` rows
# orphaned in `executing`, and the three dbt warehouse schemas simply absent so
# every mart query errored. None of it is diff-shaped, so no amount of PR CI
# would have found any of it.
#
# ⛔ The instrument is not new — the discipline is. This project already has the
# zero-row sweep; it ran it by hand, occasionally, during campaigns. That is how
# a 151-day breach goes unnoticed for 151 days.
#
# The assertions below are about the check's MECHANICS, because its thresholds
# are verified against real databases rather than fixtures: run against
# production today it reports 3 of 4 failing, and against the campaign's preview
# branch 1 of 4 — so it discriminates rather than simply always failing.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib/assert.sh
source "$HERE/lib/assert.sh"

GATE="$REPO_ROOT/scripts/check-deployed-posture.sh"
LOCAL_URL="postgres://postgres:postgres@localhost:5432/stacks_dev"

test_case "inputs_exist" "the gate is present and parses"
assert_path_exists "$GATE" "scripts/check-deployed-posture.sh exists"
if bash -n "$GATE" 2>/dev/null; then
    _record_pass "it parses under $(bash --version | head -1)"
else
    _record_fail "it does NOT parse, so it has never run here"
fi

GATE_SRC="$(cat "$GATE" 2>/dev/null)"

test_case "an_unset_url_is_a_refusal" "it will not report health having measured nothing"
OUT="$(POSTURE_DATABASE_URL="" bash "$GATE" 2>&1)"
RC=$?
if [[ "$RC" -ne 0 ]]; then
    _record_pass "an unset POSTURE_DATABASE_URL exits non-zero (exit $RC)"
else
    _record_fail "it passed with no database to measure, which is the failure mode it exists to end"
fi
assert_contains "$OUT" "refusal, not a pass" "and says plainly that it is a refusal"

test_case "a_local_host_is_REFUSED" "the trap the repo's own .env sets"
# ⛔ `.env` here sets DATABASE_URL to localhost, and the deployed-only ExUnit
# modules skip only when their variable is UNSET rather than when it is local —
# so a "deployed" assertion run with the repo's environment loaded inspects a
# developer sandbox, where the roles exist and the invariants hold. A green there
# proves nothing about anything deployed. This gate refuses instead, the way
# dbt-deployed.sh already does.
for host in "localhost" "127.0.0.1"; do
    OUT="$(POSTURE_DATABASE_URL="postgres://u:p@${host}:5432/db" bash "$GATE" 2>&1)"
    RC=$?
    if [[ "$RC" -ne 0 ]]; then
        _record_pass "a URL pointing at ${host} is refused"
    else
        _record_fail "a URL pointing at ${host} was accepted — this check would report a clean bill of health for a machine nobody deployed"
    fi
done
assert_contains "$OUT" "points at a local host" "the refusal names the reason"

test_case "the_self_test_escape_announces_itself" \
    "a self-test run cannot be mistaken for a real measurement in a log"
# The escape exists so this suite has a database it can dirty. It is narrow, and
# the run says so on stdout — otherwise a log line reading "all assertions hold"
# would be indistinguishable from a real deployed measurement.
OUT="$(POSTURE_ALLOW_LOCAL=1 POSTURE_DATABASE_URL="$LOCAL_URL" bash "$GATE" 2>&1)"
assert_contains "$OUT" "SELF-TEST" "a self-test run labels itself"
assert_contains "$OUT" "measures nothing deployed" "and states what it does not prove"

test_case "every_assertion_actually_evaluates" "none of them errors instead of running"
# ⚠️ This is the assertion that caught a real bug. The migration-table check
# named `op.schema_migrations`, which exists on staging and production but not on
# a local database — and because Postgres resolves relation names at PARSE time,
# a `to_regclass` runtime guard did not save it. It ERRORED rather than
# evaluating, and only the anti-vacuity counter revealed that as "only 3 of 4
# ran" rather than a pass.
if printf '%s' "$OUT" | grep -q "did not return a number"; then
    _record_fail "an assertion errored instead of evaluating: $(printf '%s' "$OUT" | grep -A 2 'did not return a number' | head -3)"
else
    _record_pass "all assertions returned a number against a real database"
fi

RAN_LINE="$(printf '%s' "$OUT" | grep -oE "only [0-9]+ of [0-9]+ assertion" | head -1)"
if [[ -z "$RAN_LINE" ]]; then
    _record_pass "no assertion was skipped"
else
    _record_fail "assertions were skipped: ${RAN_LINE}"
fi

test_case "a_breached_ceiling_fails_and_explains" "it does not merely print a number"
# The local database genuinely holds a past-expiry image fixture, so the
# retention ceiling really is breached here — which makes this a behavioural
# check rather than a source grep.
if printf '%s' "$OUT" | grep -qE "^FAIL images_past_expiry"; then
    _record_pass "a breached ceiling is reported as a failure"
    assert_contains "$OUT" "retention promise is not being kept" \
        "and carries the sentence a reader needs, not just a count"
else
    _record_fail "the local database holds a past-expiry image fixture and the retention assertion did not fire — the ceiling comparison is not working"
fi

test_case "the_assertion_count_is_declared" "a dropped assertion shows up in the diff"
# Retrofitted from a real regression in the sibling posture suite: a roster built
# by appending to an array is silently shortened by an editing slip, and the loop
# then passes over whatever survived.
assert_contains "$GATE_SRC" "EXPECTED_ASSERTIONS" "the population size is declared"
assert_contains "$GATE_SRC" "declared \$EXPECTED_ASSERTIONS assertion" \
    "and a mismatch between declared and built is refused"

test_case "the_anti_vacuity_counter_is_present" "a run that measured nothing cannot read as clean"
assert_contains "$GATE_SRC" "assertion(s) ran" "it reports how many assertions evaluated"

test_case "a_connection_failure_is_reported_as_itself" \
    "not as four mysterious assertion failures"
assert_contains "$GATE_SRC" "cannot query the database" "there is a connectivity probe first"

test_case "the_four_findings_are_each_covered" \
    "the sweep that found them by hand is now a roster"
for needle in "images_past_expiry" "orphaned_executing_jobs" "warehouse_schemas_missing" \
    "unmigrated"; do
    assert_contains "$GATE_SRC" "$needle" "the roster covers ${needle}"
done

summarise
