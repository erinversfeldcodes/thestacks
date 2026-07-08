# `rollback-production` composite action

Wraps `scripts/rollback-production.sh` so its secret dependencies are
**declarative inputs** — every secret the script reads is named at the
call site instead of inherited silently from the surrounding `env:`
block. Reusable from `deploy-production.yml`'s SLO-gate failure path
and from any future `workflow_dispatch` operator-initiated rollback.

## What it does

Three rollback legs, **executed in this order**:

1. **Core image** — `fly deploy --image $CORE_PREV_IMAGE` against
   `$CORE_APP`, then waits on `/api/health` via `fly proxy`.
2. **Neon DB** (optional) — `POST /branches/{id}/restore` resets the
   prod branch to the captured pre-migrate LSN. The pre-rollback state
   is preserved as a `pre-rollback-<sha7>-<ts>` Neon branch (free
   safety net).
3. **Modal vision** (optional) — clones `origin-remote` at
   `$MODAL_PREV_COMMIT`, runs `modal deploy apps/vision/modal_app.py`
   to revert the Modal app to the previous revision.

### Ordering invariant

Core image first, then DB, then vision. This is forced by what each
direction guarantees (see
[`docs/runbooks/vision-service-rollback.md`](../../../docs/runbooks/vision-service-rollback.md)
for the long form):

- **Image N-1 ↔ schema N** is **safe** by construction. The
  `migration-safety` lint enforces expand-contract migrations, so
  the post-migrate schema is forward-compatible with the previous
  image. New columns are unused; no read/write conflicts.
- **Image N ↔ schema N-1** is **unsafe**: image N may write columns
  that don't exist in the older schema → INSERT/UPDATE failures.

So we revert the image *first* (entering the safe corner), then the
DB, then vision (which is stateless w.r.t. the DB schema).

## Inputs

### Required

| Input | Used by | Example |
|---|---|---|
| `core-prev-image` | core leg | `registry.fly.io/thestacks-core@sha256:abc…` |
| `fly-api-token` | core leg (`fly deploy`) | `${{ secrets.FLY_API_TOKEN }}` |
| `rollback-reason` | audit log + stdout | `"SLO gate breached: vision_fuse_open=1"` |
| `failed-sha` | audit log (`metadata.failed_sha`) | `${{ github.sha }}` |
| `triggered-by` | audit log (`metadata.triggered_by`) | `slo-gate` \| `manual` \| `step-failure` \| `migration-failure` |
| `database-url` | audit log INSERT | `${{ secrets.DATABASE_URL }}` |
| `cloak-key` | audit-metadata encryption | `${{ secrets.CLOAK_KEY }}` |

### Optional (with defaults)

| Input | Default | Notes |
|---|---|---|
| `core-app` | `thestacks-core` | Fly app name. |
| `modal-app` | `thestacks-vision` | Modal prod app name. |
| `modal-prev-commit` | `""` | Empty = skip Modal rollback (bootstrap, see below). |
| `modal-token-id` | `""` | **Required when** `modal-prev-commit` is set; else unused. |
| `modal-token-secret` | `""` | **Required when** `modal-prev-commit` is set. |
| `origin-remote` | `https://github.com/erinversfeld/thestacks.git` | Git remote for Modal commit checkout. |
| `neon-project-id` | `""` | **Required when** `pre-migrate-lsn` is set. |
| `neon-api-key` | `""` | **Required when** `pre-migrate-lsn` is set. |
| `neon-branch-id` | `""` | **Required when** `pre-migrate-lsn` is set. |
| `pre-migrate-lsn` | `""` | Empty = skip DB rollback (image-only — see below). |
| `github-token` | `""` | Forwarded to `git clone` of the prev Modal commit (`url.insteadOf` rewrite) so private repos authenticate. Pass `${{ github.token }}`. `contents: read` is sufficient. Required when `modal-prev-commit` is set and `origin-remote` is a private repo. |

### Outputs

| Output | Values |
|---|---|
| `core-rolled-back` | `true` (rolled back), `false` (skipped — image already current), `error` (leg failed). |
| `modal-rolled-back` | `true`, `false` (skipped — `modal-prev-commit` empty), `error`. |
| `db-rolled-back` | `true`, `false` (skipped — `pre-migrate-lsn` empty), `error`. |

## Bootstrap edge cases

Both Modal and DB rollback are optional **by design**. The first
deploy on a brand-new prod stack and certain operator-suppressed
flows produce empty inputs that exit cleanly rather than failing:

- **No `main-<sha>` tag yet** → `modal-prev-commit` is empty. The
  script prints `WARN rollback: MODAL_PREV_COMMIT is unset` and
  completes a **core+DB-only rollback**. Output:
  `modal-rolled-back=false`. Subsequent deploys (after `tag-main.yml`
  stamps a tag) will roll vision back normally.
- **No pre-migrate LSN captured** → `pre-migrate-lsn` is empty (e.g.
  the deploy ran without migrations, or operator override). The
  script prints `WARN rollback: PRE_MIGRATE_LSN unset` and completes
  a **core+vision-only rollback** (image-only DB-wise). Output:
  `db-rolled-back=false`.

Neither case is a failure — both are documented partial-rollback
paths.

## Failure modes

The action exits non-zero (and `log-audit` does **not** run, leaving
audit-row absence as a signal that the rollback didn't complete) on:

| Cause | Detection | Output |
|---|---|---|
| Required env missing | `validate-inputs` step's bash assertions | exit 1 before script runs |
| `fly deploy` fails | script exits 1 with `FAIL rollback: fly deploy (core) failed` | `core-rolled-back=error` |
| Neon restore HTTP non-2xx | script exits 1 with `FAIL rollback: Neon restore returned HTTP <code>` | `db-rolled-back=error` |
| Modal deploy fails | script exits 1 with `FAIL rollback: modal deploy …` | `modal-rolled-back=error` |
| `validate-inputs` fails (e.g. `pre-migrate-lsn` set without Neon vars) | bash `exit 1` | all three outputs `error` |

`emit-outputs` always runs (`if: always()`) so the workflow can read
the per-leg status even on failure. The audit row is the source of
truth for "did rollback complete?" — its **absence** indicates the
action exited before reaching `log-audit`.

## How to invoke from `workflow_dispatch`

`deploy-production.yml`'s `workflow_dispatch:` inputs include a
`manual_rollback` boolean. When set, the workflow gates the deploy +
SLO-gate steps with `if: ${{ !inputs.manual_rollback }}` and goes
straight to this composite action (which fires on
`(failure() || inputs.manual_rollback) && env.CORE_PREV_IMAGE != ''`).
A standalone job invocation looks like:

```yaml
on:
  workflow_dispatch:
    inputs:
      manual_rollback:
        description: "Roll back the prod stack without running a deploy first."
        type: boolean
        default: false

jobs:
  rollback:
    if: ${{ inputs.manual_rollback }}
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Resolve previous-state SHAs
        id: prev
        run: |
          PREV_TAG=$(git tag --list 'main-*' --sort=-creatordate | head -1)
          # …extract CORE_PREV_IMAGE + MODAL_PREV_COMMIT from the tag…
      - name: Rollback production stack
        uses: ./.github/actions/rollback-production
        with:
          core-prev-image: ${{ steps.prev.outputs.core-image }}
          modal-prev-commit: ${{ steps.prev.outputs.modal-commit }}
          modal-token-id: ${{ secrets.MODAL_TOKEN_ID }}
          modal-token-secret: ${{ secrets.MODAL_TOKEN_SECRET }}
          fly-api-token: ${{ secrets.FLY_API_TOKEN }}
          neon-project-id: ${{ secrets.NEON_PROJECT_ID }}
          neon-api-key: ${{ secrets.NEON_API_KEY }}
          neon-branch-id: ${{ steps.prev.outputs.neon-branch-id }}
          pre-migrate-lsn: ""  # manual rollbacks skip DB by default
          rollback-reason: "Manual rollback by @${{ github.actor }}"
          failed-sha: ${{ github.sha }}
          triggered-by: manual
          database-url: ${{ secrets.DATABASE_URL }}
          cloak-key: ${{ secrets.CLOAK_KEY }}
          github-token: ${{ github.token }}
```

For the full operator procedure (when to manual-rollback, what to
expect, post-rollback checks) see the runbook at
[`docs/runbooks/manual-rollback.md`](../../../docs/runbooks/manual-rollback.md).

## See also

- [`docs/runbooks/vision-service-rollback.md`](../../../docs/runbooks/vision-service-rollback.md)
  — rationale for the core → DB → vision ordering invariant.
- [`scripts/rollback-production.sh`](../../../scripts/rollback-production.sh)
  — the script this action wraps; canonical env-var contract.
- [`apps/core/lib/stacks/audit.ex`](../../../apps/core/lib/stacks/audit.ex)
  — `Stacks.Audit.log_rollback/1`, the audit + telemetry helper invoked
  by the `log-audit` step.
- Issue [#137](../../../issues/complete/137-rollback-action-composite.md) —
  full design rationale and DoD checklist.
