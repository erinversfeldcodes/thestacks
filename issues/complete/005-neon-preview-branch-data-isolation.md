# Issue #005: Neon preview branch data isolation (pre-launch gate)

## Summary
Neon preview branches are copy-on-write clones of their parent. Today that parent is `main` — the production branch. As soon as real user data exists in production, every ephemeral preview environment deployed via `scripts/deploy-preview.sh` will inherit that data. This is a **data exposure risk** that must be resolved before any real users register.

## User Stories
Not directly tied to a user story — this is a security/infrastructure gate for launch.

## Goal
Preview deployments should never be able to read or mutate real user data. The Neon branch topology must enforce this before go-live.

## Background

Discovered during Phase 1E E2E testing (2026-03-11). When `deploy-preview.sh` creates a Neon branch, it clones from the project's default parent branch. Currently that is `main`, which already holds the fixture seed data. The branch inherits all rows — confirmed by:

```
15:09:39.626 [info] Migrations already up
Seeds loaded successfully.   # skipped because on_conflict: :nothing
```

`priv/repo/seeds.exs` was made idempotent (`on_conflict: :nothing`) as an immediate tactical fix so seeds don't crash. But idempotent seeds don't address the fundamental problem: if production has 10,000 real users in `main`, every new preview branch exposes them all.

## Technical Requirements

### 1. Introduce a `staging` Neon branch
- Create a dedicated `staging` branch in the Neon project that **only** ever contains fixture data (the current seed fixtures)
- This branch is the parent for all preview branches — not `main`
- `main` is the true production branch; it receives only production migrations (no seeds)

### 2. Update `deploy-preview.sh` to branch from `staging`
- Add `NEON_PARENT_BRANCH` env var (default: `staging`) used in the branch-creation API call:
  ```bash
  -d "{\"branch\": {\"name\": \"preview/${SANITISED}\", \"parent_id\": \"${NEON_PARENT_BRANCH_ID}\"}, ...}"
  ```
- Document `NEON_PARENT_BRANCH` in the script header and `.env.example`

### 3. Lookup `staging` branch ID at deploy time
- The branch creation API requires a branch ID, not a name. Add a lookup step before creating preview branches:
  ```bash
  NEON_PARENT_BRANCH_ID=$(curl ... GET /branches | python3 -c "... find by name == 'staging'")
  ```
- If the `staging` branch doesn't exist, fail fast with a clear error message.

### 4. Production seeds policy
- `priv/repo/seeds.exs` MUST NOT be called in production deployments (`Stacks.Release.seed/0`)
- Seeds are only for dev and preview environments
- The `staging` branch is manually seeded once (or via a one-time script) when it is created
- All future preview branches inherit clean fixture data from `staging`

### 5. Document the branch topology
- Add `docs/deployment/NEON_BRANCH_TOPOLOGY.md` documenting the three-tier setup:
  ```
  main          ← production; migrations only; no seeds
  └── staging   ← fixture data only; parent for all preview branches
       └── preview/<branch>  ← ephemeral; created and destroyed per PR
  ```

## Definition of Done
- [ ] `staging` Neon branch created in the project
- [ ] `deploy-preview.sh` reads `NEON_PARENT_BRANCH` (default: `staging`) and branches from it, not from `main`
- [ ] Lookup for `NEON_PARENT_BRANCH_ID` by name implemented in `deploy-preview.sh`
- [ ] `Stacks.Release.seed/0` is not called in the main production deploy path (only in preview via SSH console)
- [ ] `.env.example` documents `NEON_PARENT_BRANCH`
- [ ] `docs/deployment/NEON_BRANCH_TOPOLOGY.md` created
- [ ] Preview branch contains only fixture data (owner@thestacks.app + fixtures) — not any additional rows

## Dependencies
- Requires Neon API access (`NEON_API_KEY`, `NEON_PROJECT_ID`)
- Must be completed before the first real user registers (pre-launch gate)

## Agent Assignment
**platform-agent** — infrastructure and deployment concern. No Elixir code changes required beyond removing the `seed()` call from the production release module (or gating it behind an env check).

## Priority
**High** — pre-launch gate. Safe to defer until immediately before real-user onboarding, but must not be forgotten.
