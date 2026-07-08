# Issue #137: Rollback automation — composite action + migrate-before-image-cutover

## Summary

Two structural changes to the production deploy / rollback path, bundled
because both modify the same `deploy-production.yml` surface:

1. **Composite action** wrapping `scripts/rollback-production.sh` so its
   secret dependencies are declarative (explicit `inputs:`) instead of
   implicit (job-level `env:` inheritance). Adds a manual-trigger entry
   point so operators can roll back without waiting for the SLO gate.
2. **Migrate before image cutover** — run `mix ecto.migrate` against
   the prod `DATABASE_URL` from the GitHub Actions runner *before*
   `fly deploy` swaps the core image, so a partially-failing migration
   can't leave the schema half-applied while the new image is already
   serving traffic.

## User Stories
N/A (platform).

## Goal

After this issue ships:

- The rollback path is **declaratively wired**: every secret it needs is
  named at the call site; nothing inherits silently from the
  surrounding `env:` block. Reusable from any future workflow.
- An **operator-initiated rollback** is a single `workflow_dispatch`
  click — no need to fake an SLO breach via `force_rollback` to
  exercise the rollback path.
- A **migration that fails partway through** aborts the workflow with
  the **old image still serving traffic**. The new image is never
  cut over until migrations are confirmed clean against prod.
- **DB rollback is automated**: a pre-migrate Neon LSN snapshot is
  captured; on rollback the production branch is reset to that LSN,
  reverting both the schema AND any writes made after the snapshot.
  Bounded data-loss window (≤15 min worst case — deploy time + SLO
  gate duration). Documented contract; operators understand the
  trade-off.
- **The whole flow is tested end-to-end against real prod** by
  letting the current Modal-budget breach trigger the SLO gate on
  the next deploy — that produces a guaranteed rollback event we
  can observe rather than simulate. (See "Test plan" below.)

## Scope Check
- One composite action + 2-3 small steps in `deploy-production.yml`.
- ~250 LOC across the action's `action.yml`, `README.md`, the workflow
  edits, and a new audit/telemetry shim.
- Two concerns (rollback action + migration ordering) but they share
  the same deploy-production.yml surface and one PR is cleaner than
  two stacked PRs that both touch this file.

## Wiring
- [x] Includes router/workflow wiring — updates `deploy-production.yml`
      to use the new action and adds the migrate-before-cutover step.

## Technical Requirements

### 1. Composite action

#### Layout

```
.github/actions/rollback-production/
├── action.yml
└── README.md
```

#### `action.yml` shape

```yaml
name: "Rollback production stack (core + vision)"
description: >
  Wraps scripts/rollback-production.sh with declarative inputs. Every
  secret the script reads is named here; nothing is inherited from
  the surrounding env: block.
inputs:
  core-app:
    description: "Fly app name for the core service"
    required: false
    default: thestacks-core
  core-prev-image:
    description: >
      Previous Fly image digest/SHA to roll core back to. REQUIRED.
      Resolve from the latest main-<sha> tag via record-prev-state
      (see deploy-production.yml).
    required: true
  modal-app:
    description: "Modal prod app name"
    required: false
    default: thestacks-vision
  modal-prev-commit:
    description: >
      Previous git SHA for the Modal vision app. Empty = skip Modal
      rollback (core is the critical path; first-deploy bootstrap
      will always be empty).
    required: false
    default: ""
  modal-token-id:
    description: "Modal auth token ID. Required when modal-prev-commit is set."
    required: false
    default: ""
  modal-token-secret:
    description: "Modal auth token secret. Required when modal-prev-commit is set."
    required: false
    default: ""
  fly-api-token:
    description: "Fly.io API token (used by `fly deploy --image`)"
    required: true
  rollback-reason:
    description: "Free-form string written to stdout + audit log"
    required: true
  origin-remote:
    description: "Git remote to clone the previous Modal commit from"
    required: false
    default: "https://github.com/erinversfeld/thestacks.git"
  neon-project-id:
    description: >
      Neon project ID for the production project (`thestacks`). Used
      to restore the prod branch to the pre-migrate LSN. Required when
      pre-migrate-lsn is set.
    required: false
    default: ""
  neon-api-key:
    description: "Neon API key scoped to the production project."
    required: false
    default: ""
  neon-branch-id:
    description: >
      Neon branch ID for the prod project's default (primary) branch.
      Resolved by the `Capture pre-migrate Neon LSN` step (queries
      `/branches`, picks the one with `default: true`). Required when
      pre-migrate-lsn is set — the restore endpoint is path-scoped to
      a specific branch.
    required: false
    default: ""
  pre-migrate-lsn:
    description: >
      Postgres LSN captured via `SELECT pg_current_wal_lsn()`
      immediately before the migrate-before-cutover step ran. Empty =
      skip DB rollback (e.g. first deploy, or operator-suppressed).
      When set, the prod branch is restored to this LSN via the Neon
      `branches/{id}/restore` API as part of the rollback path. The
      pre-rollback state is preserved as a `pre-rollback-*` branch in
      the Neon project (free safety net — Neon's self-restore API
      requires preserve_under_name).
    required: false
    default: ""
outputs:
  core-rolled-back:
    description: "true if core successfully rolled back to core-prev-image"
    value: ${{ steps.run.outputs.core-rolled-back }}
  modal-rolled-back:
    description: >
      true if Modal vision rolled back, false if skipped, error if failed
    value: ${{ steps.run.outputs.modal-rolled-back }}
  db-rolled-back:
    description: >
      true if the Neon prod branch was reset to pre-migrate-lsn, false
      if pre-migrate-lsn was empty (skipped by design), error if reset
      failed.
    value: ${{ steps.run.outputs.db-rolled-back }}
runs:
  using: composite
  steps:
    - name: Validate inputs
      shell: bash
      run: |
        if [[ -z "${{ inputs.core-prev-image }}" ]]; then
          echo "::error::core-prev-image is required" >&2
          exit 1
        fi
        if [[ -n "${{ inputs.modal-prev-commit }}" ]]; then
          if [[ -z "${{ inputs.modal-token-id }}" || -z "${{ inputs.modal-token-secret }}" ]]; then
            echo "::error::modal-token-id + modal-token-secret are required when modal-prev-commit is set" >&2
            exit 1
          fi
        fi
    - name: Run rollback script
      id: run
      shell: bash
      env:
        CORE_APP: ${{ inputs.core-app }}
        CORE_PREV_IMAGE: ${{ inputs.core-prev-image }}
        MODAL_APP_NAME: ${{ inputs.modal-app }}
        MODAL_PREV_COMMIT: ${{ inputs.modal-prev-commit }}
        MODAL_TOKEN_ID: ${{ inputs.modal-token-id }}
        MODAL_TOKEN_SECRET: ${{ inputs.modal-token-secret }}
        FLY_API_TOKEN: ${{ inputs.fly-api-token }}
        ROLLBACK_REASON: ${{ inputs.rollback-reason }}
        ORIGIN_REMOTE: ${{ inputs.origin-remote }}
      run: |
        bash "${{ github.action_path }}/../../../scripts/rollback-production.sh"
        # Outputs reflect what the script's exit code + stdout actually did:
        echo "core-rolled-back=true" >> "$GITHUB_OUTPUT"
        if [[ -n "${{ inputs.modal-prev-commit }}" ]]; then
          echo "modal-rolled-back=true" >> "$GITHUB_OUTPUT"
        else
          echo "modal-rolled-back=false" >> "$GITHUB_OUTPUT"
        fi
```

#### `README.md`

Operator-oriented. Sections:
- What it does + ordering invariant (core first, then vision, per
  `docs/runbooks/vision-service-rollback.md`).
- Required + optional inputs with examples.
- Bootstrap edge case (first deploy has no `main-*` tag → empty
  `modal-prev-commit` → core-only rollback by design).
- Failure modes and what they mean operationally.
- How to invoke from a `workflow_dispatch` for a manual rollback.
- Cross-link to `docs/runbooks/manual-rollback.md` (new — see DoD).

### 2. Manual-trigger entry point

Add an input to `deploy-production.yml`'s `workflow_dispatch:` block:

```yaml
inputs:
  manual_rollback:
    description: "Roll back the prod stack without running a deploy first."
    type: boolean
    default: false
```

Add a job-level `if:` short-circuit so when `manual_rollback == true`
the workflow skips deploy-stack + gate and goes straight to the
composite action with `core-prev-image` resolved from the latest
`main-*` tag (same lookup the existing `record-prev-state` step uses).

### 3. Migrate before image cutover

Add a new step in `deploy-production.yml` between `Compose
DATABASE_URL` (existing) and `deploy-stack.sh` (existing):

```yaml
- name: Run prod migrations (before image cutover)
  env:
    MIX_ENV: prod
    DATABASE_URL: ${{ env.DATABASE_URL }}
    CLOAK_KEY: ${{ secrets.CLOAK_KEY }}
  run: |
    cd apps/core
    mix deps.get --only prod
    mix compile
    mix ecto.migrate
```

#### Failure-mode contract

- Migration exits non-zero → workflow fails BEFORE `deploy-stack.sh`
  → old image still serves traffic.
- The composite action's `if: failure()` clause fires → **LSN
  reset runs even though no image was deployed**. This is
  deliberate: a partially-applied migration is exactly the case
  where LSN reset earns its keep — Postgres-level rollback can
  unwind a half-finished `ALTER TABLE` that `def down` cannot.
  Image is unchanged (still N-1), so post-restore the system is
  cleanly at image N-1 / schema N-1.
- The composite action skips core image rollback in this branch
  (CORE_PREV_IMAGE == currently-serving image → no-op
  `fly deploy --image` would still succeed but adds noise; better
  to detect and skip with a log line). Modal is also skipped
  because the prior `modal deploy` step never ran.
- Audit row records `triggered_by: "migration-failure"` so this
  case is distinguishable from SLO-gate breaches in retrospective.
- The `migration-safety` lint already enforces `@breaking_ok` on
  destructive ops; that contract is unchanged. Expand-contract
  discipline means most failed migrations leave the DB in a state
  the prior image can still read — and now LSN reset cleans up
  even the cases that don't.

#### Backwards-compat for in-container migrate

`deploy-stack.sh:722` currently runs `Stacks.Release.migrate()`
after the core deploy. After this change:

- **Keep the call** as a no-op safety net. On a healthy path the
  runner already migrated → in-container call finds no pending
  migrations → returns `:ok` immediately. On the path where the
  runner was somehow skipped (operator override, future code
  change), the in-container call still applies migrations.
- **Add a comment** at the call site documenting that the runner
  is the primary migration path and this is defence-in-depth.

#### Preview-deploy unchanged

Preview Neon branches always migrate in-container as part of
`deploy-stack.sh` (no separate runner step in the preview job).
Preview migrations are cheap and isolated to the preview branch's
copy-on-write Neon clone; failure rolls back the branch via
`cleanup-preview.sh`. No change.

### 4. DB rollback via Neon LSN reset

The composite action also rolls back the schema + any data writes
made after the pre-migrate snapshot. This makes the contract
**"image and DB go back together"** — operators don't end up with
core N-1 talking to schema N.

#### Capture the LSN

The Neon API's Branch object does **not** expose a `current_lsn`
field — only `parent_lsn` (the fork-point LSN), which is fixed at
branch creation. Confirmed against the OpenAPI spec at
`https://neon.com/api_spec/release/v2.json` (Branch schema:
`id`, `parent_id`, `parent_lsn`, `current_state`, `logical_size`,
… no current LSN).

Neon's documented pattern is to capture the LSN from Postgres
itself via `SELECT pg_current_wal_lsn()`. Add a step to
`deploy-production.yml` BEFORE `Run prod migrations (before image
cutover)`:

```yaml
- name: Capture pre-migrate Neon LSN (prod)
  id: capture-lsn
  env:
    DATABASE_URL: ${{ env.DATABASE_URL }}
  run: |
    LSN=$(psql "$DATABASE_URL" -t -A -c "SELECT pg_current_wal_lsn();")
    if [[ -z "$LSN" ]]; then
      echo "::error::Failed to capture pre-migrate LSN" >&2
      exit 1
    fi
    echo "lsn=$LSN" >> "$GITHUB_OUTPUT"
    echo "Captured pre-migrate LSN: $LSN"
```

`pg_current_wal_lsn()` returns a value like `0/16E8090` — that
literal string is what Neon's restore API expects in `source_lsn`.

The LSN flows through to the rollback action via
`pre-migrate-lsn: ${{ steps.capture-lsn.outputs.lsn }}` in the
final step.

We also need the prod branch ID for the restore call. Resolve it
once in the same step (cached for the rollback action):

```yaml
    BRANCH_ID=$(curl -sL \
      -H "Authorization: Bearer $NEON_API_KEY" \
      "https://console.neon.tech/api/v2/projects/$NEON_PROJECT_ID/branches" \
      | python3 -c "
import json, sys
branches = json.load(sys.stdin).get('branches', [])
prod = next((b for b in branches if b.get('default') is True), None)
if prod is None:
    sys.exit('default (primary) branch not found')
print(prod['id'])
")
    echo "branch-id=$BRANCH_ID" >> "$GITHUB_OUTPUT"
```

(Selecting on `default: true` rather than `name == "production"`
avoids assumptions about what the primary branch was named at
project creation. The Branch schema's `primary` field is marked
DEPRECATED in favour of `default`.)

#### Reset on rollback

Verified shape (Neon API v2):

- Endpoint: `POST /projects/{project_id}/branches/{branch_id}/restore`
- Body: `{"source_branch_id": "<same branch_id>", "source_lsn": "<captured LSN>", "preserve_under_name": "pre-rollback-<sha>-<timestamp>"}`
- Self-restore (source_branch_id == branch_id) **requires**
  `preserve_under_name` — Neon snapshots the pre-rollback state
  under that name as a backup branch. We embrace this: the
  pre-rollback branch is a free safety net if the rollback itself
  was a mistake.
- Primary-branch self-restore is supported (confirmed against
  Neon docs `https://neon.com/docs/guides/branch-restore` —
  the root branch can use itself as `source_branch_id` when
  `preserve_under_name` is set).

The composite action's run step adds the Neon-restore block,
called **after core image rollback** but before vision rollback.

#### Rollback ordering: core image first, then DB, then vision

Critical invariant. The order is forced by what each direction
guarantees:

- **Image N-1 ↔ schema N**: SAFE by construction. The
  `migration-safety` lint enforces expand-contract migrations
  (`@breaking_ok` required for destructive ops), which means
  the post-migrate schema is forward-compatible with the
  previous image. New columns are unused; no read/write
  conflicts.
- **Image N ↔ schema N-1**: UNSAFE. Image N may write columns
  that don't exist in schema N-1 → INSERT/UPDATE failures, data
  corruption, or 500s.

Therefore: revert the image *before* reverting the DB. The
brief window where image N-1 talks to schema N (post-migrate,
pre-LSN-reset) is safe; the dangerous window (image N talking
to schema N-1) is avoided entirely.

Vision goes last because it doesn't share a schema contract
with the DB — it's a stateless HTTP service whose only
persistent dependency is the Modal-side image cache.

```bash
if [[ -n "$PRE_MIGRATE_LSN" ]]; then
    PRESERVE_NAME="pre-rollback-${GITHUB_SHA:0:7}-$(date -u +%Y%m%dT%H%M%SZ)"
    echo "==> Restoring Neon prod branch to LSN $PRE_MIGRATE_LSN (backup: $PRESERVE_NAME)..."
    HTTP=$(curl -sL -o /tmp/neon-restore.json -w "%{http_code}" -X POST \
        -H "Authorization: Bearer $NEON_API_KEY" \
        -H "Content-Type: application/json" \
        -d "$(jq -nc \
            --arg src "$NEON_BRANCH_ID" \
            --arg lsn "$PRE_MIGRATE_LSN" \
            --arg name "$PRESERVE_NAME" \
            '{source_branch_id: $src, source_lsn: $lsn, preserve_under_name: $name}')" \
        "https://console.neon.tech/api/v2/projects/$NEON_PROJECT_ID/branches/$NEON_BRANCH_ID/restore")
    if [[ "$HTTP" != "200" && "$HTTP" != "201" ]]; then
        echo "FAIL rollback: Neon restore returned HTTP $HTTP" >&2
        cat /tmp/neon-restore.json >&2
        exit 1
    fi
    echo "PASS rollback: Neon prod branch restored to LSN $PRE_MIGRATE_LSN"
    echo "  pre-rollback state preserved as branch: $PRESERVE_NAME"
fi
```

The preserved branch shows up in the Neon console; operators
can inspect it or promote it back to primary if the rollback
itself was wrong. Cleanup of stale `pre-rollback-*` branches is
out of scope for this issue (follow-up: scheduled job that prunes
preserved branches older than 30 days).

#### Data-loss contract

**Anything written between the LSN snapshot and the rollback is
lost.** The window is bounded by:

- Migration runtime (typically <30s for our migrations)
- Image deploy + health-check (≤5 min)
- SLO gate window (10 min)
- Rollback action runtime (≤2 min)

**Worst case ≈ 17 min** of writes lost on a triggered rollback.
Real-traffic implication during that window:
- New user registrations
- Bookshelf placements / book uploads
- Marketplace listings / offers
- Audit-log rows (other than the rollback itself)

For SLO-gate-triggered rollbacks the loss is acceptable (the
deploy was breaking; users would have hit errors anyway). For
operator-initiated rollbacks the loss is deliberate and
documented.

**Operators must know this.** `docs/runbooks/manual-rollback.md`
opens with this contract; the workflow_dispatch input help-text
references the runbook.

#### Bootstrap edge case (DB)

The very first deploy under this code captures **its own**
pre-migrate LSN (the capture step runs before migrations every
deploy, including the first) — so even the first auto-rollback
has a valid DB target. The composite action still accepts an
empty `pre-migrate-lsn` defensively (e.g. operator-suppressed,
or a future workflow change skips capture) — when empty it logs
`WARN: pre-migrate-lsn unset — skipping DB rollback (image-only)`
and proceeds.

The DB-side bootstrap is therefore a non-event under normal
conditions; only Modal lacks a rollback target on a brand-new
prod environment (see next section).

#### Bootstrap edge case (Modal target)

`MODAL_PREV_COMMIT` is resolved by `record-prev-state` from the
latest `main-<sha>` git tag — these are stamped by `tag-main.yml`
on every merge to main. The lookup is:

```bash
git tag --list 'main-*' --sort=-creatordate | head -1
```

On the very first deploy of a brand-new prod environment (no
prior merges to main → no tags), this returns empty →
`MODAL_PREV_COMMIT=""` → vision rollback skipped by the
composite action's input-handling.

For The Stacks specifically, this is academic: PR204 is **not**
the first ever merge — the repo already has many `main-<sha>`
tags from prior deploys. So `MODAL_PREV_COMMIT` resolves to a
real SHA on the very first auto-rollback under this code. See
the "Modal-prev-commit on the first auto-rollback" subsection
below for why that SHA's deploy semantics are the same regardless
of whether the original deploy used the new composite or the old
inline `modal deploy` step.

**For future environments** (e.g. a second prod stack in a
different region), seed an initial tag manually before the first
deploy:

```bash
git tag main-bootstrap "$(git rev-parse main^)"
git push origin main-bootstrap
```

This gives the first deploy a previous-target. Document this in
`docs/runbooks/bootstrap-prod-environment.md` (out of scope for
this issue — file as a follow-up if/when a second prod stack is
spun up).

#### Modal-prev-commit on the first auto-rollback under this code

When the composite action fires for the first time, it shells out
to `scripts/rollback-production.sh`, which runs:

```bash
git -C /tmp/rollback-clone checkout "$MODAL_PREV_COMMIT"
cd /tmp/rollback-clone/apps/vision
modal deploy app.py
```

`MODAL_PREV_COMMIT` resolves to a SHA that was originally deployed
**by the old inline `modal deploy` step** (since this PR introduces
the composite). That's fine: `modal deploy` is idempotent w.r.t.
revisioning — it pushes whatever code is in `apps/vision/` at the
checked-out SHA up to Modal as a new revision and points the
Modal app at it. Modal doesn't track "which workflow deployed
which revision"; it only cares about the artifact.

So the very first auto-rollback under this code:
1. Resolves a valid `MODAL_PREV_COMMIT` (the latest `main-<sha>`
   tag at deploy time).
2. Checks out that SHA, runs `modal deploy` against the vision
   sidecar.
3. Modal accepts the new revision (which happens to be identical
   to the previous app code) and the app reverts.

No special handling needed. The concern only applies on a
genuinely-empty Modal app (a brand-new prod stack), which is
covered by the bootstrap section above.

#### Required secrets (new)

- `NEON_PROJECT_ID` — GH repo secret pointing at the
  `thestacks` (production) Neon project.
- `NEON_API_KEY` — GH repo secret with API access to that
  project.

These are surfaced ONLY in `deploy-production.yml`'s job env (NOT
in `ci.yml`'s preview deploy — preview uses a different Neon
project entirely, set up in #142).

### 5. Audit + telemetry on rollback

The current rollback writes only to stdout. Add two persistent
records so operators can answer "which deploys got rolled back"
without scrolling Actions logs:

- **Audit log row** (`audit.audit_log` via `Stacks.Audit.log/1`):
  ```elixir
  %{
    action: "system.rollback",
    resource_type: "deploy",
    resource_id: # commit SHA being rolled BACK (the one that failed)
    metadata: %{
      target_image: # CORE_PREV_IMAGE
      modal_prev_commit: # MODAL_PREV_COMMIT or nil
      reason: # ROLLBACK_REASON
      triggered_by: # "slo-gate" | "manual" | "step-failure"
    }
  }
  ```
  Cloak-encrypted via the existing audit helper. Insertion happens
  AFTER the core rollback succeeds (i.e. the previous image is
  serving and the row goes into the DB on the schema the previous
  image was written against).

- **Telemetry event**: `[:stacks, :system, :rollback]` with the same
  metadata. Tagged so the SLO gate / Axiom dashboards can chart
  rollback frequency over time.

The composite action invokes a small `mix run` step after the
rollback script succeeds:

```bash
mix run -e 'Stacks.Audit.log_rollback(%{...})'
```

`Stacks.Audit.log_rollback/1` is new — wraps the audit-log insert +
telemetry emit in one call. ~30 LOC.

### 6. Update `deploy-production.yml`

Replace the inline `bash scripts/rollback-production.sh` with:

```yaml
- name: Rollback production stack
  if: ${{ failure() || inputs.manual_rollback }}
  uses: ./.github/actions/rollback-production
  with:
    core-app: thestacks-core
    core-prev-image: ${{ env.CORE_PREV_IMAGE }}
    modal-app: thestacks-vision
    modal-prev-commit: ${{ env.MODAL_PREV_COMMIT }}
    modal-token-id: ${{ secrets.MODAL_TOKEN_ID }}
    modal-token-secret: ${{ secrets.MODAL_TOKEN_SECRET }}
    fly-api-token: ${{ secrets.FLY_API_TOKEN }}
    neon-project-id: ${{ secrets.NEON_PROJECT_ID }}
    neon-api-key: ${{ secrets.NEON_API_KEY }}
    neon-branch-id: ${{ steps.capture-lsn.outputs.branch-id }}
    pre-migrate-lsn: ${{ steps.capture-lsn.outputs.lsn }}
    rollback-reason: >
      ${{ inputs.manual_rollback && format('Manual rollback by @{0}', github.actor) || 'SLO gate breached or prior step failed' }}
```

The `if:` condition now covers both the existing `failure()` trigger
(SLO gate breach or earlier step failure) and the new
`inputs.manual_rollback` trigger.

### 7. Lint composite action + all existing actions/workflows

`actionlint` is purpose-built for GitHub Actions YAML — it catches
deprecated syntax, missing required inputs, expression errors,
and shellcheck issues in inline `run:` steps that yamllint won't
see. We adopt it for the new composite action AND backfill it
across all existing workflows + actions.

#### CI step

Add to `.github/workflows/ci.yml` under the `lint` job (or as a
new `lint-actions` job if `lint` is busy enough):

```yaml
- name: Lint GitHub Actions YAML
  uses: rhysd/actionlint@v1
  # alternative: install via `go install` and run inline
```

Scope: `actionlint` discovers and lints all of:
- `.github/workflows/*.yml`
- `.github/actions/**/action.yml`

#### Backfill posture

Existing workflows have not been linted with actionlint before;
expect a small backlog of warnings on first run. Triage rule:
- Hard errors (typos, malformed expressions, missing keys) → fix
  in this PR.
- Style warnings (shellcheck SC2086, etc.) → either fix in this
  PR if trivial, or `actionlint -ignore '<pattern>'` with a
  TODO link to a follow-up issue.

The composite action MUST land lint-clean from day one
(non-negotiable for new code).

## Reviewer Context

- The script's existing test harness uses `INVOCATION_LOG` to
  short-circuit real `fly` / `modal` / `git clone` invocations. The
  composite action's tests should reuse it — don't introduce a second
  test mechanism.
- `Stacks.Audit.log/1` is the existing audit helper; encryption goes
  through `Stacks.Vault` (Cloak AES-256-GCM). Don't write a new
  insertion path.
- Composite actions can reference scripts via `${{ github.action_path
  }}/../../../scripts/<name>.sh`. The relative path looks awkward but
  is the documented GitHub pattern for composite actions consuming
  repo-root scripts.
- The `migration-safety` lint already runs on every PR via
  `scripts/lint-migrations.sh`; it enforces `@breaking_ok` on
  destructive ops. That existing gate makes "image rollback against a
  newer schema" safe in 99% of cases — this issue documents the
  contract; it doesn't add new lint rules.
- `record-prev-state` step in `deploy-production.yml:200-225` already
  resolves `CORE_PREV_IMAGE` and `MODAL_PREV_COMMIT` from the latest
  `main-*` tag. Reuse those values for both the auto and manual
  rollback paths.

## Definition of Done

### Composite action
- [ ] `.github/actions/rollback-production/action.yml` created with the
      input/output schema above.
- [ ] `.github/actions/rollback-production/README.md` covers what it
      does, all inputs, the bootstrap edge case, failure modes, manual
      invocation, runbook links.
- [ ] `deploy-production.yml` uses the composite action via `uses:
      ./.github/actions/rollback-production`.
- [ ] `manual_rollback` workflow_dispatch input added; gates a
      branch that skips deploy and goes straight to rollback.

### Migration ordering
- [ ] `Run prod migrations (before image cutover)` step lands in
      `deploy-production.yml` between `Compose DATABASE_URL` and
      `deploy-stack.sh`.
- [ ] `scripts/deploy-stack.sh:722` retained as a no-op safety net
      with an updated comment.
- [ ] Preview deploy path (`deploy-preview` job) unchanged — preview
      Neon branches still migrate in-container.

### DB rollback via Neon LSN
- [ ] `Capture pre-migrate Neon LSN (prod)` step lands in
      `deploy-production.yml` BEFORE the migrate step. Captures LSN
      via `SELECT pg_current_wal_lsn()` and resolves the prod
      branch ID via `/branches` filtered on `default: true`.
- [ ] `NEON_PROJECT_ID` + `NEON_API_KEY` added as GH
      repo secrets (operator confirmed available, before merge).
- [ ] Composite action accepts `neon-project-id`,
      `neon-api-key`, `neon-branch-id`, `pre-migrate-lsn`
      inputs; calls `POST /branches/{id}/restore` with
      `source_branch_id` (self), `source_lsn`, `preserve_under_name`
      between core and vision rollback.
- [ ] Composite action handles the bootstrap edge case (empty
      `pre-migrate-lsn` → log WARN, skip DB rollback).
- [ ] Data-loss contract documented in
      `docs/runbooks/manual-rollback.md` opening section.
- [ ] `pre-rollback-*` preserved branches show up in the Neon
      console after a rollback (verify in Phase 3); document
      cleanup as a follow-up issue (prune >30d old).

### Audit + telemetry
- [ ] `Stacks.Audit.log_rollback/1` helper added (~30 LOC).
- [ ] Composite action invokes the helper on rollback success.
- [ ] `[:stacks, :system, :rollback]` telemetry event verified at
      one of: prod gate scrape, Axiom dashboard, or unit test.

### Documentation
- [ ] `docs/runbooks/manual-rollback.md` (new): how an operator
      invokes a manual rollback, what to expect.
- [ ] `docs/runbooks/migration-recovery.md` (new): forward-fix vs.
      down-migrate decision tree for a partially-applied prod
      migration. Cross-references `migration-safety` lint.
- [ ] `scripts/rollback-production.sh` header updated to remove the
      "Issue #137 follow-up" stub now that it's complete.

### Tests
- [ ] Unit test for `Stacks.Audit.log_rollback/1` (insert + telemetry
      event).
- [ ] Existing `scripts/rollback-production.sh` test harness
      (`test/scripts/rollback_production_test.sh`) extended for the
      Neon-restore path (uses `INVOCATION_LOG` to mock the `curl` to
      Neon, asserts API call shape: endpoint, body, preserve name).
- [ ] Test harness covers ordering: core image rollback runs
      BEFORE Neon restore in the assertion log.
- [ ] Test harness covers migration-failure path: when
      CORE_PREV_IMAGE matches currently-serving image, core
      rollback is skipped and Neon restore still fires.
- [ ] `just verify` clean.

### Linting (new)
- [ ] `actionlint` step added to `ci.yml`'s lint job.
- [ ] Existing workflows + composite action all lint-clean (or
      hard errors fixed in this PR; style warnings ignored with
      a follow-up issue link).
- [ ] New composite action lands with zero actionlint warnings.

### Live validation against prod (Test plan above)
- [ ] Phase 1: rollback automation lands on PR204 (composite +
      LSN capture + Neon reset + audit helper).
- [ ] Phase 2 + 3: at least two consecutive PR204 pushes produce
      clean rollback observations end-to-end (all Phase 3
      checkboxes green for the last two pushes).
- [ ] Phase 3 observations recorded in this file's Progress Notes
      for each iteration.
- [ ] Phase 4: any edge cases surfaced during Phase 2 are patched
      and re-verified before merge.
- [ ] Phase 5: `pull_request:` clause removed from
      `deploy-production.yml`'s `if:` expression — final-state
      triggers are `workflow_dispatch` and `workflow_run` only.
      Verified by a PR204 push that produces no deploy-production
      run.
- [ ] Phase 6: Modal budget bumped post-merge; subsequent deploy
      passes the gate without rollback.
- [ ] Phase 7: deliberate manual rollback exercised on a no-op
      commit; audit row tagged `triggered_by: "manual"`.

## Test plan

The current Modal-workspace-budget breach gives us a guaranteed SLO
failure on every prod deploy until the budget is bumped. We use that
window — and PR204's existing temp `pull_request:` trigger on
`deploy-production.yml` — to exercise the rollback path
iteratively against real prod *before* locking the workflow down.

### Test posture during PR204

`deploy-production.yml:50-55` accepts three trigger events:

```yaml
if: ${{
  github.event_name == 'workflow_dispatch' ||
  github.event_name == 'pull_request' ||
  github.event.workflow_run.conclusion == 'success'
}}
```

The `pull_request` clause is documented as **TEMPORARY for iteration
… delete before merge**. We deliberately leave it in place during
PR204 so every push to this branch fires a real prod deploy →
guaranteed Modal-vision SLO breach → rollback. Each push is one more
chance to surface edge cases against real Fly + Neon + Axiom
behaviour rather than a dry-run.

**Operational implication**: while PR204 is open, prod is in a
deploy → rollback loop on every push. Real users may briefly see
the new image (≤10 min in the SLO gate window) before being rolled
back. Acceptable in this window — Modal was already broken pre-PR
so the user-visible state is no worse than baseline. Document this
to ops in the PR description so nobody is surprised.

### Phase 1: ship the rollback automation

Land all the workflow + composite-action + audit changes from the
sections above in this PR. Do NOT fix the Modal budget yet — that's
the test event.

### Phase 2: iterate on PR204 pushes

Each push to PR204 triggers `deploy-production` (via the
`pull_request:` clause). Expected sequence per push:

1. Pre-migrate LSN captured.
2. Migrations run on the runner against prod DATABASE_URL → expected
   clean (no schema changes shipping in this PR).
3. `deploy-stack.sh --production` runs core + Modal + scraper +
   log-shipper deploys.
4. Modal canaries hit Modal → 429 (workspace billing limit) →
   vision_fuse circuit opens.
5. SLO gate (10 min) sees `vision_fuse_open=1` → BREACH.
6. Rollback composite action fires (`if: failure()`):
   - Core: `fly deploy --image $CORE_PREV_IMAGE` → rolls back to
     last `main-*` tagged image.
   - DB: Neon API reset of prod branch to PRE_MIGRATE_LSN.
   - Vision: skipped on first run (no `MODAL_PREV_COMMIT`); attempted
     on subsequent runs once a tag exists.
   - Audit: `Stacks.Audit.log_rollback/1` writes the row.

### Phase 3: observations to capture per iteration

Record observations in this file's Progress Notes for each push.
The first push will surface the most edge cases; later pushes
verify the fixes for those edge cases. Looking for:

- [ ] `gate-observations.json` artifact uploaded; `vision_fuse_open=1` confirmed.
- [ ] `audit.audit_log` row written with `action: "system.rollback"`.
- [ ] `[:stacks, :system, :rollback]` telemetry visible in Axiom.
- [ ] Fly app's serving image SHA matches `CORE_PREV_IMAGE` (`fly status -a thestacks-core`).
- [ ] Neon prod branch's LSN reset succeeded (verify via Neon API or `neonctl branches list`).
- [ ] Composite action outputs reflect reality: `core-rolled-back=true`, `db-rolled-back=true`, `modal-rolled-back=false` (or `true` if MODAL_PREV_COMMIT exists).
- [ ] Bootstrap path: first push has no LSN captured for the *previous* deploy (only this deploy's LSN is captured pre-migrate). Verify the composite action handles "no DB rollback target" gracefully if hit.
- [ ] Vision-skip path: first push has no `main-*` tag for Modal commit, so vision rolls back is a `false` (skipped). Verify the audit row records this correctly.
- [ ] Vision-attempt path: second-or-later push has a `main-*` tag; vision rollback actually runs. Verify it succeeds.
- [ ] Health-check post-rollback: core's `/api/health` returns 200 within ~60s of rollback completing.
- [ ] No data-loss surprises: any rows written between LSN capture and rollback are gone (intentional — confirm against the documented contract, don't treat as a bug).

### Phase 4: edge cases discovered → revise → re-push

Each iteration of Phase 2/3 may surface a real bug or
infrastructure quirk (Neon API JSON shape doesn't match the
sketched payload, audit row missing a field, Fly image SHA format
differs from what we expected, etc.). Treat each as:

1. Diagnose from the workflow logs + the artifact.
2. Patch the composite action / capture-LSN step / audit helper.
3. Push the fix to PR204 → next deploy fires → next rollback observed.

Repeat until all observation checkboxes in Phase 3 are reliably
green for at least two consecutive pushes.

### Phase 5: lock down deploy-production triggers

Once PR204's rollback path is solid (criteria: two consecutive
clean rollback observations end-to-end), tighten the workflow
**before merging**:

- Remove the `github.event_name == 'pull_request'` clause from
  `deploy-production.yml:50-55`'s `if:` expression. Final state:
  ```yaml
  if: ${{
    github.event_name == 'workflow_dispatch' ||
    github.event.workflow_run.conclusion == 'success'
  }}
  ```
- Verify in PR204's last push (after the trigger removal) that
  `deploy-production` is **skipped** on PR pushes — only CI runs.
- Merge PR204 to main: post-merge `tag-main.yml` stamps a new
  `main-<sha>` tag, then `workflow_run` triggers
  `deploy-production` for the merge commit. (This merge is the
  production deploy.)

### Phase 6: cost-trace correction (post-merge)

After PR204 merges and the post-merge deploy fires:

- Bump Modal workspace spend cap (operator action, outside agent
  scope).
- The next deploy after the bump should clear; Modal calls return
  200 → vision_fuse closes via the existing probe → SLO gate
  passes → no rollback fires.

If the post-merge deploy ALSO triggers a rollback (Modal still
broken at merge time), that's an expected outcome — the rollback
automation is now battle-tested, audit row is written, and the
production stack reverts cleanly to the previous main tag.

### Phase 7: deliberate manual-rollback test (follow-up, post-budget-fix)

Once Modal is healthy and a normal deploy clears the gate, validate
the manual-rollback path explicitly:

- Push a no-op commit to main.
- Wait for normal deploy success (gate passes, no auto-rollback).
- Re-run the deploy-production workflow with
  `manual_rollback: true`.
- Expect: same composite action fires, audit row written with
  `triggered_by: "manual"`.

This closes the gap that Phases 2-6 don't explicitly exercise (the
manual-rollback on-ramp; the SLO-gate path is covered by every
auto-rollback observed in Phase 2).

## Out of scope

- **Per-region / per-machine rollback.** Fly's `fly deploy --image`
  rolls all machines in the app. Targeted rollback (one region only,
  canary-style) is out of scope.
- **Non-prod rollback** (preview environments). Preview branches are
  ephemeral; if a preview deploy fails, `cleanup-preview.sh`
  destroys the stack. No rollback path needed.
- **Migration `def down` semantics.** We rely on Neon LSN reset
  rather than `mix ecto.rollback`. The `def down` blocks in
  generated migrations stay there for local dev (`mix ecto.rollback`
  on a dev DB) but are NOT trusted in prod rollback.

## Dependencies

- Issue #136 — `scripts/rollback-production.sh` is in place and the
  test harness works. ✅ done.
- `record-prev-state` step + `tag-main.yml` workflow that stamps
  `main-<sha>` tags. ✅ done.
- `migration-safety` lint. ✅ done; the existing lint enforces
  `@breaking_ok` on destructive ops which is what makes the rollback
  contract safe.

## Agent Assignment
platform-agent (composite action + workflow + runbook docs).
elixir-agent (`Stacks.Audit.log_rollback/1` + telemetry).

## Progress Notes

- 2026-04-18: Created as follow-up from Issue #136 Phase 3
  platform-reviewer finding (composite action, declarative secrets).
- 2026-04-19: Added migrate-before-image-cutover secondary scope
  from PE gate finding — both touch deploy-production.yml so
  bundling is cleaner than splitting.
- 2026-04-29: Substantially expanded scope after a detailed audit of
  current state (`scripts/rollback-production.sh`,
  `deploy-production.yml`, `deploy-stack.sh`). Added: action.yml
  full shape, manual-trigger workflow_dispatch input, audit-log
  + telemetry on rollback, backwards-compat for in-container
  migrate, runbook deliverables.
- 2026-04-29 (later): expanded again to include automated DB rollback
  via Neon LSN reset (was previously out-of-scope). Schema reverts
  along with the image; data-loss window bounded by SLO gate (~15
  min worst case) and explicitly documented. Required new GH secrets:
  NEON_PROJECT_ID + NEON_API_KEY.
- 2026-04-29 (later again): test plan refined to use PR204's existing
  `pull_request:` trigger on deploy-production.yml as the validation
  vehicle. Each push to PR204 fires a real prod deploy → SLO breach
  via Modal-budget → rollback. Iterate edge cases on this branch,
  then lock down the trigger (remove the `pull_request:` clause)
  before merging. Phases 5 + 6 capture the lock-down + post-merge
  steps explicitly so the temp PR-trigger doesn't leak into the
  long-term workflow shape.
- 2026-04-29 (open questions resolved): operator answered remaining
  triage items.
  - Audit helper invocation: inside the composite action.
  - Rollback ordering: **core image first, then DB, then vision**.
    Forced by expand-contract — image N-1 ↔ schema N is safe by
    construction (lint enforces it); image N ↔ schema N-1 is unsafe.
    Documented as an explicit invariant in section 4.
  - Migration-failure path: LSN reset fires even when no image was
    deployed (audit `triggered_by: "migration-failure"`). This is
    the case where Postgres-level rollback earns its keep —
    `def down` can't reliably unwind a partial `ALTER TABLE`.
  - Bootstrap (DB): non-event — capture step runs every deploy
    including the first, so first auto-rollback has a valid DB
    target. Only Modal lacks a target on a brand-new prod stack.
  - Bootstrap (Modal): documented one-time pre-tag procedure
    (`git tag main-bootstrap $(git rev-parse main^)`) for future
    fresh prod environments. Filed as a follow-up runbook.
  - Modal-prev-commit on first auto-rollback: explained — `modal
    deploy` is idempotent w.r.t. revisioning, doesn't care which
    workflow originally deployed a SHA. Same SHA re-deployed
    yields the same Modal app state. No special handling needed.
  - Lint scope: `actionlint` for the composite action AND backfill
    across all existing workflows. Added section 7.
- 2026-04-29 (Neon API verified): investigated open questions against
  Neon's OpenAPI spec (`https://neon.com/api_spec/release/v2.json`)
  and docs (`https://neon.com/docs/guides/branch-restore`).
  Findings:
  - **No `current_lsn` field on Branch object.** The spec only exposes
    `parent_lsn` (fork-point, fixed at branch creation). Capture must
    come from Postgres itself via `SELECT pg_current_wal_lsn()`.
  - **Restore endpoint** is `POST /projects/{pid}/branches/{bid}/restore`
    (not `/reset`) with body `{source_branch_id, source_lsn,
    preserve_under_name}`.
  - **Self-restore requires `preserve_under_name`** — Neon snapshots
    pre-rollback state under that name. Treating this as a free
    safety net rather than working around it.
  - **Primary-branch self-restore is supported** (root branch can
    use itself as `source_branch_id` when `preserve_under_name` is
    set).
  - Resolving the prod branch ID via `default: true` (the deprecated
    `primary` field) future-proofs against the branch being renamed.
  Updated sections "Capture the LSN" and "Reset on rollback" with
  verified shapes; added `neon-branch-id` input to the composite
  action; added `pre-rollback-*` cleanup as a follow-up.
- 2026-04-29 → 2026-05-02: Phases 1-6 implemented + reviewed +
  committed. Commits: 7fd3c7c (Phase 1, audit helper) → 0304db2
  (Phase 2, Neon LSN restore + script extension) → c79b192 (Phase 3,
  composite action + parser) → 9ca438b (Phase 4, deploy-production.yml
  wiring) → 9653376 (Phase 5, actionlint adoption) → 3d1b607 (Phase 6,
  runbooks). Phase 6 follow-up issues #162/#163/#164 written but left
  untracked per operator. README.md for the composite action committed
  in Phase 4 (after being deferred in Phase 3). Phase 6 had one
  revision cycle to fix 4 reviewer findings (P0 audit-SQL column +
  Cloak-encryption caveat; P0 migration-recovery Modal-leg shape; P1
  bootstrap cross-ref to non-existent file; P2 db-rolled-back=error
  overclaim). Phase 4 had a regex word-boundary fix on the contract
  test pre-commit (replaced a YAML line-continuation workaround with
  `\brollback\b` matching). Phase 3 had a parser-extraction revision
  (extracted `emit-outputs` grep classification into
  `scripts/parse-rollback-output.sh` + 15-case fixture test with a
  live-marker-check sentinel that catches script/parser drift).
- 2026-05-02 (Phase 7 iteration 1 — semgrep): branch pushed; pre-push
  hook surfaced `yaml.github-actions.security.run-shell-injection` on
  the composite action's `validate-inputs` step (inputs interpolated
  inline via `${{ inputs.* }}` in `run:`). Defense-in-depth refactor:
  moved 8 input values into an `env:` block (CORE_PREV_IMAGE,
  MODAL_PREV_COMMIT, MODAL_TOKEN_ID/SECRET, PRE_MIGRATE_LSN,
  NEON_PROJECT_ID/API_KEY/BRANCH_ID) and reference via `$VAR` in
  the bash. Same pattern as `run-rollback` and `log-audit`. Local
  semgrep clean across `.github/`; bash test suites unchanged
  (250/0); actionlint clean.
- 2026-05-03 (Phase 7 iteration 2 — ZAP): pre-push hook's
  `security-live` stage failed with `Failed to access summary file
  /home/zap/zap_out.json` + `FAIL deploy: ZAP baseline found new
  failures`. Reproduced locally: `ghcr.io/zaproxy/zaproxy:stable`
  has drifted to a state where the Automation Framework writes its
  summary to a path `zap-baseline.py` doesn't expect; `--autooff`
  mode times out downloading 15 add-ons before the scan starts.
  Pre-existing infra issue, not caused by #137. Pinned
  `scripts/ci.sh:291` to `ghcr.io/zaproxy/zaproxy:2.16.1` (last
  known-good for `zap-baseline.py`). Local repro produces
  `FAIL-NEW: 0, WARN-NEW: 11, PASS: 56` — the script's `grep -q
  "FAIL-NEW: 0"` now passes. Bumping the pin is a one-line edit but
  should be paired with a fresh local re-run; comment block at the
  pin documents this for future maintainers.
- 2026-05-04 (Phase 7 iteration 3 — fly image parsing + clone auth +
  fork-safe origin): three small but load-bearing fixes surfaced
  while iterating against real prod.
  - `fly image show --json` returns a list of per-machine objects
    with no top-level `Ref` field on current flyctl, so the inline
    bash heredoc in `record-prev-state` couldn't resolve
    `CORE_PREV_IMAGE`. Extracted a tolerant parser to
    `scripts/parse-fly-image.py` (tries `Ref`/`reference`/etc;
    falls back to synthesising `registry/repo@digest` from
    components). Header documents the per-machine list shape.
  - The Modal rollback leg's git clone failed against a tmpdir
    because `actions/checkout@v4` only sets up token auth in the
    workspace `.git/config`. The composite action now sets
    `git config --global url.<token-auth>.insteadOf` before
    invoking the script when `github-token` is provided. Added
    `github-token` input to the action's contract.
  - The script's default `ORIGIN_REMOTE` had the wrong owner
    (`erinversfeld/thestacks` vs. actual `erinversfeldcodes/thestacks`).
    Fixed by passing `${{ github.server_url }}/${{ github.repository }}.git`
    from the calling workflow — fork-safe (no hard-coded owner).
- 2026-05-04 (Phase 7 iteration 4 — verify-rollback step): operator
  flagged that after a rollback completes we should re-run the SLO
  gate against the rolled-back system; if those checks fail, alert
  for manual intervention rather than cascade-rolling-back further.
  Refactored the SLO gate into `.github/actions/check-slo-gate`
  (composite action wrapping `scripts/check-slo-gate.sh`) so the
  same script with the same SLI definitions can be invoked at both
  deploy-time AND post-rollback. Added `verify-rollback` step that
  waits 60s for machines to settle then re-runs the gate; on
  failure emits a `MANUAL INTERVENTION REQUIRED` annotation and
  exits 1 (no further rollback attempted). Single workflow run =
  single rollback attempt + single verify, no infinite-loop risk.
  Artifact upload now collects both `gate-observations.json` and
  `gate-observations-post-rollback.json`.
- 2026-05-04 (Phase 7 iteration 5 — successful end-to-end run):
  most-recent push exercised all three rollback legs cleanly:
  core image (PASS), Neon LSN restore (PASS — created
  `pre-rollback-4ddb647-20260504T060132Z` preserve branch), Modal
  vision (PASS — `vision rolled back to 052a1e64...`). Audit row
  written via `Stacks.Audit.log_rollback/1`. One cosmetic finding:
  the audit step's `mix run` boots `CoreWeb.Endpoint`, which logs
  an `[error] Could not warm up static assets: cache_manifest.json`
  because the runner has no digested static assets — surfaces as
  a red error annotation on the otherwise-successful run.
- 2026-05-04 (Phase 7 lock-down): reverted the four Phase 7 TEMP
  loosenings to production-grade gating in lockstep:
  - **Rollback step `if:`** restored to
    `(failure() || inputs.manual_rollback) && env.CORE_PREV_IMAGE != ''`
    (was `always() && env.CORE_PREV_IMAGE != ''`).
  - **Bootstrap notice `if:`** restored similarly.
  - **SLO gate `if:`** restored to `!inputs.manual_rollback`
    (was `${{ false }}`).
  - **Workflow trigger** locked to `push: branches: [main]` +
    `workflow_dispatch:` (removed `workflow_run` and the Phase 7
    `pull_request:` iteration trigger). Job-level `if:` removed
    as redundant.
  - Contract test (`deploy_production_workflow_test.sh`) flipped
    in lockstep: `workflow_run_trigger` test renamed to
    `push_main_trigger` (now forbids workflow_run/pull_request);
    `workflow_dispatch_feature` requires `push:` instead of
    `workflow_run:`; rollback `failure()`/`manual_rollback`
    assertions and gate `manual_rollback` assertion all
    re-enabled. Final test count: 75/75 passing, actionlint clean.
- 2026-05-04 (tag-main sequencing): switched `tag-main.yml` from
  `push: branches: [main]` to `workflow_run` on Deploy production
  with `conclusion == 'success'`. Changes the semantics of
  `main-<sha>` tags from "merged to main" to "verified-deployed".
  Failed deploys never get a tag, so the rollback target is always
  the last KNOWN-GOOD prod, not just the last attempt. Updated
  `record-prev-state` to take `head -1` (the current HEAD has no
  tag yet — tag-main only stamps after deploy-production succeeds —
  so no race). Contract test `tag_main_workflow` updated to assert
  the new trigger shape.
- 2026-05-04 (endpoint child opt-out): added `STACKS_SKIP_ENDPOINT`
  env-gate around `CoreWeb.Endpoint` in `Core.Application`. Default
  behaviour unchanged (endpoint always supervised); the rollback
  action's audit step now sets `STACKS_SKIP_ENDPOINT=1` so the
  `mix run -e` invocation doesn't boot the endpoint and trigger
  the cosmetic `cache_manifest.json` error annotation.
