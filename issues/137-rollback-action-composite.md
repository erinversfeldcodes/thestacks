# Issue #137: GitHub composite action for production rollback

## Summary
Wrap `scripts/rollback-production.sh` in a GitHub composite action so the Modal authentication env vars (`MODAL_TOKEN_ID`, `MODAL_TOKEN_SECRET`) are consumed explicitly as action inputs rather than implicitly inherited from the caller's `env:` block. Improves reusability and makes secret dependencies declarative.

## User Stories
N/A (platform).

## Goal
A reusable action `stacks/rollback-production@v1` (local composite) that:
- Declares explicit inputs for every secret and parameter it needs.
- Shells out to `scripts/rollback-production.sh` with those inputs mapped to env vars.
- Can be invoked from `.github/workflows/deploy-production.yml` (and any future workflow) without relying on implicit secret inheritance.

## Scope Check
Single composite action + wiring. Small.

## Wiring
- [x] Includes wiring — updates `deploy-production.yml` to use the new action.

## Technical Requirements

### Action directory structure
```
.github/actions/rollback-production/
├── action.yml
└── README.md
```

### `action.yml` inputs
- `core-app` (required) — Fly app name for core.
- `core-prev-image` (required) — Previous image SHA to roll back to.
- `modal-app` (optional) — Modal app name. Default: `thestacks-vision`.
- `modal-prev-commit` (optional) — Previous Modal commit to re-deploy. Empty = skip Modal rollback.
- `modal-token-id` (required) — Modal auth token ID.
- `modal-token-secret` (required) — Modal auth token secret.
- `fly-api-token` (required) — Fly API token.
- `rollback-reason` (required) — Human-readable reason.

### Action steps
1. Map inputs to env vars on the shell step.
2. Invoke `scripts/rollback-production.sh` from the caller repo.
3. Pass through exit code so caller workflows can continue to gate on it.

### Update `deploy-production.yml`
Replace the current inline rollback step with a `uses: ./.github/actions/rollback-production` step, passing secrets explicitly.

## Reviewer Context
- Issue #136 established the rollback script. The current workflow's env block inherits `MODAL_TOKEN_ID` + `MODAL_TOKEN_SECRET`; the script does not document this dependency in its header (flagged by Phase 3 platform-reviewer finding P1 #2).
- Composite actions can be called as `uses: ./.github/actions/rollback-production`; no separate repository needed.

## Definition of Done
- [ ] Action directory created with `action.yml` and README.
- [ ] Action invokes `scripts/rollback-production.sh` with all required env vars mapped from explicit inputs.
- [ ] `deploy-production.yml` uses the new action.
- [ ] Added to CI lint scope if composite actions are included.
- [ ] Test: fire the workflow on a safe target (preview app) and confirm the action runs the rollback script correctly.

## Secondary scope — migrate-before-image-cutover

**Problem** (PE gate finding, 2026-04-19): `scripts/deploy-stack.sh` runs
`fly deploy` (core image cutover, machines start serving traffic) *before*
invoking `Stacks.Release.migrate()` inside the new container. If a migration
partially applies and then raises, the failure path rolls back the image
but leaves the schema half-applied. The expand-contract discipline usually
makes this recoverable, but any multi-statement migration that executes
statement N successfully before N+1 fails will leave the DB on a schema the
rolled-back image was never written against.

### Proposed fix
Run migrations from the GitHub Actions runner against the Neon prod
DATABASE_URL *before* the core image cutover:

1. New step in `deploy-production.yml` between "Decompose DATABASE_URL" and
   "Deploy core": run `mix ecto.migrate` using the release binary *or* the
   source checkout with production Mix env. Fail the workflow before any
   image cutover happens.
2. Remove the in-container migrate invocation from `deploy-stack.sh`'s
   post-deploy block (or keep as a no-op safety net — it'll find no pending
   migrations on a healthy path).
3. Keep `seed_prod` in-container (needs the running release env for Argon2
   + encryption vault setup).

### DoD additions
- [ ] `deploy-production.yml` migrates against prod DATABASE_URL before
  image cutover.
- [ ] `deploy-stack.sh` no longer runs migrations as part of the core
  deploy success path.
- [ ] Test: a migration that raises mid-way aborts the workflow before
  the new image is deployed (simulate with a throwaway migration against
  a preview branch).

## Dependencies
- Issue #136 — rollback-production.sh must exist and be stable.

## Agent Assignment
platform-agent.

## Progress Notes
- 2026-04-18: Created as follow-up from Issue #136 Phase 3 platform-reviewer finding.
- 2026-04-19: Added migrate-before-image-cutover secondary scope from PE gate finding — the rollback-action work and the migration-ordering fix both live in the deploy-production.yml surface and are cleaner bundled than split.
