# Runbook: Production Migration Recovery

**Severity:** P1 (schema state may be inconsistent)
**Owner:** Platform operator
**Last reviewed:** 2026-05-01

---

## Symptoms

The operator opens this runbook when one or more of these signals fire:

- The `deploy-stack.sh` step in `.github/workflows/deploy-production.yml`
  exits non-zero, and its log shows the failure happened in the
  "Running prod migrations (before image cutover)" block at
  `scripts/deploy-stack.sh:637`. That block runs `mix ecto.migrate`
  from the GitHub Actions runner against the prod `DATABASE_URL`
  BEFORE the core `fly deploy` cutover — a partial migration aborts
  the script before any image swap, so the old image keeps serving
  traffic.
- The auto-rollback fires (`if: failure() || inputs.manual_rollback` on
  the `rollback-production composite action` step).
- The composite action's `triggered-by` input evaluates to
  `"step-failure"` — recorded in the audit row's
  `metadata.triggered_by`. (Migration failures are no longer
  distinguishable from other `deploy-stack.sh` failures at the
  workflow level since the consolidation; `metadata.reason` and the
  workflow logs carry the precise cause.)
- Schema state may be partially applied. Some `ALTER TABLE` statements
  in the failing migration committed before the failure point; others
  did not. Postgres does not wrap a multi-statement migration in a
  single transaction unless the migration itself opts in (and many
  destructive ops can't safely be wrapped).

---

## What happens automatically

The auto-rollback path described in `issues/137-rollback-action-composite.md`
handles the migration-failure case explicitly:

| Leg | What runs |
|-----|-----------|
| Image rollback | **Skipped.** The currently-serving image already matches `CORE_PREV_IMAGE` because `deploy-stack.sh` never ran (the migrate step failed first). The script detects this via `fly image show` and logs `==> core rollback skipped — currently-serving image already matches …`. |
| Neon LSN reset | **Fires.** This is the case where the LSN reset earns its keep — Postgres-level rollback unwinds half-applied `ALTER TABLE` statements that `def down` cannot reliably reverse. |
| Modal vision | **Fires.** `MODAL_PREV_COMMIT` was resolved by `record-prev-state` before any deploy work ran, so it is non-empty. The script unconditionally redeploys to that commit (re-deploying an identical artifact is idempotent on Modal — the app cycles a new revision pointing at the same code). This keeps the vision/core wire-format pair locked together. |

End state: image N-1 + schema N-1 + vision-at-prev-commit, fully consistent.

The audit row for this path lands with `metadata.triggered_by =
"step-failure"` and `metadata.reason` describing the SLO-gate context
or the prior-step failure. (Before the Phase 7 consolidation,
migrate-prod was a discrete workflow step and `triggered_by` could
distinguish `"migration-failure"` from `"step-failure"`. After
moving the migrate inside `deploy-stack.sh`, all in-script failures
surface uniformly as `step-failure`; check the workflow logs and
`metadata.reason` to identify whether the failure was migrate,
fly deploy, or something else.)

---

## Decision tree: forward-fix vs down-migrate vs trust auto-rollback

### Path A — Trust the auto-rollback (default)

If the auto-rollback completed cleanly, **no further action is needed**.
Verify all of:

- The composite action's outputs report `core-rolled-back=false`
  (skipped — image was never cut over), `db-rolled-back=true` (Neon
  reset succeeded), `modal-rolled-back=true` (Modal redeployed at the
  prev commit). This is the canonical migration-failure shape: only
  the core-leg short-circuits because its target equals the
  currently-serving image.
- An audit row exists in `audit.audit_log` with
  `action = "system.rollback"` and
  `metadata.triggered_by = "step-failure"` (with `metadata.reason`
  identifying the migration as the failing step).
- The `[:stacks, :system, :rollback]` telemetry event fired (visible in
  Axiom).
- `/api/health` returns 200.
- The `pre-rollback-*` Neon branch is visible in the Neon console (free
  safety net — see "Pre-rollback Neon branch promotion" below).

The failed migration's source file should be updated before the next
deploy attempt — fix the bug, push a corrective commit, let the next
prod deploy try again.

### Path B — Forward-fix

Use when:

- The failed migration was destructive (`DROP COLUMN`, `DROP TABLE`,
  `RENAME`) and Path A's LSN reset can't be safely re-applied — for
  example, if writes since the failure have referenced columns whose
  state would be invalidated by the reset. (This is a rare combination
  given prod's expand-contract discipline; investigate before assuming
  it applies.)
- The migration partially succeeded and the LSN reset would discard
  data the operator wants to keep (e.g. early statements wrote audit
  rows that document the partial migration's state).

Procedure:

1. Inspect the partial state. Connect via `psql "$DATABASE_URL"` and
   query `pg_class` / `information_schema.columns` to confirm exactly
   which DDL committed before the failure.
2. Write a corrective migration that brings the schema to a known-good
   state. The corrective migration should be **idempotent** (each
   statement guarded with `IF NOT EXISTS` / `IF EXISTS`) so re-running
   on a host that already partially applied the original is safe.
3. Ship the corrective migration in a new PR. The next prod deploy will
   apply it before image cutover.

### Path C — `mix ecto.rollback` (LOCAL DEV ONLY)

**Never trust `def down` in prod.** The `down/0` blocks in generated
migrations are kept for local-dev convenience (running
`mix ecto.rollback` against a dev DB to undo a migration during
development) but are **not** exercised in any prod path. Prod relies on
the LSN reset for schema-level rollback because:

- `def down` can't reliably reverse a partially-applied `ALTER TABLE`
  (Postgres doesn't expose enough state to know how far the original
  migration got).
- `def down` is unaudited free-form Elixir; it can drift from `def up`
  silently.
- The LSN reset is byte-level Postgres — it reverts both DDL and DML in
  one atomic API call.

This path exists as a documentation note, not an instruction. If you
find yourself running `mix ecto.rollback` against prod, stop and
escalate.

---

## Cross-references

### `migration-safety` lint

`scripts/lint-migrations.sh` enforces a `@breaking_ok` module attribute
on any migration that performs a destructive operation:

- `remove :col` (drop column)
- `drop_column`
- `drop_table` / `drop table(...)`
- `rename` (column or table)
- `modify ..., null: false` (tighten nullable to NOT NULL)

The annotation requires the author to attest, in free text, that the
expand phase has already shipped — i.e. that no code in the previous
production image reads or writes the affected shape. Without
`@breaking_ok`, the migration fails CI.

This lint is what makes "image N-1 ↔ schema N is safe by construction"
load-bearing. Every prod migration is forced to be expand-contract
unless explicitly opted out, which keeps the auto-rollback's
image-revert-then-DB-revert ordering safe.

The lint is conscience-based — it doesn't mechanically verify that the
expand phase actually shipped. A reviewer or operator must cross-check
the referenced commit(s) before approving a destructive migration.

### Expand-contract invariant (asymmetry)

The two-direction safety guarantee:

- **Image N-1 ↔ schema N: SAFE.** Expand-contract enforces that the
  post-migrate schema is forward-compatible with the previous image.
  New columns are unused by image N-1; new tables aren't read; column
  type widenings are byte-compatible. The brief window where image N-1
  talks to schema N is harmless.
- **Image N ↔ schema N-1: UNSAFE.** Image N may write columns that
  don't exist in schema N-1 → INSERT/UPDATE failures, 500 responses,
  potential constraint violations.

The asymmetry forces rollback ordering: revert the image **before** the
schema, never after. The composite action's order
(core image → Neon DB → Modal vision) implements exactly that
invariant.

---

## Pre-rollback Neon branch promotion

When the auto-rollback's Neon LSN reset fires, Neon's API requires
`preserve_under_name` on a self-restore. The result: a `pre-rollback-*`
branch appears in the Neon project, snapshotted at the
pre-rollback state. This is a free safety net for the rare case where
the rollback itself was wrong.

To inspect:

1. Open the Neon console:
   `https://console.neon.tech/app/projects/$NEON_PROJECT_ID/branches`.
2. Find the branch named `pre-rollback-<sha7>-<UTC-timestamp>`.
3. Read its size, parent LSN, and creation time.

To promote (rare — only if the rollback itself was wrong):

```bash
neonctl branches set-default <branch-id>
```

…or use the console UI's "Set as default" action on the branch. After
promotion the prod app's `DATABASE_URL` continues to point at the same
endpoint; Neon swaps the underlying branch. No app restart needed
(connection-pool reconnection is automatic).

`pre-rollback-*` branches are not auto-cleaned up. See
`issues/162-cleanup-pre-rollback-neon-branches.md` for the scheduled
pruning workflow.

---

## Failure modes

### Neon LSN reset failed (`FAIL rollback: Neon restore`)

The workflow log shows `FAIL rollback: Neon restore returned HTTP …` or
`FAIL rollback: Neon restore curl call failed (transport-level)`.

End state: image is still N-1 (untouched — the migrate step never cut
over), but the DB may be in partially-applied schema-N state. **Do not
redeploy on top of this state.** A subsequent deploy would attempt to
re-apply the same failing migration and likely worsen the partial
state.

Investigate manually:

1. Connect via `psql "$DATABASE_URL"`.
2. Query `pg_class` / `information_schema.columns` to determine which
   DDL committed.
3. Cross-link to `docs/runbooks/neon-outage.md` if Neon's API is
   broadly unhealthy (HTTP 5xx on the restore call may indicate a
   region-wide Neon issue, not a per-request failure).
4. Once Neon is healthy, retry the LSN reset manually via `curl` using
   the same body shape as the script (see
   `scripts/rollback-production.sh` lines 153–179 for the canonical
   call).

### Auto-rollback succeeded but app behaviour is still wrong

The rollback completed cleanly (image N-1, schema N-1, audit row,
telemetry, health check 200) but users still see the original
regression.

This means the symptom that motivated the rollback wasn't actually
caused by the rolled-back deploy — there's an upstream issue (a Modal
side change, an external API misbehaving, a partner-integration
breakage). Escalate to standard incident response:

1. Check Modal, Fly, Neon, and partner-API status pages.
2. Check `docs/runbooks/modal-outage.md`,
   `docs/runbooks/budget-exhaustion.md`, and any other partner-specific
   runbooks.
3. If the upstream is healthy, the bug is in code that hasn't changed
   recently — debug as a normal production incident, not a deploy
   regression.

---

## Related

- `docs/runbooks/manual-rollback.md` — operator-initiated rollback path
  (no migration involved; no `pre-rollback-*` branch).
- `docs/runbooks/neon-outage.md` — Neon API health, scale-to-zero, and
  general DB recovery.
- `docs/runbooks/vision-service-rollback.md` — wire-format ordering for
  vision-side rollback.
- `scripts/lint-migrations.sh` — `@breaking_ok` enforcement.
- `scripts/rollback-production.sh` — the script the composite action
  wraps; canonical Neon restore call at lines 153–179.
- `.github/actions/rollback-production/action.yml` — composite action
  contract.
- `issues/137-rollback-action-composite.md` — section 4 (Data-loss
  contract), section "Migrate before image cutover" (failure-mode
  contract).
- `issues/162-cleanup-pre-rollback-neon-branches.md` — scheduled pruning
  of `pre-rollback-*` branches.
