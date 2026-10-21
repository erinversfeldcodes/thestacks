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
if grep -q "did not return a number" <<< "$OUT"; then
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
# ⛔ PLANTS the breach rather than assuming it. This case used to rely on a
# past-expiry image that `seeds.exs` happens to insert, and the reliance was
# invisible until somebody ran the image-retention sweep against their
# development database — which is a correct thing to do, and which deletes that
# row. The suite then failed with "the ceiling comparison is not working" while
# the gate under test was perfectly fine: a green that was reporting the
# contents of one machine rather than the behaviour of the code, and a red for
# the same reason.
#
# ⚠️ Planted and removed here, so the precondition is true by construction and
# no legitimate operation elsewhere can take it away. The `POSTURE_ALLOW_LOCAL`
# escape above exists precisely so this suite has a database it may dirty.
PLANTED_IMAGE_ID="$(uuidgen 2>/dev/null || python3 -c 'import uuid;print(uuid.uuid4())')"
psql "$LOCAL_URL" -q -c "
  INSERT INTO op.uploaded_images (id, storage_path, status, uploaded_at, expires_at, created_at, updated_at)
  VALUES ('${PLANTED_IMAGE_ID}', 'uploads/posture-suite-planted', 'pending',
          now() - interval '40 days', now() - interval '10 days',
          now() - interval '40 days', now() - interval '40 days')
" >/dev/null 2>&1 || _record_fail "could not plant the past-expiry fixture this case needs"

PLANTED_COUNT="$(psql "$LOCAL_URL" -tAc \
    "SELECT count(*) FROM op.uploaded_images WHERE expires_at < now()" 2>/dev/null)"
if [[ "${PLANTED_COUNT:-0}" -ge 1 ]]; then
    _record_pass "the breach is planted (${PLANTED_COUNT} image(s) past expiry), so the ceiling really is exceeded"
else
    _record_fail "the fixture did not land, so this case would pass or fail for the wrong reason"
fi

OUT="$(POSTURE_ALLOW_LOCAL=1 POSTURE_DATABASE_URL="$LOCAL_URL" bash "$GATE" 2>&1)"

if grep -qE "^FAIL images_past_expiry" <<< "$OUT"; then
    _record_pass "a breached ceiling is reported as a failure"
    assert_contains "$OUT" "past their expiry and still present" \
        "and carries the sentence a reader needs, not just a count"
    # The roster mixes assertions about CONFIGURATION with assertions that count
    # a backlog, and the two mean different things when they fire. This one is a
    # backlog, so a reader must not be sent looking for a posture regression.
    assert_contains "$OUT" "images_past_expiry [data condition]" \
        "and says which kind of assertion it is"
    assert_contains "$OUT" "went red because work accumulated" \
        "and says what that kind of failure means"
else
    _record_fail "a past-expiry image was planted and the retention assertion did not fire — the ceiling comparison is not working"
fi

psql "$LOCAL_URL" -q -c \
    "DELETE FROM op.uploaded_images WHERE id = '${PLANTED_IMAGE_ID}'" >/dev/null 2>&1 || true

test_case "a_nullable_expiry_is_itself_the_breach" "the retention guarantee is checked, not assumed"
# ⛔ PLANTS THE SCHEMA CHANGE, because the arm under test cannot be reached any
# other way. The query used to carry `expires_at IS NOT NULL`, which was dead —
# the column is created `null: false` — but which told a reader that a null
# expiry was a legitimate state being skipped. If that ever became true, an
# image could be stored with no expiry and the row count would never see it.
#
# ⚠️ The restore runs through a trap as well as inline, so an interrupted run
# cannot leave the development database's schema relaxed. Re-adding NOT NULL is
# safe here because nothing in this case inserts a row while it is dropped.
_restore_expiry_not_null() {
    psql "$LOCAL_URL" -q -c \
        "ALTER TABLE op.uploaded_images ALTER COLUMN expires_at SET NOT NULL" >/dev/null 2>&1 || true
}
trap '_restore_expiry_not_null' EXIT

if psql "$LOCAL_URL" -q -c \
    "ALTER TABLE op.uploaded_images ALTER COLUMN expires_at DROP NOT NULL" >/dev/null 2>&1; then
    RELAXED="$(psql "$LOCAL_URL" -tAc "SELECT is_nullable FROM information_schema.columns WHERE table_schema='op' AND table_name='uploaded_images' AND column_name='expires_at'" 2>/dev/null | tr -d '[:space:]')"
    if [[ "$RELAXED" == "YES" ]]; then
        _record_pass "the column really is nullable now, so this case tests the arm and not the fixture"
        OUT="$(POSTURE_ALLOW_LOCAL=1 POSTURE_DATABASE_URL="$LOCAL_URL" bash "$GATE" 2>&1)"
        if grep -qE "^FAIL images_past_expiry" <<< "$OUT"; then
            _record_pass "a nullable expires_at fires the retention assertion on its own"
            assert_contains "$OUT" "has become NULLABLE" \
                "and names the route, so it is not mistaken for an overdue backlog"
        else
            _record_fail "expires_at was made nullable and the retention assertion stayed green — the guarantee is assumed, not checked"
        fi
    else
        _record_fail "could not relax the column, so this case would pass for the wrong reason"
    fi
else
    _record_fail "could not relax the column, so this case would pass for the wrong reason"
fi

_restore_expiry_not_null
RESTORED="$(psql "$LOCAL_URL" -tAc "SELECT is_nullable FROM information_schema.columns WHERE table_schema='op' AND table_name='uploaded_images' AND column_name='expires_at'" 2>/dev/null | tr -d '[:space:]')"
if [[ "$RESTORED" == "NO" ]]; then
    _record_pass "NOT NULL is restored, so this case left the schema as it found it"
else
    _record_fail "expires_at is still nullable after this case — the development schema has been left relaxed"
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

test_case "the_connection_string_never_reaches_the_log" \
    "psql quotes the url it was given, password included"
#
# ⛔ The recorded incident, pinned. When `POSTURE_DATABASE_URL` does not parse
# as a connection URI, psql treats the ENTIRE STRING as a database name and
# echoes it back in `database "…" does not exist` — so a gate that captured
# psql's stderr and printed it published the password. Measured against the
# previous version of this script: one occurrence in the log. A truncated or
# mis-set secret is enough to reach it.
#
# ⚠️ The throwaway value below is not a credential and never was. Never put a
# real one in a test.
THROWAWAY_PW="NOTAREALPASSWORD-platform-test"
for shape in \
    "notascheme://someuser:${THROWAWAY_PW}@db.example.invalid/stacks" \
    "postgresql://someuser:${THROWAWAY_PW}@db.example.invalid:5432/stacks"; do
    out="$(POSTURE_DATABASE_URL="$shape" bash "$GATE" 2>&1 || true)"

    if grep -q "$THROWAWAY_PW" <<< "$out"; then
        _record_fail "the password reached the log for a url of this shape: ${shape%%:*}://…"
    else
        _record_pass "no password in the output for a ${shape%%:*}:// url"
    fi
done
assert_contains "$(cat "$GATE")" 'PGPASSWORD=' \
    "the password is passed out of band, not on psql's argv"
if grep -qE 'psql "\$POSTURE_DATABASE_URL"' "$GATE"; then
    _record_fail "the raw url is still being handed to psql as a single argument"
else
    _record_pass "the url is decomposed into keyword parameters instead"
fi

test_case "every_hand_found_breach_is_covered" \
    "the sweeps that found them by hand are now a roster"
#
# ⚠️ The last two are a different kind from the first four, and that is why they
# are pinned here rather than left to the count. The first four are states a
# healthy stack drifts into; these two are PRIVILEGE facts that no test can
# observe, because the test role is a superuser and is exempt from the thing
# being asserted. If either is dropped from the roster, every suite stays green
# and the assertion simply stops existing.
# ⚠️ The last five are a third kind again, and the reason they must be pinned by
# NAME is sharper than for the privilege facts above. They guard a line in
# `seeds.exs` whose correctness rests on a policy decision about a table it does
# not mention — so there is no diff that touches the seed when the guarantee
# breaks, and `check-rls-scope.sh` never reads `seeds.exs` at all. Drop one of
# these from the roster and nothing anywhere notices: not the seed, not the
# scope gate, not this suite's count if the count is adjusted with it.
for needle in "images_past_expiry" "orphaned_executing_jobs" "warehouse_schemas_missing" \
    "unmigrated" "app_role_exempt_from_rls" "definer_function_executable_by_public" \
    "widening_policy_is_not_read_only" "rls_table_without_warehouse_policy" \
    "definer_takes_a_user_list_as_its_subject" "definer_with_unnamed_parameters" \
    "rls_reader_membership_is_real" "definer_execute_comes_from_the_grant_not_the_role" \
    "rls_coverage_has_no_unexpected_table" "rls_coverage_has_not_regressed" \
    "owner_policies_are_for_all"; do
    assert_contains "$GATE_SRC" "$needle" "the roster covers ${needle}"
done

test_case "the_rls_coverage_pair_is_two_assertions_not_one" \
    "a symmetric difference cannot say which direction broke"
# ⛔ Deliberately TWO, and the suite pins that rather than leaving it to style.
# A fifth table gaining row-level security means "re-read the seed and add a
# warehouse policy"; one of the four LOSING it is a disclosure. One count cannot
# say which happened, and a message that cannot say what to do is a message
# nobody acts on. Collapsing them later would look like a simplification.
if grep -q "rls_coverage_has_no_unexpected_table" <<< "$GATE_SRC" &&
    grep -q "rls_coverage_has_not_regressed" <<< "$GATE_SRC"; then
    _record_pass "both directions are separate assertions with their own remediation"
else
    _record_fail "the two RLS-coverage directions were collapsed into one assertion"
fi

test_case "the_owner_policy_check_catches_a_MISSING_policy" \
    "the obvious form reads a deleted policy as clean"
# ⛔ MEASURED, and the whole reason this assertion is not written the obvious
# way. `WHERE policyname IN (…) AND cmd <> 'ALL'` returns ZERO when an owner
# policy is DELETED or split into two differently-named ones, because no row
# matches the names — absence reads as clean, which is this campaign's recurring
# shape appearing inside the gate built to catch it. With one expected policy
# absent from the catalog the EXCEPT arm reports 1 and the naive form reports 0.
assert_contains "$GATE_SRC" "EXCEPT SELECT policyname" \
    "the owner-policy assertion carries the arm that catches an absent policy"

summarise
