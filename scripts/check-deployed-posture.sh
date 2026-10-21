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

# ⛔ The assertion without which every row-level policy on this stack could be
# decorative, and nothing else would say so.
#
# BYPASSRLS outranks FORCE ROW LEVEL SECURITY: a role holding it is exempt from
# every policy on every table, and so is any superuser regardless of the flag.
# Production's owner role, `neondb_owner`, HAS `rolbypassrls = true` — measured —
# which is why the application was moved onto `stacks_app` at all. If that role
# ever acquires the attribute, by a Neon role template or by somebody granting
# it, the policies keep existing, keep looking correct in `pg_policies`, and
# enforce nothing.
#
# ⚠️ No test can catch this. The test suite connects as a superuser and bypasses
# row-level security itself, so an exempt runtime role passes every one of the
# 4000+ tests. This gate runs against a deployed database, which is the only
# place the question is answerable.
ASSERTIONS+=("app_role_exempt_from_rls
SELECT count(*) FROM pg_roles WHERE rolname = 'stacks_app' AND (rolbypassrls OR rolsuper)
0
The runtime role is EXEMPT from row-level security, so every policy on
op.bookshelves, op.bookshelf_placements, op.user_blocks and op.visibility_grants
is decorative — they are evaluated for nobody. The policies will still look
correct in pg_policies and every test will still pass, because the test role
bypasses RLS too. Revoke BYPASSRLS from stacks_app, or stop calling this
enforcement.")

# ⛔ The cross-user functions are the deliberate holes in per-user scoping, and
# their whole safety argument is that each is reachable only by the roles that
# need it. Postgres defeats that by default: `CREATE FUNCTION` grants EXECUTE to
# PUBLIC, so a function created without an explicit REVOKE is callable by every
# role that can connect — and a `SECURITY DEFINER` function runs as its owner, so
# PUBLIC means any connected role performs an unscoped cross-user read.
#
# ⚠️ Measured, before this was closed: as the runtime role with no scope set,
# op.placement_owners_for_edition returned three user ids, while the same
# question asked directly against the table was refused by the policy these
# functions exist to work around. The explicit grants to the runtime role looked
# like an allowlist and were decorative.
#
# ⚠️ No test can catch this either, for the same reason as the assertion above:
# the test role is a superuser, so it can call anything whatever the grants say.
# The grant list is only a fact about a real database.
ASSERTIONS+=("definer_function_executable_by_public
SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'op' AND p.prosecdef AND (p.proacl IS NULL OR EXISTS (SELECT 1 FROM aclexplode(p.proacl) a WHERE a.grantee = 0))
0
A SECURITY DEFINER function in schema op is executable by PUBLIC, which means
every role that can connect can perform the unscoped cross-user read that
function wraps — including the runtime role, for functions it was never granted.
A NULL proacl is the Postgres default and counts: it is the absence of a REVOKE,
not a decision. REVOKE ALL ... FROM PUBLIC and grant by name.")

# ⛔ The invariant that makes a deliberately-anonymous read WRITE-SAFE, and it
# is load-bearing without being obvious.
#
# An anonymous session resolves `op.current_scope()` to NULL, so every
# scope-equality policy denies it. What stops it WRITING is a second,
# independent fact: every policy that widens access without testing the scope
# is `FOR SELECT`. Measured — anonymous can read 24 `op.bookshelves` rows, and
# an unqualified `UPDATE` touched 0 of them, because UPDATE and DELETE consult
# only the `FOR ALL` owner policy's USING and the public arms contribute no
# write visibility. A row that SATISFIES a widening arm is still refused on
# insert, because a `FOR SELECT` policy contributes no WITH CHECK.
#
# ⚠️ `CREATE POLICY` with no `FOR` clause means `ALL`, which is exactly what
# somebody adding the next widening arm will reach for — and that would hand
# every anonymous visitor UPDATE and DELETE on every row the arm admits. The
# invariant holds today and nothing asserted it.
ASSERTIONS+=("widening_policy_is_not_read_only
SELECT count(*) FROM pg_policies WHERE schemaname = 'op' AND coalesce(qual, '') NOT LIKE '%current_scope%' AND 'rls_reader' <> ALL(roles) AND cmd <> 'SELECT'
0
A policy that does NOT test op.current_scope() is not restricted to SELECT, so it
widens WRITE access rather than read access. An anonymous or unscoped session can
then UPDATE or DELETE every row that policy admits. CREATE POLICY defaults to FOR
ALL, so this is the shape a new widening arm takes by accident. Add FOR SELECT.")

# ⛔ A row-level-secured table with no warehouse read policy fails SILENTLY:
# dbt reads zero rows rather than erroring, which is the exact failure shape
# this whole change set exists to eliminate.
#
# ⚠️ It is reachable by omission rather than by mistake. The role migration
# grants `SELECT ON ALL TABLES IN SCHEMA op` plus `ALTER DEFAULT PRIVILEGES`,
# so a future table receives the GRANT automatically and the POLICY never —
# and a grant without a policy reads as access while returning nothing.
ASSERTIONS+=("rls_table_without_warehouse_policy
SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'op' AND c.relforcerowsecurity AND NOT EXISTS (SELECT 1 FROM pg_policies p WHERE p.schemaname = 'op' AND p.tablename = c.relname AND 'stacks_dbt' = ANY(p.roles))
0
A table in op has FORCE ROW LEVEL SECURITY but no policy naming stacks_dbt, so the
nightly warehouse refresh reads ZERO rows from it instead of failing. The grant is
inherited from ALTER DEFAULT PRIVILEGES; the policy is not. Add a role-scoped
USING (true) policy for stacks_dbt and stacks_readonly.")

EXPECTED_ASSERTIONS=8

# ⚠️ The declared count, retrofitted from a real regression elsewhere in this
# suite: a roster built by appending to an array is silently shortened by an
# editing mistake, and the loop below then passes over whatever survived. Pinning
# the size makes a dropped assertion a failing diff rather than a quieter pass.
if [[ "${#ASSERTIONS[@]}" -ne "$EXPECTED_ASSERTIONS" ]]; then
    echo "FAIL deployed-posture: declared $EXPECTED_ASSERTIONS assertion(s), built ${#ASSERTIONS[@]}." >&2
    echo "       Update EXPECTED_ASSERTIONS in the same change that adds or removes one." >&2
    exit 1
fi

# ⛔ THE CONNECTION STRING NEVER REACHES psql's ARGV, AND psql's STDERR NEVER
# REACHES THIS LOG.
#
# Both halves were wrong here, and together they are this project's one recorded
# credential-disclosure incident reproduced exactly: `psql "$URL" … 2>&1`
# captured, and the capture printed on the failure path. psql quotes the whole
# connection string — password included — into its own error text, so redacting
# the command you compose does not redact what the tool prints back. The
# `::add-mask::` in the calling workflow matches exact strings only and would
# not have covered a reformatted fragment.
#
# So: the password is passed through PGPASSWORD, the rest through keyword
# parameters, stderr is DISCARDED rather than captured, and a failure is
# CLASSIFIED from the exit code instead of quoted.
parse_conn() {
    POSTURE_PGPASSWORD="$(printf '%s' "$POSTURE_DATABASE_URL" | sed -nE 's#^[a-z+]+://[^:/@]+:([^@]*)@.*#\1#p')"
    POSTURE_PGUSER="$(printf '%s' "$POSTURE_DATABASE_URL" | sed -nE 's#^[a-z+]+://([^:/@]+).*#\1#p')"
    POSTURE_PGHOST="$(printf '%s' "$POSTURE_DATABASE_URL" | sed -nE 's#^[a-z+]+://[^@]+@([^:/?]+).*#\1#p')"
    POSTURE_PGPORT="$(printf '%s' "$POSTURE_DATABASE_URL" | sed -nE 's#^[a-z+]+://[^@]+@[^:/?]+:([0-9]+).*#\1#p')"
    POSTURE_PGDATABASE="$(printf '%s' "$POSTURE_DATABASE_URL" | sed -nE 's#^[a-z+]+://[^@]+@[^/]+/([^?]+).*#\1#p')"
    : "${POSTURE_PGPORT:=5432}"

    # ⚠️ A refusal, not a pass. If the url did not parse, nothing below can be
    # measured and saying so is the only honest outcome. Reports WHICH field is
    # missing and never the url.
    local missing=""
    [[ -z "$POSTURE_PGUSER" ]] && missing="${missing} user"
    [[ -z "$POSTURE_PGHOST" ]] && missing="${missing} host"
    [[ -z "$POSTURE_PGDATABASE" ]] && missing="${missing} database"
    if [[ -n "$missing" ]]; then
        echo "FAIL deployed-posture: POSTURE_DATABASE_URL is missing:${missing}." >&2
        echo "       Nothing was measured. This is a refusal, not a pass." >&2
        exit 1
    fi
}
parse_conn

scalar() {
    PGPASSWORD="$POSTURE_PGPASSWORD" psql \
        "host=$POSTURE_PGHOST port=$POSTURE_PGPORT user=$POSTURE_PGUSER dbname=$POSTURE_PGDATABASE sslmode=prefer" \
        -tA -c "$1" 2>/dev/null
}

# A connectivity probe before the assertions, so "cannot connect" is reported as
# itself rather than as several mysterious failures.
if ! probe="$(scalar 'SELECT 1')" || [[ "$probe" != "1" ]]; then
    echo "FAIL deployed-posture: cannot query the database as ${POSTURE_PGUSER}@${POSTURE_PGHOST}." >&2
    echo "       psql's own output is deliberately discarded — it quotes the connection" >&2
    echo "       string, password included, and this runs in a CI log." >&2
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
        # ⚠️ Classified, not quoted. `scalar` discards psql's stderr because it
        # echoes the connection string, so there is nothing safe to print here —
        # an empty value means the query errored and the reason is in psql's
        # discarded output by design. Re-run the SQL by hand to see it.
        if [[ -z "$value" ]]; then
            echo "     The query returned nothing, which means it errored." >&2
            echo "     Its text: ${sql}" >&2
        else
            echo "     It returned a non-numeric value of ${#value} character(s)." >&2
        fi
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
