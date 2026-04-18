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

## Dependencies
- Issue #136 — rollback-production.sh must exist and be stable.

## Agent Assignment
platform-agent.

## Progress Notes
Created 2026-04-18 as follow-up from Issue #136 Phase 3 platform-reviewer finding.
