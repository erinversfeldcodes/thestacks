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

# ⚠️ The `expires_at IS NOT NULL` clause this query used to carry was DEAD, and
# worse than dead: it told a reader that a null expiry is a legitimate state
# being deliberately skipped, which would mean the retention promise rested on
# an arm the assertion lacked. It does not. The column is `null: false` at
# creation (20260305000008) and no later migration relaxes it, so an image with
# no expiry cannot exist and the row count is already complete.
#
# The clause is gone and the guarantee it was standing in for is now CHECKED
# instead, by the second arm below. That matters here specifically because this
# gate runs against a deployed database, where "the migration says so" is a
# claim about a different machine than the one being measured.
ASSERTIONS+=("images_past_expiry
SELECT (SELECT count(*) FROM op.uploaded_images WHERE expires_at < now()) + (SELECT count(*) FROM information_schema.columns WHERE table_schema = 'op' AND table_name = 'uploaded_images' AND column_name = 'expires_at' AND is_nullable = 'YES')
0
An image can outlive the 30-day retention promise, by one of two routes.

Either rows are past their expiry and still present, with their storage paths
and user attribution intact — this reached 6,655 rows overdue by up to 151 days
before anyone noticed, because the sweep that clears them could not finish and
nothing rescued it.

Or expires_at has become NULLABLE, in which case an image can be stored with no
expiry at all and the count above would never see it. The column is created
NOT NULL; if that has changed on this database, the retention guarantee is gone
and the row count is no longer the whole question.")

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
# ⛔ THE ROLE'S ABSENCE IS COUNTED, AND IT IS THE WORSE STATE OF THE TWO.
#
# This was `WHERE rolname = 'stacks_app' AND (rolbypassrls OR rolsuper)` alone,
# which returns 0 — compliance — when there is no `stacks_app` role at all. That
# is not a benign gap: `runtime.exs` falls back to the OWNER when the runtime
# role is unavailable, and production's owner holds `rolbypassrls`. So the state
# the old form reported as clean is strictly worse than the state it reported as
# a failure — exempt by fallback rather than exempt by attribute, with nothing
# in `pg_roles` to look at.
#
# The second arm is therefore load-bearing in the same way the coverage
# assertion's `EXCEPT` arm is, and for the same reason: an inclusion test over a
# catalog has to make the empty result a HAZARD, or the gate's verdict on a
# missing object is indistinguishable from its verdict on a correct one.
#
# MEASURED, all four states, against a real database:
#   old form, role absent                  → 0   ← the false clean
#   new form, role absent                  → 1
#   new form, role present and exempt      → 1   (asked of `postgres`, rolsuper)
#   new form, role present and not exempt  → 0   (asked of `stacks_app`)
ASSERTIONS+=("app_role_exempt_from_rls
SELECT (SELECT count(*) FROM pg_roles WHERE rolname = 'stacks_app' AND (rolbypassrls OR rolsuper)) + (SELECT count(*) FROM (SELECT 1 WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'stacks_app')) t)
0
Either the runtime role is EXEMPT from row-level security, or it DOES NOT EXIST.

If it is exempt, every policy on op.bookshelves, op.bookshelf_placements,
op.user_blocks and op.visibility_grants is decorative — they are evaluated for
nobody. The policies will still look correct in pg_policies and every test will
still pass, because the test role bypasses RLS too. Revoke BYPASSRLS from
stacks_app, or stop calling this enforcement.

If it does not exist, the same thing is true by a different route and with less
to see: runtime.exs falls back to the owner, and the owner holds BYPASSRLS. Run
the migration that creates the role rather than reading this as a clean bill.")

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
SELECT count(*) FROM pg_policies WHERE schemaname = 'op' AND (coalesce(qual, '') || coalesce(with_check, '')) NOT LIKE '%current_scope%' AND 'rls_reader' <> ALL(roles) AND cmd <> 'SELECT'
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
SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'op' AND c.relrowsecurity AND NOT EXISTS (SELECT 1 FROM pg_policies p WHERE p.schemaname = 'op' AND p.tablename = c.relname AND 'stacks_dbt' = ANY(p.roles))
0
A table in op has ROW LEVEL SECURITY ENABLED but no policy naming stacks_dbt, so
the nightly warehouse refresh reads ZERO rows from it instead of failing. The grant
is inherited from ALTER DEFAULT PRIVILEGES; the policy is not. Add a role-scoped
USING (true) policy for stacks_dbt and stacks_readonly.

⚠️ ENABLED, not FORCED, and the distinction is the whole point of the query. An
earlier version of this sentence said FORCE, which contradicted the SQL beside it
and invited a reader to 'fix' the query by narrowing it to relforcerowsecurity.
FORCE only extends policies to the TABLE OWNER; stacks_dbt is not the owner, so
plain enablement already subjects it to policies and already blocks the refresh.
Keying on relrowsecurity is correct and strictly broader.")

# ⛔ A `SECURITY DEFINER` function may take an identifier of the THING BEING
# ASKED ABOUT — a book, an edition, a placement, a group — but never a list of
# the USERS WHOSE ROWS TO RETURN.
#
# ⚠️ The rule exists because one function broke it and the body looked fine.
# `op.group_feed_placements(member_ids uuid[], …)` was created taking the list
# of users whose shelf activity to return, so the caller chose the subject and
# the function — definer-owned, reading every row — simply obeyed. Measured: an
# anonymous session could call it with every user id on the platform. The
# authorisation lived entirely in the application code that computed the
# argument, and `group` visibility is admitted by NO policy arm, so it
# disclosed rows the policy set deliberately withholds.
#
# ⚠️ The general form of the rule is MONOTONICITY, and it is worth stating
# because it decides the next parameter somebody wants to add: a definer
# parameter is safe iff the returned row set is monotonically NON-INCREASING in
# it. `member_ids` was increasing — more ids, more rows — which is exactly what
# made it a subject selector. `exclude_user_ids`, `before_dt` and `lim` are all
# decreasing, so the maximum disclosure is fixed entirely by the subject
# identifier plus the viewer check, and the worst a caller achieves by
# manipulating them is seeing LESS than it is entitled to — a correctness bug at
# most, never a disclosure.
#
# ⛔ The virtue of the rule is that it is checkable from the SIGNATURE, without
# reading the body or trusting a sentence about callers — which is what the
# previous moduledoc's claim to be "in the same family as the boolean and the
# id-list" amounted to. So it is enforced by NAME: a `uuid[]` parameter on a
# definer function must be called `exclude_…`, because an exclusion list
# narrows a result while a subject list chooses it. Every other definer here
# takes a scalar identifier and satisfies the rule trivially.
#
# ⚠️ HONEST GAP, recorded rather than papered over: this checks the NAME, not
# the USE. A function could declare `exclude_user_ids uuid[]` and then write
# `WHERE user_id = ANY(exclude_user_ids)` — widening while named as narrowing —
# and this would pass. That is accepted as the right trade: the name is now an
# explicit claim the author had to make, the population is small enough to
# enumerate (one `uuid[]` parameter exists on any `op` definer today, and its
# use is narrowing), and a stronger check would have to assert the parameter
# appears only under a negated `ANY`/`NOT IN`, which is more SQL parsing than
# the problem deserves. This converts a judgement into a grep; it does not
# replace reading the body.
# ⛔ PAIRED BY MODE, NOT BY POSITION — the same correction its sibling
# `definer_with_unnamed_parameters` already carries, which this assertion was
# left behind by.
#
# `proargnames` holds IN + INOUT + VARIADIC + OUT + TABLE names; `proargtypes`
# holds only the input ones. So `proargnames[ord]` against `proargtypes[ord-1]`
# is sound only while every input is declared before every output, and Postgres
# does not require that. FIVE of the seven definers in `op` already have OUT or
# TABLE columns, so this is a live surface rather than a hypothetical one.
#
# MEASURED with a planted definer — `(OUT exclude_total int, IN subject_ids
# uuid[])`, a real violation:
#   positional form  → 0   ← the OUT name absorbed the `exclude%` exemption and
#                            the real uuid[] input fell off the end of the vector
#   mode-paired form → 1
# With the OUT named `total` instead, both return 1 — but the positional form
# gets there by attributing the uuid[] to `total`, so even its agreement is for
# the wrong reason.
#
# `coalesce(a.argname, '')` is deliberate: an UNNAMED uuid[] input is not named
# `exclude%`, so it must count as a violation. Left as a bare NULL comparison it
# would evaluate to NULL and drop out, which is absence reading as clean.
ASSERTIONS+=("definer_takes_a_user_list_as_its_subject
SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace, unnest(coalesce(p.proargnames, array_fill(''::text, ARRAY[p.pronargs])), coalesce(p.proallargtypes, p.proargtypes::oid[]), coalesce(p.proargmodes, array_fill('i'::\"char\", ARRAY[p.pronargs]))) AS a(argname, argtype, argmode) WHERE n.nspname = 'op' AND p.prosecdef AND a.argmode IN ('i','b','v') AND format_type(a.argtype, NULL) = 'uuid[]' AND coalesce(a.argname, '') NOT LIKE 'exclude%'
0
A SECURITY DEFINER function in op takes a uuid[] parameter that is not named
exclude_*, which means the caller is naming WHOSE ROWS to return rather than what
is being asked about. A definer function reads every row, so an argument that
chooses the subject moves the whole authorisation decision into the caller — and
an anonymous session is a caller. Take an identifier of the subject and read the
asker from op.scope_user() instead.")

# ⛔ A definer function with UNNAMED parameters, which is a cheaper hole than the
# name-vs-use gap documented above and runs in the worse direction.
# `proargnames` is NULL when no parameter is named, so `CREATE FUNCTION
# op.f(uuid[]) …` with positional parameters contributes zero rows to the
# assertion above and passes it entirely — a subject selector that is simply
# never named is invisible to a check keyed on names.
#
# ⛔ MEASURED CORRECTION. The first version of this compared
# `array_length(proargnames)` against `array_length(proargtypes)`, and that is
# wrong in a way that made the assertion fire on healthy functions:
# `proargnames` carries IN **plus OUT plus TABLE column** names, while
# `proargtypes` carries only IN args. So every `RETURNS TABLE(...)` definer is
# longer on the left by construction. Measured against the real corpus it
# returned **4**, not 0 — `group_feed_placements` (8 vs 4),
# `unmerge_placement_counts` (4 vs 2), `placement_owners_for_edition` and
# `wishlist_user_ids` (2 vs 1), the last two predating this work entirely. It
# would have turned the daily monitor red on its first run against the deployed
# stack, for nothing.
#
# `pronargs` is the INPUT-argument count, and `proargnames[1:pronargs]` is
# exactly the input names, so this asks the question actually intended: is any
# INPUT parameter unnamed? Measured 0 on the real corpus, and 1 against a
# planted `op.f(uuid)` with a positional parameter while correctly ignoring a
# planted well-named `RETURNS TABLE` definer.
#
# ⛔ SECOND CORRECTION, and the first one still had two holes. Positional
# slicing (`proargnames[1:pronargs]`) assumes input names come first, and
# `proargnames` actually follows `proallargtypes` — so an `OUT` or `INOUT`
# parameter BEFORE an input mis-aligns the slice. Measured against a planted
# `op.f(a uuid, OUT b integer, uuid)`: `proargnames={a,b,""}`,
# `proargmodes={i,o,i}`, `pronargs=2`, slice `{a,b}` — both non-empty, so the
# positional form PASSES while the third (input) argument is unnamed.
#
# ⚠️ Also measured: an unnamed slot among named ones is stored as the EMPTY
# STRING, not NULL — `information_schema._pg_expandarray` has
# `proargnames={"",x,n}` with `pronargs=1`, a live example of a signature that
# counts fine and is unnamed where it matters.
#
# So inputs are selected BY MODE rather than by position, and tested for
# emptiness rather than counted. `array_fill` is reached only when
# `proargmodes IS NULL`, which is exactly the case where names and types have
# equal length, so the zip is safe. `pronargs > 0` is load-bearing: it keeps
# `platform_row_counts` (0 inputs, 3 TABLE column names) out.
ASSERTIONS+=("definer_with_unnamed_parameters
SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'op' AND p.prosecdef AND p.pronargs > 0 AND (p.proargnames IS NULL OR EXISTS (SELECT 1 FROM unnest(p.proargnames, coalesce(p.proargmodes, array_fill('i'::\"char\", ARRAY[cardinality(p.proargnames)]))) AS a(nm, md) WHERE a.md IN ('i','b','v') AND coalesce(a.nm,'') = ''))
0
A SECURITY DEFINER function in op has INPUT parameters that are not all named.
The assertion that a definer may not take a list of users as its subject is keyed
on parameter NAMES, so an unnamed parameter is invisible to it — the check would
pass over exactly the function it exists to catch. Name every input parameter.")

#
# ⛔ The two assertions below exist because the deployed owner role has
# `rolbypassrls = true`, which means the definer functions work there through
# BOTH the `rls_reader` membership they are designed to use AND the exemption —
# so a change that dropped the membership would not surface on that stack. The
# general rule, and this session's recurring shape: WHEN TWO INDEPENDENT CAUSES
# PRODUCE THE SAME OBSERVABLE, DO NOT STRENGTHEN THE ASSERTION ON THE
# OBSERVABLE. Assert the cause you depend on, or remove the cause you do not.
#
# ⚠️ `pg_has_role` is the trap here, and it is MEASURED: it returns **true with
# zero membership rows** for a superuser, because superusers are treated as
# members of every role. It is an effect test wearing a catalog test's clothes.
# `pg_auth_members` is the cause and nothing masks it.
ASSERTIONS+=("rls_reader_membership_is_real
SELECT count(*) FROM (SELECT 1 WHERE NOT EXISTS (SELECT 1 FROM pg_auth_members WHERE roleid = 'rls_reader'::regrole AND member = current_user::regrole AND inherit_option)) t
0
The connecting role is NOT an inheriting member of rls_reader. The SECURITY
DEFINER functions are owned by rls_reader, so on a stack whose owner holds
BYPASSRLS they would still appear to work — through the exemption rather than
through the grant. This asserts the grant itself, from pg_auth_members, which
no role attribute can mask.

The membership is established by the migration that creates the definers
(20261020160000), which grants rls_reader to the migrating role so it can hand
ownership over. So this is GREEN wherever that migration has run and red where
it has not — which makes it a check on the migration having completed, not only
on the deployed grant. An earlier version of this text claimed it would be red
on any local database; that was measured before the migration had been applied
locally and was wrong.")

# EXECUTE is an ACL fact and BYPASSRLS confers no function privileges, so this
# is an honest test even on the bypassing owner — measured: all seven definers
# deny EXECUTE to `stacks_dbt`, which has neither the grant nor the exemption.
ASSERTIONS+=("definer_execute_comes_from_the_grant_not_the_role
SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'op' AND p.prosecdef AND NOT has_function_privilege(current_user, p.oid, 'EXECUTE')
0
A SECURITY DEFINER function in op cannot be executed by the connecting role.
BYPASSRLS grants no function privileges, so unlike a row read this cannot be
masked by the owner's exemption: if this is red the EXECUTE grant is genuinely
missing and the calling path is broken however the rows behave.")

#
# ⛔ THE THREE BELOW GUARD A SEED LINE'S CORRECTNESS FROM A DISTANCE.
# `apps/core/priv/repo/seeds.exs` has two lines whose correctness rests on a
# policy decision about a table they do not mention, and they share all four
# epistemics: both fail ON DEPLOY ONLY, both are invisible locally because the
# seed runs as a superuser, both would be broken by an edit to a MIGRATION with
# nothing in the diff touching the seed, and both sit outside
# `check-rls-scope.sh`, which scans `apps/core/lib/**/*.ex` and never looks at
# `seeds.exs` at all. That last point is why no existing gate catches either.
#
# So the remedy is not to fix the seed lines — neither is broken — but to fail
# when the PRECONDITION changes.
#
# ⚠️ Keyed on `relrowsecurity`, NOT `relforcerowsecurity`. FORCE only affects
# the table OWNER, and the seed connects as `stacks_app`, so plain enablement is
# what changes its behaviour. Measured: all four carry `rls=true force=true`
# today and the two give an identical set, so this is about future correctness —
# conflating them would make the first assertion miss an enabled-but-unFORCEd
# table, which is exactly the case that breaks the seed.

# ⚠️ SPLIT from the regression check below rather than expressed as one
# symmetric difference, because the two have DIFFERENT remediation and a single
# count cannot say which happened: a fifth table gaining RLS means "go re-read
# the seed and add a warehouse policy"; one of the four losing it is a
# disclosure. An unactionable message is a message nobody acts on.
ASSERTIONS+=("rls_coverage_has_no_unexpected_table
WITH expected(relname) AS (VALUES ('bookshelves'),('bookshelf_placements'),('user_blocks'),('visibility_grants')), actual AS (SELECT c.relname::text FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname='op' AND c.relkind='r' AND c.relrowsecurity) SELECT count(*) FROM (SELECT relname FROM actual EXCEPT SELECT relname FROM expected) t
0
A newly secured op table changes two things nothing else checks: seeds.exs reads
at least one op table UNSCOPED and is correct only because that table carries no
row-level security, and the warehouse roles need their own read policy or the
nightly dbt refresh silently returns zero rows. Add both, then extend the
expected list here. Do not extend the list first.")

ASSERTIONS+=("rls_coverage_has_not_regressed
WITH expected(relname) AS (VALUES ('bookshelves'),('bookshelf_placements'),('user_blocks'),('visibility_grants')), actual AS (SELECT c.relname::text FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname='op' AND c.relkind='r' AND c.relrowsecurity) SELECT count(*) FROM (SELECT relname FROM expected EXCEPT SELECT relname FROM actual) t
0
Row-level security was DISABLED on a table that carries user rows. This is not a
seed concern and not a performance decision; it is a disclosure. Every policy on
that table is now decorative.")

# ⛔ The UNION ALL's second arm is the load-bearing half, and it is why this is
# not written the obvious way. `WHERE policyname IN (…) AND cmd <> 'ALL'`
# returns ZERO when someone DELETES an owner policy or splits it into two
# differently-named ones, because no row matches the names — absence reads as
# clean, which is this campaign's recurring shape appearing inside the gate
# meant to catch it. MEASURED: with one expected policy absent from the catalog,
# the EXCEPT arm reports 1 and the naive form reports 0.
ASSERTIONS+=("owner_policies_are_for_all
WITH expected(policyname) AS (VALUES ('bookshelves_owner'),('bookshelf_placements_owner'),('user_blocks_owner'),('visibility_grants_granter')) SELECT count(*) FROM ((SELECT p.policyname::text FROM pg_policies p JOIN expected e ON e.policyname = p.policyname WHERE p.schemaname='op' AND p.cmd <> 'ALL') UNION ALL (SELECT policyname FROM expected EXCEPT SELECT policyname::text FROM pg_policies WHERE schemaname='op')) t
0
RETURNING on a row-level-secured table applies SELECT policies to the new row,
and seeds.exs depends on returning: [:id]. These owner policies being FOR ALL is
what supplies that SELECT policy. Splitting one into FOR INSERT + FOR SELECT
breaks the seed on deploy only. A MISSING policy counts as a violation here —
do not 'fix' this by removing a name from the expected list.")

# ⛔ TWO KINDS OF ASSERTION LIVE IN ONE ROSTER, AND THEY DO NOT MEAN THE SAME
# THING WHEN THEY FIRE.
#
# Thirteen of the fifteen are STRUCTURAL: they ask about roles, policies,
# grants, function signatures and schema shape, so their answer is a property
# of the database's configuration and is the same the moment after a deploy as
# it is a month later. Two are DATA conditions: they count rows that a backlog
# produces, so they go red because work accumulated, not because the posture
# changed.
#
# MEASURED against a real database, all fifteen: 13 green, and the only two red
# are exactly the data conditions — `images_past_expiry` at 1 (a seeded image
# 249 days overdue) and `orphaned_executing_jobs` at 27. Both were red before
# this distinction was drawn; neither was introduced by it.
#
# ⚠️ Why the split is worth the lines rather than a caveat on the whole file:
# this suite already shipped one assertion that was red the day it was written
# and would have reddened the production monitor on its first run. The lesson
# taken from that was "measure before you ship", and the lesson missed was that
# a roster mixing the two kinds cannot express WHICH ONES a clean local or
# preview run is evidence about. A structural assertion passing on a preview is
# real evidence, because a preview is a branch of staging and carries the real
# role set. A data assertion passing on a preview says nothing about
# production's backlog.
#
# So: a firing assertion is labelled, and the label tells a reader whether they
# are looking at a posture regression or at a queue that needs draining.
DATA_CONDITION_ASSERTIONS=(
    images_past_expiry
    orphaned_executing_jobs
)

EXPECTED_ASSERTIONS=15
EXPECTED_DATA_CONDITIONS=2

# ⚠️ The declared count, retrofitted from a real regression elsewhere in this
# suite: a roster built by appending to an array is silently shortened by an
# editing mistake, and the loop below then passes over whatever survived. Pinning
# the size makes a dropped assertion a failing diff rather than a quieter pass.
if [[ "${#ASSERTIONS[@]}" -ne "$EXPECTED_ASSERTIONS" ]]; then
    echo "FAIL deployed-posture: declared $EXPECTED_ASSERTIONS assertion(s), built ${#ASSERTIONS[@]}." >&2
    echo "       Update EXPECTED_ASSERTIONS in the same change that adds or removes one." >&2
    exit 1
fi

# ⛔ The data-condition list is checked against the roster, BOTH WAYS, because a
# name list that has stopped matching anything is the failure mode this whole
# file keeps finding elsewhere. A renamed assertion would otherwise silently
# lose its label and be read as structural — which is the direction that
# matters, since it would turn "a queue needs draining" into "the posture
# regressed". Its size is pinned for the same reason the roster's is.
if [[ "${#DATA_CONDITION_ASSERTIONS[@]}" -ne "$EXPECTED_DATA_CONDITIONS" ]]; then
    echo "FAIL deployed-posture: declared $EXPECTED_DATA_CONDITIONS data condition(s), listed ${#DATA_CONDITION_ASSERTIONS[@]}." >&2
    exit 1
fi

ROSTER_NAMES=""
for entry in "${ASSERTIONS[@]}"; do
    ROSTER_NAMES="${ROSTER_NAMES} $(printf '%s' "$entry" | sed -n '1p')"
done
for dc in "${DATA_CONDITION_ASSERTIONS[@]}"; do
    case " ${ROSTER_NAMES} " in
        *" ${dc} "*) ;;
        *)
            echo "FAIL deployed-posture: '${dc}' is listed as a data condition but is not in the roster." >&2
            echo "       Either it was renamed or it was removed. A label pointing at nothing would" >&2
            echo "       make its assertion read as structural, which is the wrong way to be wrong." >&2
            exit 1
            ;;
    esac
done

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
    # ⛔ Parsed by a URL parser, not by sed, and the reason is percent-encoding.
    # `deployed-posture.yml` composes this URL with
    # `urllib.parse.quote(pw, safe='')`, so any `@ / : % +` in the password
    # arrives percent-ENCODED. The one-argument `psql "$URL"` form this replaced
    # decoded that for free as part of URI parsing; lifting the raw substring
    # with a regex and handing it to `PGPASSWORD` does not, and libpq does not
    # decode either. So the moment the password is rotated to one containing a
    # reserved character, authentication fails with the wrong string and this
    # gate goes red nightly for a reason unrelated to what it measures.
    #
    # ⚠️ Latent today only because the current password happens to have no
    # reserved characters. The same applies to user and dbname, also quoted.
    #
    # ⚠️ The QUERY STRING is carried through too. Dropping it lost
    # `sslmode=require` — silently downgrading to `prefer`, which falls back to
    # PLAINTEXT if the server declines TLS, in the one script whose job is
    # asserting posture — and also drops `channel_binding` and
    # `options=endpoint=…`, which some Neon endpoints require.
    local parsed
    parsed="$(POSTURE_URL="$POSTURE_DATABASE_URL" python3 - <<'PARSE'
import base64
import os
import sys
from urllib.parse import urlsplit, unquote

u = urlsplit(os.environ["POSTURE_URL"])
if not u.hostname:
    sys.exit(1)
# ⛔ urlsplit(...).port RAISES ValueError on a non-numeric port rather than
# returning None, and an unguarded read made the refusal below report
# "missing: user host database" — naming three fields that were all present.
# Failing closed is correct; naming the wrong cause is not, and this file
# already carries one misattribution on record.
try:
    port = u.port or 5432
except ValueError:
    sys.stderr.write("unparseable port in POSTURE_DATABASE_URL\n")
    sys.exit(2)
# unquote() is the whole point: these arrive percent-encoded.
# ⛔ Each field BASE64-ENCODED, one per line. The workflow composes this URL
# with quote(pw, safe=''), which encodes a literal newline as %0A — and
# unquote() faithfully restores it. Emitting raw values one per LINE meant such
# a password truncated at its first newline and every later field shifted up by
# one: the host would be read from the password's second line. That is the same
# defect class as the sed parse this replaced — a transport that cannot
# represent its own data.
#
# ⚠️ NUL delimiters were the obvious fix and do NOT work here: bash discards
# null bytes in command substitution, so `$(…)` would collapse all six fields
# into one string. Base64's alphabet excludes the newline, which makes the
# line-per-field transport safe for arbitrary field content without changing
# its shape.
for _field in [
    unquote(u.username or ""),
    unquote(u.password or ""),
    u.hostname,
    str(port),
    unquote((u.path or "").lstrip("/")),
    u.query or "",
]:
    print(base64.b64encode(_field.encode()).decode())
PARSE
)"
    local parse_rc=$?
    # ⚠️ The parser's exit code is CLASSIFIED rather than collapsed, so the
    # refusal names the actual cause. Exit 2 is "the URL parsed but the port is
    # not a number" — previously that fell through to the field-presence check
    # below and reported three fields missing that were all present.
    if [[ $parse_rc -eq 2 ]]; then
        echo "FAIL deployed-posture: POSTURE_DATABASE_URL has an unparseable port." >&2
        echo "       Nothing was measured. This is a refusal, not a pass." >&2
        exit 1
    elif [[ $parse_rc -ne 0 ]]; then
        echo "FAIL deployed-posture: POSTURE_DATABASE_URL is not a parseable connection URL." >&2
        echo "       Nothing was measured. This is a refusal, not a pass." >&2
        exit 1
    fi

    # One base64 field per line, decoded positionally. A newline inside any
    # field — a rotated password is the realistic case — now stays inside that
    # field instead of shifting every subsequent one up by a line.
    local _fields=()
    while IFS= read -r _f; do
        _fields+=("$(printf '%s' "$_f" | base64 --decode)")
    done <<< "$parsed"
    POSTURE_PGUSER="${_fields[0]:-}"
    POSTURE_PGPASSWORD="${_fields[1]:-}"
    POSTURE_PGHOST="${_fields[2]:-}"
    POSTURE_PGPORT="${_fields[3]:-}"
    POSTURE_PGDATABASE="${_fields[4]:-}"
    POSTURE_PGQUERY="${_fields[5]:-}"

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

    # ⛔ `require`, never `prefer`. `prefer` falls back to plaintext when the
    # server declines TLS, which is a posture downgrade written into the posture
    # checker. Any sslmode the URL itself carries wins, since it was chosen
    # deliberately upstream.
    POSTURE_CONNINFO="host=${POSTURE_PGHOST} port=${POSTURE_PGPORT}"
    POSTURE_CONNINFO="${POSTURE_CONNINFO} user=${POSTURE_PGUSER} dbname=${POSTURE_PGDATABASE}"
    if [[ "$POSTURE_PGQUERY" == *sslmode=* ]]; then
        POSTURE_CONNINFO="${POSTURE_CONNINFO} $(printf '%s' "$POSTURE_PGQUERY" | tr '&' ' ')"
    else
        # ⚠️ `require` for anything deployed; `prefer` ONLY under the
        # self-test escape, which already announces that it measures nothing
        # deployed. A local Postgres has no TLS, so defaulting to `require`
        # everywhere made the escape unable to connect — and the suite then
        # reported "the ceiling comparison is not working" while the gate was
        # fine, which is the same misattribution this file has on record from
        # the planted-image fixture.
        if [[ "${POSTURE_ALLOW_LOCAL:-0}" == "1" ]]; then
            POSTURE_CONNINFO="${POSTURE_CONNINFO} sslmode=prefer"
        else
            POSTURE_CONNINFO="${POSTURE_CONNINFO} sslmode=require"
        fi
        [[ -n "$POSTURE_PGQUERY" ]] &&
            POSTURE_CONNINFO="${POSTURE_CONNINFO} $(printf '%s' "$POSTURE_PGQUERY" | tr '&' ' ')"
    fi
}
parse_conn

# ⛔ TWO shapes, because the credential and the diagnostics live in different
# places. psql quotes the connection string only in a CONNECTION error — which
# is exactly the malformed-URL case that leaked. A QUERY error (`relation …
# does not exist`, `permission denied for table`, a syntax error in a new
# assertion) is emitted after a successful connection and contains no
# connection string.
#
# ⚠️ Discarding stderr everywhere lost diagnostics that were load-bearing: the
# `query_to_xml` insight recorded above — that Postgres resolves relation names
# at parse time — was found by READING one of those query errors. So the
# connectivity probe discards, and the assertions keep stderr with the password
# redacted as belt-and-braces.
probe_scalar() {
    PGPASSWORD="$POSTURE_PGPASSWORD" psql "$POSTURE_CONNINFO" -tA -c "$1" 2>/dev/null
}

scalar() {
    local out
    out="$(PGPASSWORD="$POSTURE_PGPASSWORD" psql "$POSTURE_CONNINFO" -tA -c "$1" 2>&1)"

    # ⚠️ Guarded on the password being non-empty: an empty `sed` pattern
    # matches everywhere, which would corrupt every message rather than
    # redacting one.
    if [[ -n "$POSTURE_PGPASSWORD" ]]; then
        printf '%s' "$out" | sed "s|${POSTURE_PGPASSWORD}|REDACTED|g"
    else
        printf '%s' "$out"
    fi
}

# A connectivity probe before the assertions, so "cannot connect" is reported as
# itself rather than as several mysterious failures.
if ! probe="$(probe_scalar 'SELECT 1')" || [[ "$probe" != "1" ]]; then
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
        # Safe to quote now: `scalar` keeps query stderr and redacts the
        # password, and a query error cannot carry the connection string.
        echo "     ${value:-(no output — the query errored silently)}" >&2
        echo "     Its text: ${sql}" >&2
        echo "     Treated as a failure: an assertion that cannot run has not passed." >&2
        FAILURES=$((FAILURES + 1))
        continue
    fi

    CHECKED=$((CHECKED + 1))

    kind="structural"
    case " ${DATA_CONDITION_ASSERTIONS[*]} " in
        *" ${name} "*) kind="data condition" ;;
    esac

    if [[ "$value" -gt "$ceiling" ]]; then
        echo "FAIL ${name} [${kind}]: ${value} (ceiling ${ceiling})" >&2
        printf '     %s\n' "$why" >&2
        if [[ "$kind" == "data condition" ]]; then
            echo "     ⚠️ This is a DATA condition: it counts rows a backlog produced, so it" >&2
            echo "        went red because work accumulated, not because the posture changed." >&2
            echo "        Drain it; do not read it as a configuration regression." >&2
        else
            echo "     ⛔ This is a STRUCTURAL assertion: it describes the database's" >&2
            echo "        configuration, so it does not go red on its own over time. Something" >&2
            echo "        changed the posture." >&2
        fi
        echo "" >&2
        FAILURES=$((FAILURES + 1))
    else
        echo "ok   ${name} [${kind}]: ${value} (ceiling ${ceiling})"
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
