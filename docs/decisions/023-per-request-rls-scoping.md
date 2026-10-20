# ADR 023: Per-Request RLS Scoping — `SET LOCAL` in a Transaction, Fail Loud, Role-Scoped Exemptions

**Status:** Accepted
**Date:** 2026-10-20
**Deciders:** Platform owner
**Technical area:** Database security, row-level security, request lifecycle, background work, warehouse
**Relates to:** [ADR 006](006-rls-plus-application-visibility.md) — this decides the *scoping
mechanism* 006 assumed but never specified. 006's defence-in-depth position is unchanged: RLS sits
behind the application-layer gate in `Stacks.Visibility.resolve_visibility/2`, and nothing here moves
an authorisation decision out of the application.

---

## Context

⚠️ **This ADR exists partly because the architecture documentation asserted a mechanism that was
never built.** `docs/technical-architecture.md` stated that "the Phoenix pool sets the variable via
`SET LOCAL` at the start of each transaction". There is no such code: `app.current_user_id` appears
zero times under `apps/core/lib`. Anyone auditing whether RLS was wired found a confident yes in the
canonical document, which is the most expensive kind of wrong — the claim is corrected in the same
change as this ADR.

Four `op` tables carry row-level security — `bookshelves`, `bookshelf_placements`, `user_blocks`,
`visibility_grants` — with seven PERMISSIVE policies between them (five `ALL`, two `SELECT`). All
four have `FORCE ROW LEVEL SECURITY` and the deployed runtime role is not a superuser, so **the
policies are already evaluated on every deployed query**. They are nevertheless inert, because every
`ALL` policy opens with `current_setting('app.current_user_id', true) IS NULL OR …` and nothing under
`apps/core/lib` ever sets that GUC.

So the common framing — that pointing the runtime at the least-privilege role "activates policies
never exercised" — is wrong in both directions. The policies are live; they permit everything; and
the reason is an unset variable, not the connection role.

⛔ **And the short-circuit is worse than inert: it is non-deterministic.** Measured on the
development database, 2026-10-20:

```
fresh connection, GUC never set    → current_setting('app.current_user_id', true) IS NULL = t
                                   → the policy permits EVERY row

same connection, after any transaction has SET LOCAL it — including one that ROLLED BACK
                                   → current_setting('app.current_user_id', true) = ''
                                   → IS NULL is false, so the OR branch evaluates ''::uuid
                                   → ERROR: invalid input syntax for type uuid: ""
```

`SET LOCAL` reverts the GUC to its *default*, and once a custom GUC has been set in a session its
default is the empty string rather than unset. On a pooled connection, therefore, the same unscoped
query either grants every row or raises a 500, decided by which connection serves it. This is latent
today only because nothing sets the GUC at all; it detonates on the first commit that scopes
anything, and it would present as intermittent 500s on a subset of connections.

This ADR decides the mechanism, where scope is established, what background work does, whether the
NULL branch survives, and how the whole thing is proven. Every claim below marked *measured* was run
against a real Postgres, not reasoned about.

## Decision

### 1. Mechanism: `SET LOCAL` inside an explicit transaction

Three mechanisms exist and were measured:

| Mechanism | Measured behaviour | Failure mode |
|---|---|---|
| `SET LOCAL` **outside** a transaction | `WARNING: SET LOCAL can only be used in transaction blocks`; the setting does not take | **Silently does nothing** — looks wired, enforces nothing |
| `SET LOCAL` **inside** a transaction | Scoped to the transaction; reverts to the role default on `COMMIT` or `ROLLBACK` | Leak-free; requires a transaction |
| session-level `SET` | Persists on the connection until `RESET` | **Leaks across requests** — a missed reset serves one reader another reader's rows |

We use **`SET LOCAL` inside an explicit transaction**. The session-level variant is rejected because
its failure mode is the precise harm RLS exists to prevent, and `before_send` hooks do not run on
every abnormal exit path, so "missed reset" is not hypothetical.

⚠️ **A single request-wide transaction is also rejected**, and the reason is specific to this
codebase rather than general advice: `StacksWeb.UploadController` serves `text/event-stream` with a
heartbeat loop, so a transaction opened for the life of a request would hold a database connection
*and* an open transaction for the entire duration of every progress stream. Long transactions pin
pool slots and block `VACUUM`, and the 512 MB preview VM has the least headroom for exactly that.

### 2. Where scope is established: at each context boundary

Each context function that reads or writes an RLS table opens a transaction and sets the scope. This
is more call sites than a single plug, but it is the only option compatible with §1's rejection of
request-wide transactions, and `Repo.transaction`/`Ecto.Multi` are already used in 14 modules, so the
shape is idiomatic here rather than novel.

### 3. The policy shape: one indexable equality calling one function

The NULL short-circuit is **removed**. Policies become:

```sql
USING (user_id = op.current_scope())
```

where `op.current_scope()` is a single `STABLE` function holding the whole rule:

```sql
CREATE FUNCTION op.current_scope() RETURNS uuid LANGUAGE plpgsql STABLE AS $$
BEGIN
  IF current_setting('app.current_user_id', true) IS NULL
     OR current_setting('app.current_user_id', true) = 'unset' THEN
    RAISE EXCEPTION 'query on a row-level-secured table with no request scope set'
      USING ERRCODE = '42501';
  END IF;
  RETURN current_setting('app.current_user_id')::uuid;
END $$;
```

and the runtime role carries a deliberately non-UUID default:

```sql
ALTER ROLE stacks_app SET app.current_user_id = 'unset';
```

⚠️ **The role default is what makes the behaviour deterministic**, and it is the part that is easy to
leave out. A role-level default is inherited at login (measured: a role with that `rolconfig`
returns the value on connect), and `SET LOCAL` reverts to *that* value rather than to the empty
string. So an unscoped query raises identically on a fresh connection and on one that has already
served a scoped request (both measured) — which is exactly the non-determinism in the Context
section, closed.

**Unscoped fails LOUD, not quiet.** This corrects a natural assumption: removing the NULL branch does
*not* mean "a missed scope returns zero rows". Because the reset value is a string rather than NULL,
equality-only **raises**. We keep that and make it say so, via the named `42501` above instead of a
bare `invalid input syntax for type uuid` from seven separate policy bodies.

### 4. ⛔ The function returns the scope VALUE. The exemption is never an `OR` term

This is the sharpest constraint in this ADR and it is not obvious. Measured on 50,000 rows with an
index on `user_id`:

| Policy shape | Plan |
|---|---|
| `USING (user_id = op.current_scope())` | **Bitmap Index Scan** |
| `USING (op.scope_allows(user_id))` | Seq Scan |
| `USING (op.current_scope() = <sentinel> OR user_id = op.current_scope())` | Seq Scan |

The obvious way to centralise the rule — a boolean function taking the row's `user_id` — turns every
query on all four tables into a sequential scan. So does adding a sentinel value as an `OR` term,
**even when the query is scoped to a real user**. Either would be a silent, whole-table performance
regression discovered in production.

Therefore: `op.current_scope()` takes no arguments and returns the scope, the comparison stays
`user_id = <value>` and stays indexable, and **a system-wide exemption is expressed as a
role-scoped policy, never as a value in the policy body.** A policy written `TO <role>` is applied
only when `current_user` matches, so the runtime role's plan keeps exactly one indexable qual.

⚠️ **Correction, measured after this ADR was first written.** The sentence above is true of the
owner policy *alone*, and that is not the whole story for reads. Postgres combines PERMISSIVE
policies with `OR`, and three of these four tables carry a second permissive policy for `SELECT`
(`bookshelves_platform_select`, `bookshelf_placements_platform_select`,
`visibility_grants_grantee_select`). So a read evaluates
`user_id = op.current_scope() OR visibility = 'platform'`, which **sequentially scans** when only
`user_id` is indexed — measured on 50,000 rows. Writes, and everything on `user_blocks` (a single
policy), keep the index.

✅ It is fixable, and the fix is an index rather than a policy change: with **both** columns
indexed the planner builds a `BitmapOr` of two index scans, and a *partial* index on the platform
rows is enough since that arm only ever asks for them. The migration therefore adds four:
partial `visibility` indexes on `bookshelves` and `bookshelf_placements`, and plain indexes on
`visibility_grants.granted_by_id` (which had none) and `.granted_to_id` (which was only the third
column of a composite). ⚠️ This seq scan is **pre-existing** — today's policies already OR the same
second arm — so the indexes repair something enforcement would otherwise inherit, rather than
compensating for a regression this change introduces.

### 5. Background work: every RLS query is scoped to someone — no exceptions, no sentinel

Measured: 37 workers exist, 7 carry a `user_id`, and only four touch an RLS table at all.

| Worker | Disposition |
|---|---|
| `regenerate_feed_job` | per-user — scopes to its `user_id` |
| `visibility_recap_job` | per-user — scopes to its `user_id` |
| `expired_unverified_accounts_job` | ⚠️ needs NOTHING — see the correction below |
| `goodreads_import_job` | ⚠️ needs NOTHING — see the correction below |

⚠️ **Correction, measured during implementation: neither of those two needed refactoring, and the
claim that they did came from a grep matching prose.** `expired_unverified_accounts_job`'s only
mention of these tables is a code COMMENT; it queries `op.users`, which carries no policy, and then
calls `GDPR.Deletion.delete_user_data/2`, which scopes itself. `goodreads_import_job` reaches the
tables only through `Shelving.place_book/5` and `Shelving.get_placements_for_book/2`, both of which
now scope themselves. So the real worker surface was two other jobs — `visibility_recap_job`, which
runs its own `update_all` and is scoped in `perform/1`, and `regenerate_feed_job`, scoped at its
`Feeds.regenerate/2` context boundary.

The invariant still holds and still has no exemption for application work: no sentinel GUC value and
no `BYPASSRLS` role anywhere in this design.

⚠️ `Core.Repo` and `Core.ObanRepo` both use `APP_DATABASE_URL`, so Oban workers and web requests are
the **same database role**; no policy can distinguish them. That is a reason this decision avoids
role-based exemptions for application work, not an obstacle to be engineered around.

### 6. The warehouse and read-only roles get role-scoped policies

Measured: `stacks_dbt` and `stacks_readonly` are both `rolsuper = false, rolbypassrls = false`, so
`FORCE ROW LEVEL SECURITY` applies to them, and **five dbt staging models read these four tables**
(`stg_bookshelves`, `stg_bookshelf_placements`, `stg_bookshelf_placement_history`, `stg_user_blocks`,
`stg_visibility_grants`). Today the NULL branch is the only reason the warehouse sees any rows.

They are exempted declaratively, per §4:

```sql
CREATE POLICY <name> ON op.<table> FOR SELECT TO stacks_dbt, stacks_readonly USING (true);
```

No new connection string: both roles already exist and already have their own credentials. The
exemption is visible in `pg_policies`, which is where a reviewer can audit it, rather than in
application code.

⚠️ Without this, the first nightly refresh after enforcement **raises** rather than silently
emptying the warehouse — loud, which is the design working, but still a broken refresh. It ships in
the same migration as the policy change.

### 7. Forgetting is a compile error, not a code-review item

Three layers, because the author must not have to remember:

1. **Compile-time.** Workers declare `use Stacks.Worker, scope: :user | :system` in place of bare
   `use Oban.Worker`. Omitting `scope:` **fails to compile**, naming the module.

   ⛔ **Correction, after implementing it: the macro does NOT wrap `perform/1`, and does not assert
   the `user_id` either.** This paragraph originally said it would do both. Wrapping was dropped
   because the measurements in §9 make it unsafe — a `Repo.rollback/1` inside a nested transaction
   discards the value rolled back with, and a declared `unique_constraint` violation inside an
   explicit transaction returns `{:error, :rollback}` instead of the changeset. A macro cannot tell
   which jobs rely on either, so it would break some of them invisibly; six `Shelving` functions and
   `GDPR.Deletion.delete_user_data/2` are exactly those cases. The `user_id` assertion was dropped
   for a duller reason: a macro receives the `use` options and cannot see the `perform/1` head where
   the args pattern lives.

   ⚠️ So the division of labour is: **the macro refuses to compile without a declaration; the gate
   tests whether the declaration is true.** Neither covers the other, and a plan that had the macro
   doing both would have left the gate looking redundant.
2. **A sweep gate.** `scripts/check-rls-scope.sh` checks four things, each with a planted-red run
   recorded in the issue: every module referencing the four secured schemas and running a Repo call
   establishes a scope (or is allowlisted **with its reason**); every `scope: :system` worker
   references none of those schemas, comments stripped, because `:system` is the easy answer when
   somebody does not want to decide; every `scope: :user` worker names a `user_id`; and **nothing but
   `Stacks.Scope` touches `app.current_user_id`**, since a bare `SET LOCAL` outside a transaction
   warns and does nothing. It carries an anti-vacuity floor on the number of modules and workers
   examined — the first version of the gate errored on a bash 3.2 incompatibility and still exited 0,
   which is the failure it now refuses to have.
3. **Runtime.** The `42501` errcode is a named, alertable signal meaning a path was missed.

⛔ **Layer 3 is deliberately last, because the test suite cannot see any of this.** Measured: the
test environment connects as `postgres`, which is `rolsuper = true`, and **superusers bypass RLS
entirely** — so all 4097 tests pass whether or not a path is scoped. Layers 1 and 2 are therefore
what hold before merge, and the first environment that genuinely enforces is the preview stack, where
the application connects as `stacks_app`. Any future claim that "the tests prove scoping works" is
false by construction unless the suite is given a non-superuser role.

### 8. Rollout: straight to enforcing, with no flag

No `STACKS_RLS_ENFORCE`. The justification is the detection path, measured rather than assumed:

| Failure shape | Preview E2E, pre-merge | Production SLO gate, on merge |
|---|---|---|
| Unscoped path (raises `42501`) | caught | 5xx breaches the 0.99 success-rate threshold → automatic rollback |
| Over-permissive path (wrong rows) | caught — `privacy-placement` and `privacy-block` assert the cross-user direction | not detected |

⚠️ **One claim elsewhere in this document needed correcting, and the measurement is the reason.**
"A scoped connection cannot read another user's bookshelf" is **false as stated**: it cannot read
another user's *private* bookshelf, while a platform-visible one is readable by any signed-in
reader — that is what `bookshelves_platform_select` says, and narrowing it would change the
product's visibility rule rather than enforce it. Measured as `stacks_app` on 2026-10-20: scoped to
one user, **0 of 82** other users' private shelves were visible, their 3 platform-visible shelves
were, and the user's own 5 were. The proof obligation is therefore stated against *private* rows,
and any test asserting the broader claim would fail for the right reason on the wrong grounds.

The deployed E2E runs on the pull request against the preview stack, **before** merge, and the six
specs covering these tables carry **48 presence assertions and zero `count > 0` guards**
(`shelf-actions` 20, `public-profile` 8, `privacy-placement` 6, `reading-journey` 5, `syndication` 5,
`privacy-block` 4). Because §3 makes a missed scope raise rather than return nothing, the
post-merge gate can see it too: a zero-rows failure would have been invisible to a gate that measures
status codes and latency — it is `200 OK` and *faster*, so the gate would read a leak-free-but-empty
system as healthier.

A flag's remaining value would be an operator lever, and the SLO gate's automatic rollback already is
one.

### 9. Two consequences of the mechanism that every caller inherits

⛔ **An insert relying on constraint-error recovery must pass `mode: :savepoint`.** Measured: a
declared `unique_constraint` violation inside an EXPLICIT transaction returns `{:error, :rollback}`
from the transaction rather than `{:error, changeset}` from the insert — Ecto does not savepoint
automatically there. So `block_user/2`'s duplicate case and `grant_visibility/3`'s `:already_granted`
both lost the changeset that identified them the moment they ran inside a scope. Any new write that
distinguishes a constraint failure from other failures owes the same option.

⛔ **A function that owns its transaction must use `set!/1` or `multi_step/2`, never `with_user/2`.**
`with_user/2` opens a transaction; a `Repo.rollback/1` inside a nested one aborts the outer and
discards the value rolled back with, so a context using rollback for control flow silently returns
`:rollback` instead of its reason. Six `Shelving` functions and `GDPR.Deletion.delete_user_data/2`
take the Multi form for this reason.

⚠️ **`is_binary/1` is not a sufficient guard for a scope value.** A raw 16-byte UUID is a binary, and
passing one through reaches the database as invalid UTF-8 — the lucky case. Sixteen bytes that happen
to be valid UTF-8 would set a scope matching no user, so every query in the operation would return
nothing while reporting success. `Stacks.Scope` normalises through `Ecto.UUID.cast/1`.

## Consequences

- A missed scope is a 500 for that request rather than a silent full-table grant. That is the trade
  this ADR makes deliberately, and §7's first two layers exist to make it rare.
- Every RLS-table read runs inside a transaction. More transactions, each short.
- `pg_policies` becomes the audit surface for who may read across users: exactly two roles, neither
  of which serves application traffic.
- The non-determinism described in the Context section is closed as a side effect — the role default
  removes the state where the GUC can read as NULL in production.
- The warehouse depends on a policy rather than on an accident, and says so.
- Until the test suite runs as a non-superuser role, local green is not evidence about scoping. This
  is recorded rather than fixed here; fixing it is a change to the test harness, not to this design.

## Alternatives considered

- **Session-level `SET` with a `RESET` hook** — cheapest, no transaction requirement. Rejected: its
  failure mode on a pooled connection is a cross-user row leak, and the hook does not run on every
  exit path.
- **One request-wide transaction in an endpoint plug** — one place, impossible to forget. Rejected on
  the SSE endpoint: a progress stream would hold a connection and an open transaction for its whole
  life.
- **Keeping the `IS NULL OR` short-circuit** — inert on arrival, scope path by path. Rejected: it is
  the non-determinism, and it leaves a missed scope indistinguishable from a deliberate system-wide
  query, which is today's state.
- **A sentinel GUC value for system-wide work** (`'system'`, or an all-zeros UUID) — one concept, no
  extra role. Rejected on measurement: as an `OR` term in the policy it forces a sequential scan on
  every query, scoped ones included.
- **A `BYPASSRLS` role for background work** — declarative and unforgettable. Rejected: it creates a
  standing credential exempt from row-level security, and §5 shows it is unnecessary — the only four
  workers involved can all be scoped to a user.
- **A `SECURITY DEFINER` function to escape policies** — does not work as hoped: with
  `FORCE ROW LEVEL SECURITY` the table owner is itself subject to policies, so the definer would need
  `BYPASSRLS`, which is the alternative above.
- **Two-phase rollout behind `STACKS_RLS_ENFORCE`** — enforcement switched on against a measured
  counter. Rejected per §8: detection already happens before merge, and the raise makes the
  post-merge gate able to see a failure it would otherwise have read as an improvement.
