#!/usr/bin/env bash
# Asserts, against a real deployed database, the invariants that a per-diff gate
# cannot see.
#
# ⚠️ WHY THIS EXISTS, and why PR CI was never going to find any of it.
#
# A sweep of the production database on 2026-10-19 found five things, none of
# them diff-shaped:
#
#   * 6,655 of 6,764 uploaded images were past their expiry and still present,
#     the oldest overdue by 151 days, against a stated 30-day retention promise;
#   * all 91 `oban_jobs` rows were in state `executing` and no other state, 76 of
#     them stale between 97 and 180 days — jobs claimed by a machine that then
#     suspended, with nothing to rescue them;
#   * `op.price_snapshots` held zero rows, on a database with 55 books and 91
#     job rows, so not an empty database — the scraper's output table had never
#     been written;
#   * the `marts`, `staging` and `intermediate` schemas did not exist and `wh`
#     held no relations, so every mart-backed query had always errored;
#   * the staging branch's schema was frozen three weeks behind the default
#     branch because its reseed workflow had been failing for two months.
#
# Every one of those is a statement about a deployed system drifting away from
# its intent. A gate that reads a diff cannot observe any of them, and each had
# been true for months with every existing gate green.
#
# ⛔ SO THE INSTRUMENT IS NOT NEW — the discipline is. This project already
# names the defect class and already has the right tool for it, the zero-row
# sweep. What it did was run that sweep BY HAND, during a campaign, every few
# months. A sweep performed by a human occasionally is how a 151-day retention
# breach goes unnoticed for 151 days. This is the same sweep on a schedule.
#
# ⚠️ EVERY ASSERTION HERE IS A CEILING OR A FLOOR WITH A STATED REASON, never a
# pinned current value. A test pinning today's row counts would fail on ordinary
# growth, which is the fastest way to get a monitor muted.
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo .)"
cd "$REPO_ROOT" || exit 1

# A deployed database, named explicitly. There is no default and no fallback to
# a local URL on purpose: the whole value of this check is that it ran against
# something real, and a check that quietly inspects a developer's sandbox
# reports a clean bill of health for a machine nobody deployed.
: "${POSTURE_DATABASE_URL:=}"

if [[ -z "$POSTURE_DATABASE_URL" ]]; then
    echo "FAIL deployed-posture: POSTURE_DATABASE_URL is required." >&2
    echo "       Nothing was measured. This is a refusal, not a pass." >&2
    echo "       Point it at a DEPLOYED database — production or a preview branch." >&2
    exit 1
fi

# ⚠️ A LOCAL HOST IS REFUSED, not silently accepted.
#
# `.env` in this repository sets DATABASE_URL to localhost, and the deployed-only
# ExUnit modules skip only when their variable is UNSET rather than when it is
# local — so running those with the repo's own environment loaded points a
# "deployed" assertion at a developer sandbox, where the roles exist and the
# invariants hold. A green there proves nothing. `dbt-deployed.sh` already
# refuses a local host for exactly this reason; so does this.
# ⚠️ The ONE exception, and it is narrow on purpose: the suite that tests this
# script needs a database it can dirty, and a deployed one is the wrong place to
# plant a violation. `POSTURE_ALLOW_LOCAL` is for that and nothing else — it is
# set by `test/platform/deployed_posture_test.sh`, never by a workflow, and the
# run announces that it is self-testing so a log cannot be mistaken for a real
# measurement.
if [[ "${POSTURE_ALLOW_LOCAL:-0}" == "1" ]]; then
    echo "NOTE: POSTURE_ALLOW_LOCAL is set — this is a SELF-TEST of the check's own"
    echo "      mechanics against a local database. It measures nothing deployed."
else
    case "$POSTURE_DATABASE_URL" in
        *@localhost* | *@127.0.0.1* | *@::1* | *@*.localhost* | *@*.test*)
            echo "FAIL deployed-posture: POSTURE_DATABASE_URL points at a local host." >&2
            echo "       This check only means something against a deployed database." >&2
            echo "       Nothing was measured. This is a refusal, not a pass." >&2
            exit 1
            ;;
    esac
fi

if ! command -v psql >/dev/null 2>&1; then
    echo "FAIL deployed-posture: psql is not available." >&2
    echo "       Nothing was measured. This is a refusal, not a pass." >&2
    exit 1
fi

# Assertions are declared as SQL returning a single integer, plus a ceiling and
# the sentence a reader needs when it fires. Declared rather than inlined so the
# roster is reviewable in one place and `EXPECTED_ASSERTIONS` can pin its size.
#
# Each entry: name | sql | ceiling | explanation
ASSERTIONS=()

ASSERTIONS+=("images_past_expiry
SELECT count(*) FROM op.uploaded_images WHERE expires_at IS NOT NULL AND expires_at < now()
0
The 30-day image-retention promise is not being kept. These rows are past their
expiry and still present, with their storage paths and user attribution intact.
This reached 6,655 rows overdue by up to 151 days before anyone noticed, because
the sweep that clears them could not finish and nothing rescued it.")

ASSERTIONS+=("orphaned_executing_jobs
SELECT count(*) FROM public.oban_jobs WHERE state = 'executing' AND attempted_at < now() - interval '2 hours'
0
Jobs have been stuck in 'executing' for over two hours. On a machine that scales
to zero that means the node was suspended mid-run; without a rescue plugin they
never return to 'available', and the pruner deliberately never touches
'executing', so nothing collects them. Production reached 91 such rows, the
oldest 180 days old, including the image-retention sweep itself.")

ASSERTIONS+=("warehouse_schemas_missing
SELECT 3 - count(*) FROM pg_namespace WHERE nspname IN ('marts', 'staging', 'intermediate')
0
A dbt warehouse schema is missing, so every query against it errors. Production
ran for months with none of the three and an empty 'wh', which meant the
community-read-count query always failed — and the code caught that failure and
returned a confident zero, so every book reported that nobody had read it.")

# ⚠️ The migration table is NOT in the same schema everywhere: a local database
# keeps it at `public.schema_migrations`, while staging and production keep it at
# `op.schema_migrations` (both held 102 rows when measured). Hardcoding either
# made this assertion ERROR rather than evaluate, which the anti-vacuity counter
# below correctly reported as "only 3 of 4 ran".
#
# A `to_regclass` guard does not fix that: Postgres resolves relation names at
# PARSE time, so merely naming a missing table in a subquery fails before any
# runtime guard is reached. `query_to_xml` takes the statement as a string and
# evaluates it per row that actually exists, so nothing unresolvable is parsed.
ASSERTIONS+=("unmigrated
SELECT CASE WHEN coalesce(sum(cnt), 0) = 0 THEN 1 ELSE 0 END FROM (SELECT (xpath('/row/c/text()', query_to_xml(format('SELECT count(*) AS c FROM %I.%I', table_schema, table_name), false, true, '')))[1]::text::bigint AS cnt FROM information_schema.tables WHERE table_name = 'schema_migrations') t
0
No migration table was found in either 'op' or 'public', or it is empty. That
means this is not the database anyone thinks it is, and every other assertion
here was evaluated against the wrong thing.")

EXPECTED_ASSERTIONS=4

# ⚠️ The declared count, retrofitted from a real regression elsewhere in this
# suite: a roster built by appending to an array is silently shortened by an
# editing mistake, and the loop below then passes over whatever survived. Pinning
# the size makes a dropped assertion a failing diff rather than a quieter pass.
if [[ "${#ASSERTIONS[@]}" -ne "$EXPECTED_ASSERTIONS" ]]; then
    echo "FAIL deployed-posture: declared $EXPECTED_ASSERTIONS assertion(s), built ${#ASSERTIONS[@]}." >&2
    echo "       Update EXPECTED_ASSERTIONS in the same change that adds or removes one." >&2
    exit 1
fi

scalar() {
    psql "$POSTURE_DATABASE_URL" -tA -c "$1" 2>&1
}

# A connectivity probe before the assertions, so "cannot connect" is reported as
# itself rather than as four mysterious failures.
probe="$(scalar 'SELECT 1')"
if [[ "$probe" != "1" ]]; then
    echo "FAIL deployed-posture: cannot query the database." >&2
    echo "       ${probe}" >&2
    echo "       Nothing was measured. This is a refusal, not a pass." >&2
    exit 1
fi

FAILURES=0
CHECKED=0

for entry in "${ASSERTIONS[@]}"; do
    name="$(printf '%s' "$entry" | sed -n '1p')"
    sql="$(printf '%s' "$entry" | sed -n '2p')"
    ceiling="$(printf '%s' "$entry" | sed -n '3p')"
    why="$(printf '%s' "$entry" | sed -n '4,$p')"

    value="$(scalar "$sql")"

    if ! [[ "$value" =~ ^[0-9]+$ ]]; then
        echo "FAIL ${name}: the assertion did not return a number." >&2
        echo "     ${value}" >&2
        echo "     Treated as a failure: an assertion that cannot run has not passed." >&2
        FAILURES=$((FAILURES + 1))
        continue
    fi

    CHECKED=$((CHECKED + 1))

    if [[ "$value" -gt "$ceiling" ]]; then
        echo "FAIL ${name}: ${value} (ceiling ${ceiling})" >&2
        printf '     %s\n' "$why" >&2
        echo "" >&2
        FAILURES=$((FAILURES + 1))
    else
        echo "ok   ${name}: ${value} (ceiling ${ceiling})"
    fi
done

# ⚠️ Anti-vacuity. The loop above reports success by printing nothing bad, which
# is also what it does when every query errored and every one was counted as a
# failure — or when the roster was empty. This is the number that separates
# "measured and clean" from "measured nothing".
if [[ "$CHECKED" -ne "$EXPECTED_ASSERTIONS" ]]; then
    echo "" >&2
    echo "FAIL deployed-posture: only ${CHECKED} of ${EXPECTED_ASSERTIONS} assertion(s) ran." >&2
    echo "       The rest could not be evaluated, so this run does not clear them." >&2
    exit 1
fi

if [[ "$FAILURES" -gt 0 ]]; then
    echo "" >&2
    echo "${FAILURES} of ${CHECKED} deployed-posture assertion(s) failed." >&2
    exit 1
fi

echo ""
echo "OK: all ${CHECKED} deployed-posture assertion(s) hold."
