# Runbook: Manual Production Rollback

**Severity:** P1 (operator-initiated, planned)
**Owner:** Platform operator
**Last reviewed:** 2026-05-01

---

## Behavioural contract (read first)

A manual rollback is **image-only** by design. Fly's prod core image is
reverted to the previous `main-<sha>` tag, and Modal vision is reverted
to the matching commit. **The Neon prod database is NOT reverted** —
schema and all stored rows stay in their current state.

This is a deliberate trade-off:

1. **No data loss at the row level.** Writes made between the bad
   deploy and the manual rollback stay on disk. Audit-log rows, new
   user registrations, bookshelf placements, marketplace activity —
   all preserved. The composite action emits `db-rolled-back=false`
   on this path; the script logs `WARN rollback: PRE_MIGRATE_LSN unset
   — skipping Neon DB rollback (image-only)` and proceeds.
2. **The previous image reads the current schema safely.** Every prod
   migration is enforced expand-contract by `scripts/lint-migrations.sh`
   (new columns are unused by the previous image; destructive ops
   require explicit `@breaking_ok`). Image N-1 reading schema N is the
   safe direction of the asymmetry.
3. **Behavioural reverts may have edge cases.** If image N introduced
   new validation rules, new write patterns, or new feature flags,
   rows written under image N may surface unexpectedly under image
   N-1 (usually benign — e.g. a new column has data the older code
   ignores — but worth checking in post-rollback verification).

**When this runbook is NOT the right path.** If a destructive migration
partially applied and you need to revert the schema as well as the
image, this runbook can't help — the manual-rollback path does not
capture or reset the LSN. Read `migration-recovery.md` for the
auto-rollback path's semantics (which DOES reset the LSN at the cost of
losing writes since the LSN snapshot).

For comparison: the auto-rollback path (SLO gate breach during a deploy)
captures a Postgres LSN before the migrate step runs and resets the prod
Neon branch back to that LSN if the gate fires. That path drops up to
~17 minutes of writes (deploy time + 10-minute gate window + rollback
runtime). See `issues/137-rollback-action-composite.md` section 4
("Data-loss contract") for the bound and its derivation. **The
manual-rollback path documented here does not have that data-loss
penalty.**

---

## When to use this runbook

Trigger a manual rollback when:

- The SLO gate already ran and passed but a regression slipped through
  the SLI set (e.g. a UX bug, a partner-integration error, a slow query
  not captured by `latency_p99_ms`). The auto-rollback fires only on SLI
  breach; this is the on-ramp for "the gate said green but it isn't".
- An operator wants to revert to the previous deploy without first
  pushing a corrective commit. Useful when the team is offline or a
  forward-fix would take long enough that reverting is the lower-risk
  path.
- A forward-fix isn't possible quickly. Ship known-good code now; debug
  the failed deploy in a follow-up.

If a migration partially applied and the auto-rollback already fired,
this is **not** the right runbook — read `migration-recovery.md` instead.
The auto-rollback path captured a fresh LSN before migrating; the
manual path does not.

---

## Prerequisites

Before triggering, verify:

1. **GitHub Actions permissions.** The operator must have
   `workflow_dispatch` permission on `Deploy production`
   (`.github/workflows/deploy-production.yml`).
2. **Required GH repo secrets exist** (set once at project bootstrap;
   confirm via `gh secret list`):
   - `FLY_API_TOKEN`
   - `MODAL_TOKEN_ID`, `MODAL_TOKEN_SECRET`
   - `NEON_PROJECT_ID`, `NEON_API_KEY`
   - `CLOAK_KEY`
   - `STACKS_PROD_DB_ROLE`, `STACKS_PROD_DB_PASSWORD`,
     `STACKS_PROD_DB_HOST`, `STACKS_PROD_DB_NAME`
3. **`main-<sha>` git tags exist.** The `record-prev-state` step resolves
   `CORE_PREV_IMAGE` and `MODAL_PREV_COMMIT` from the two most-recent
   `main-*` tags (newest = current HEAD; second-newest = rollback
   target). On a brand-new prod stack there are no tags — see issue
   #163 for the bootstrap procedure (runbook pending). The one-liner
   is `git tag main-bootstrap "$(git rev-parse main^)" && git push
   origin main-bootstrap`.
4. **Read the behavioural contract above** and confirm the
   image-only revert (and any per-row edge cases under image N-1) is
   acceptable for the current situation.

---

## Procedure

### 1. Confirm the behavioural contract

Re-read the "Behavioural contract" section above. If image-only
revert (with no DB-level data loss) is acceptable for this situation,
proceed.

### 2. Trigger the workflow

Either via the CLI:

```bash
gh workflow run deploy-production.yml -f manual_rollback=true
```

…or via the GitHub Actions UI:

1. Open `.github/workflows/deploy-production.yml` in the GitHub UI.
2. Click "Run workflow".
3. Tick `manual_rollback: true`.
4. Click "Run workflow".

### 3. Watch the run live

Open the run in the GitHub Actions UI. Expected step sequence on the
manual-rollback path:

| Step | Expected outcome |
|------|------------------|
| `actions/checkout` + setup | runs |
| `record-prev-state` | runs; resolves `CORE_PREV_IMAGE` + `MODAL_PREV_COMMIT` from tags |
| `Generate proto artifacts` | runs |
| `Compose DATABASE_URL` | runs |
| `Install postgresql-client` | runs (cheap; harmless on this path) |
| `Capture pre-migrate Neon LSN` | **skipped** (`if: !inputs.manual_rollback`) |
| `Run prod migrations` | **skipped** |
| `deploy-stack.sh` | **skipped** |
| `check-slo-gate.sh` | **skipped** |
| `rollback-production composite action` | **fires** (`if: failure() || inputs.manual_rollback`) |
| `upload-artifact gate-observations` | runs (warns: no file produced) |
| `summary` | runs |

Total runtime: ≈5–10 min.

### 4. Read the composite-action output

After the rollback step completes, the composite action emits three
outputs (visible in the step's expanded log):

- `core-rolled-back=true` — `fly deploy --image $CORE_PREV_IMAGE` succeeded.
  May be `false` (skipped) if the currently-serving image already
  matches `CORE_PREV_IMAGE` (rare on a manual rollback path; would
  indicate the previous deploy never cut over).
- `db-rolled-back=false` — expected on the manual-rollback path. No LSN
  was captured (the capture step is gated behind `!manual_rollback`),
  so the script logs `WARN rollback: PRE_MIGRATE_LSN unset — skipping
  Neon DB rollback (image-only)` and proceeds.
- `modal-rolled-back=true` — Modal vision rolled back to
  `MODAL_PREV_COMMIT`. May be `false` if `MODAL_PREV_COMMIT` resolved
  empty (bootstrap edge case — no `main-*` tags). On a long-lived prod
  stack this should always be `true`.

If any output is `error`, jump to "Failure modes" below.

---

## Post-rollback verification

Run through this checklist within ~5 minutes of the workflow completing:

- [ ] **Fly's serving image SHA matches `CORE_PREV_IMAGE`.**
  ```bash
  fly status -a thestacks-core
  ```
  The `Image` line should match the SHA logged at the rollback step's
  `==> Rolling core back to image …` line.
- [ ] **Health check passing.** Should return 200 within ~60 seconds of
  the rollback completing:
  ```bash
  curl -sS https://thestacks.fly.dev/api/health
  ```
- [ ] **Audit row written.** The composite action's `log-audit` step
  invokes `Stacks.Audit.log_rollback/1` after the rollback script
  succeeds. Verify a row landed in `audit.audit_log` (admin-only
  query):
  ```sql
  SELECT occurred_at, action, resource_id
    FROM audit.audit_log
   WHERE action = 'system.rollback'
   ORDER BY occurred_at DESC
   LIMIT 1;
  ```
  Expected: a row whose `occurred_at` is within ~1 minute of the
  workflow run, `action = 'system.rollback'`, and `resource_id` equal
  to the SHA being rolled back from (the broken-deploy SHA — the
  `failed_sha` field of the helper, carried in `resource_id` because
  it isn't a UUID and the audit table's UUID column rejects it).
  The `metadata` column is Cloak-encrypted bytea — `SELECT metadata`
  returns ciphertext. To confirm `triggered_by = "manual"` and
  `target_image = CORE_PREV_IMAGE`, either: (a) read the workflow
  run's `log-audit` step output (the helper logs the metadata before
  encrypting), or (b) decrypt via `Stacks.Vault` from a remsh into
  the prod app — admin-only, rarely needed.
- [ ] **Telemetry event visible in Axiom.** The `[:stacks, :system,
  :rollback]` event is emitted by `log_rollback/1`. Check the rollback
  dashboard / saved query.
- [ ] **No user-visible regressions.** Smoke-check the symptoms that
  motivated the rollback — they should be gone now that the previous
  image is serving.

---

## Pre-rollback Neon branch (`pre-rollback-*`)

**Not created on this path.** The Neon LSN reset only fires when
`pre-migrate-lsn` is set on the composite action; the manual-rollback
path doesn't capture an LSN, so the script emits the WARN line and
skips the leg. No `pre-rollback-*` branch appears in the Neon console.

`pre-rollback-*` branches **only** exist on auto-rollback paths where
the migrate step ran and an LSN was captured. If you arrived here
because a migration was rolled back, see `migration-recovery.md` —
that runbook covers the pre-rollback branch and how to promote it back
if the rollback itself was wrong.

---

## Failure modes

### Workflow fails before reaching the rollback step

Rare on this path because the manual-rollback flow is short — most
intermediate steps are skipped. If a setup step fails (`checkout`,
`setup-beam`, etc.), it's a CI infrastructure issue rather than a
rollback-specific failure. Investigate the failed step's logs; rerun the
workflow once the underlying issue is fixed.

### Rollback step fails (`rollback-production.sh` exited non-zero)

The composite action's `run-rollback` step exits non-zero. The
`emit-outputs` step still runs (`if: always()`) and parses
`/tmp/rollback-output.log` to classify which leg failed:

- `core-rolled-back=error` → the `fly deploy --image` call failed.
  Inspect `/tmp/rollback-output.log` (in the step's logs) for the Fly
  error. Common causes: Fly app under heavy contention, image not
  pullable from the registry, transient Fly-API outage. Re-trigger the
  workflow once Fly is healthy.
- `modal-rolled-back=error` → either `git checkout` of
  `MODAL_PREV_COMMIT` failed (the SHA isn't fetchable from the origin
  remote) or `modal deploy` itself failed. Check Modal status and
  inspect the workflow log for the specific failure marker (`FAIL
  rollback: could not check out …` vs `FAIL rollback: modal deploy …`).
- `db-rolled-back=error` → expected when an upstream leg failed
  before the DB-skip check ran or the rollback log was never produced.
  Two legitimate cases on the manual-rollback path:
  1. The core leg failed (`fly deploy --image` exited non-zero), the
     script bailed out at line 113 of `rollback-production.sh` before
     reaching the DB WARN-and-skip at line 154. Parser falls through
     to its default `error`.
  2. `validate-inputs` rejected an empty `core-prev-image` (the
     fresh-prod-stack bootstrap edge case — see step 3 in Prerequisites
     above), so `run-rollback` never executed and `/tmp/rollback-output.log`
     never existed. Parser emits `error` for all three legs.
  Investigate the upstream failure first. If `core-rolled-back=true`
  AND `db-rolled-back=error`, the short-circuit logic is broken — file
  a P1 issue against the composite action.

### Previous `main-<sha>` tag doesn't exist

`record-prev-state` resolves `CORE_PREV_IMAGE` from the
second-most-recent `main-<sha>` tag. On a brand-new prod stack this is
empty → the composite action exits non-zero in the validate-inputs step
with `core-prev-image is required`.

For a fresh prod environment, seed an initial tag before the first
deploy (Issue #163 will turn this into a dedicated runbook):

```bash
git tag main-bootstrap "$(git rev-parse main^)"
git push origin main-bootstrap
```

…then re-run the workflow.

---

## Related

- `docs/runbooks/migration-recovery.md` — recovery from a partially-applied
  migration (auto-rollback path with `pre-rollback-*` branch).
- `docs/runbooks/vision-service-rollback.md` — vision-side rollback
  ordering and wire-format constraints (deploy core before vision; same
  invariant applies to rollback).
- `.github/actions/rollback-production/action.yml` — composite action
  contract and input semantics.
- `scripts/rollback-production.sh` — the underlying script the composite
  action wraps.
- `scripts/parse-rollback-output.sh` — output classifier used by the
  composite action.
- `issues/137-rollback-action-composite.md` — the parent issue
  (data-loss contract, ordering invariant, bootstrap edge cases).
