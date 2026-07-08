# Issue #142: Bootstrap `staging` Neon project so previews inherit fixtures with zero data lineage to production

## Summary
Bootstrap a dedicated `thestacks-staging` Neon project (separate from the production project for absolute data isolation) containing migrations + the full dev fixture set. Rewire preview deploys to branch from `staging` in that project, rename the preview-pointing secrets to `NEON_STAGING_*`, re-enable the `deploy-preview` CI job, and remove the per-preview seed step.

## User Stories
N/A — infrastructure + developer-experience change.

## Goal
Success looks like:

1. A separate `thestacks-staging` Neon project exists with a `staging` branch containing migrations applied from scratch + the full dev fixture set (owner user, authors, books, bookshelves, placements, etc.). Zero data lineage to production — no copy-on-write parent relationship, no way to reset staging to production's state.
2. `deploy-stack.sh` in preview mode reads `NEON_STAGING_PROJECT_ID` + `NEON_STAGING_API_KEY` (replacing the prod-pointing `NEON_PROJECT_ID` + `NEON_API_KEY`) and defaults `NEON_PARENT_BRANCH=staging`. Preview branches are copy-on-write children of `staging` within the staging project.
3. Preview deploys skip the per-preview `Stacks.Release.seed/0` call. Fixtures arrive via Neon copy-on-write from staging.
4. The commented-out `deploy-preview` job in `.github/workflows/ci.yml` (currently lines 563–756) is uncommented and wired to use the new `NEON_STAGING_*` secrets.
5. Stale `preview/*` branches in the old (prod) Neon project are deleted so they stop accruing compute.
6. `docs/deployment/NEON_BRANCH_TOPOLOGY.md` is rewritten to describe the two-project architecture and the duplicate Lifecycle/Configuration/Cleanup sections (pre-existing doc bug, lines 37+91, 45+99, 81+109) are deduplicated.
7. Production is never touched during this work. `deploy-production.yml` composes `DATABASE_URL` from `STACKS_PROD_DB_*` components directly and does not consult Neon branching — no change needed there.

## Scope Check
- Controllers touched: **0**
- New endpoints: **0**
- LOC: ~300 (script renames, doc rewrite, ~200 line CI job uncomment + wiring)
- Combined concerns: infra + docs + CI. Single theme (preview/staging isolation) — safe as one issue.

## Wiring
- [ ] This issue includes router wiring and is user-facing when complete.
- [x] This issue is implementation only. Infrastructure / deploy + CI change.

## Technical Requirements

### Phase 1 — Bootstrap staging project (orchestrator direct execution)

**Prerequisites (already completed by operator):**
- New Neon project `thestacks-staging` created (distinct from the prod project)
- Branch `staging` exists in the new project
- `NEON_STAGING_PROJECT_ID` + `NEON_STAGING_API_KEY` added to local `.env`

**Steps:**
1. Fetch the staging connection URI via `neonctl connection-string --branch staging --project-id $NEON_STAGING_PROJECT_ID` (using `NEON_STAGING_API_KEY` for auth).
2. `DATABASE_URL=<staging-uri> mix ecto.migrate` — apply all migrations from scratch against the empty staging branch. Iterates both `Core.Repo` and `Core.ObanRepo` per `config/config.exs:27`; both point at the same DATABASE_URL so the second pass sees migrations already applied.
3. `DATABASE_URL=<staging-uri> ALLOW_SEEDS=true mix run apps/core/priv/repo/seeds.exs` — load the full dev fixture set. `seeds.exs` is idempotent (`on_conflict` on every insert) so re-runs are safe.
4. Verify staging contains non-zero rows for `op.users`, `op.books`, `op.bookshelves` via `psql`.

### Phase 1b — Clean up stale prod-project preview branches

Using the OLD `NEON_PROJECT_ID` + `NEON_API_KEY` (still pointing at the prod project):
- `neonctl branches list --project-id $NEON_PROJECT_ID` → filter branches whose name starts with `preview/`
- Delete each one via `neonctl branches delete`
- Confirm zero `preview/*` branches remain in the prod project

### Phase 2 — Code + docs + CI rewire + generator fix (delegate to platform-agent)

Files to modify:

#### Rename `NEON_*` → `NEON_STAGING_*` in the preview code path

- **`scripts/deploy-stack.sh`** (~16 touchpoints):
  - Preflight checks: `NEON_PROJECT_ID` → `NEON_STAGING_PROJECT_ID` (line 13)
  - Preflight checks: `NEON_API_KEY` → `NEON_STAGING_API_KEY` (line 16)
  - Preview-mode Neon API calls: rename all `NEON_API_KEY` / `NEON_PROJECT_ID` references in the branch-creation block (lines ~139–141, 179, 193, 205–206, 221–222, 232–233, 237, 240, 258, 478) to their `NEON_STAGING_*` counterparts
  - Default `NEON_PARENT_BRANCH` → `staging` (line ~202)
  - Remove the preview-side seed block entirely (~lines 677–684 depending on current state). Prod `seed_prod` path stays.
  - Update header comments that describe env var usage (lines ~21–24, 197–201)

- **`scripts/cleanup-preview.sh`**: rename `NEON_API_KEY` / `NEON_PROJECT_ID` references (lines 11–12, 86, 91–92, 101–102, 109) to `NEON_STAGING_*` equivalents.

- **`.github/workflows/ci.yml`**: uncomment the `deploy-preview` job (lines 563–756) and rename the env block's `NEON_PROJECT_ID` / `NEON_API_KEY` to `NEON_STAGING_*`. Keep the `needs: [versions]` minimal-deps line (the TODO to restore full deps is tracked separately).

- **`.github/workflows/deploy-production.yml`**: no change required. Prod composes `DATABASE_URL` from `STACKS_PROD_DB_*` and clears `NEON_API_KEY` internally via the `--production` flag.

- **`docs/deployment/NEON_BRANCH_TOPOLOGY.md`**: full rewrite. Describe the two-project architecture. Remove the "pre-launch window" section, remove the "belt-and-braces self-seeding" note. Deduplicate the two sets of Lifecycle/Configuration/Cleanup sections (lines 37+91, 45+99, 81+109).

- **`.env.example`**: update the `NEON_*` block to reference `NEON_STAGING_*` where appropriate and document the two-project split.

- **`issues/142-bootstrap-staging-neon-branch.md`** (this file): already updated to reflect the two-project architecture.

#### Restore `@disable_migration_lock true` to CONCURRENTLY migrations (regression fix)

Discovered during Phase 1 of this issue: when `20260422072906_create_title_search_cache` ran against the new staging Neon DB, Ecto emitted:

> `Migration … has set index … to concurrently but did not disable migration lock. Please set: use Ecto.Migration @disable_migration_lock true`

The migration took 300s (vs <2s for non-CONCURRENTLY migrations) and concluded with an `ssl send: closed` TCP timeout. Root cause: an earlier simplification in this codebase removed `@disable_migration_lock true` from the proto.sync migration generator and the two existing cache migrations, based on a wrong analysis that Ecto holds the migration lock on a separate connection that doesn't interfere with CONCURRENTLY. Ecto's own warning proves otherwise.

Files to modify:

- **`apps/core/lib/mix/tasks/proto_sync/migration_generator.ex`**: restore `@disable_migration_lock true` alongside the existing `@disable_ddl_transaction true` in the generated migration template. Update the inline rationale comment to reflect the correct reasoning (Ecto's CONCURRENTLY check is advisory, but the lock it acquires in the non-disabled path holds long enough that the ALTER step on a fresh index can exceed TCP keepalive, producing the observed 300s hang + ssl-send-closed on Neon specifically).
- **`apps/core/priv/repo/migrations/20260422072905_create_isbn_resolver_cache.exs`**: add `@disable_migration_lock true`. Inert for any env where the migration has already been applied; prevents future fresh envs from hitting the hang.
- **`apps/core/priv/repo/migrations/20260422072906_create_title_search_cache.exs`**: same fix.
- **`apps/core/test/mix/tasks/proto_sync_test.exs`**: flip the negative assertion (`refute output =~ "@disable_migration_lock"`) to positive (`assert output =~ "@disable_migration_lock true"`).

### Phase 3 — Verification

Trigger a dummy preview deploy (either via CI on a throwaway branch or locally via `scripts/deploy-preview.sh`). Verify all of:
- A new preview Neon branch is created in the **staging project** (not the prod project). `neonctl branches list --project-id $NEON_STAGING_PROJECT_ID` shows the new branch.
- Migrations are present on the preview (inherited from staging via copy-on-write).
- No preview-side seed step is logged in the deploy output.
- After logging in as the seeded dev owner (`owner@thestacks.app` / `dev-password-123`), `GET /api/bookshelves/library` returns non-empty placements (proves fixtures are present via inheritance).
- Preview deploy time is measurably faster than pre-#142 runs (saves the ~5–10s seed step).

### Operator-step gate before Phase 2's CI work can run

GH Actions needs the two new repository secrets added via the GitHub UI:
- `NEON_STAGING_PROJECT_ID` — the Neon project ID for the staging project
- `NEON_STAGING_API_KEY` — API key scoped to the staging project (or account-level key)

The existing `NEON_PROJECT_ID` / `NEON_API_KEY` GH secrets become orphaned after this issue lands (no code path references them). Delete at leisure.

## Reviewer Context

- **Neon two-project model**: staging has zero lineage to production. A Neon admin running `branches reset` on staging cannot restore production data because they're in different projects. This was the motivating design decision.
- **Prod deploy path is untouched**: `deploy-production.yml` composes `DATABASE_URL` from `STACKS_PROD_DB_ROLE`/`PASSWORD`/`HOST`/`NAME` secrets and does NOT use Neon branching. The `--production` flag in `deploy-stack.sh` clears `NEON_API_KEY` internally, so prod is safe regardless of what value `NEON_API_KEY` holds.
- **`Core.ObanRepo` caveat**: both `ecto_repos` point at the same DB via `DATABASE_URL`. Migrations iterate both repos but find `public.schema_migrations` already populated by the first repo, so no duplicate errors. If this ever changes (ObanRepo on separate DB), the bootstrap command breaks silently.
- **`seeds.exs` idempotency**: every `insert_all` uses `on_conflict: :nothing` or `on_conflict: {:replace, ...}` with `conflict_target: :id` (users). Safe to re-run.
- **CI `deploy-preview` job was commented out**: the existing YAML block (lines 563–756) contains working logic. Uncommenting restores it — we're not designing a new job, just re-enabling what was there with the new secret names.

## Definition of Done

- [ ] Phase 1 complete: staging project contains applied migrations + seeded dev fixtures. Row counts verified for `op.users`, `op.books`, `op.bookshelves`.
- [ ] Phase 1b complete: zero `preview/*` branches remain in the old prod Neon project.
- [ ] Phase 2 complete:
  - [ ] `scripts/deploy-stack.sh` uses `NEON_STAGING_*` in preview mode + defaults `NEON_PARENT_BRANCH=staging` + no preview-side seed call
  - [ ] `scripts/cleanup-preview.sh` uses `NEON_STAGING_*`
  - [ ] `.github/workflows/ci.yml` `deploy-preview` job is uncommented and wired to `NEON_STAGING_*`
  - [ ] `.env.example` updated
  - [ ] `docs/deployment/NEON_BRANCH_TOPOLOGY.md` rewritten for two-project architecture; duplicate Lifecycle/Configuration/Cleanup sections deduplicated
  - [ ] `@disable_migration_lock true` restored in the proto.sync migration generator template
  - [ ] `@disable_migration_lock true` added to `20260422072905_create_isbn_resolver_cache.exs` and `20260422072906_create_title_search_cache.exs`
  - [ ] `apps/core/test/mix/tasks/proto_sync_test.exs` assertion flipped from `refute` → `assert` for `@disable_migration_lock true`
- [ ] Phase 3 complete: a real preview deploy succeeds and verifies all the criteria above (staging project parent, no seed step, fixtures inherited, `/api/bookshelves/library` non-empty).
- [ ] `just verify` passes on the Phase 2 branch.
- [ ] `bash -n scripts/deploy-stack.sh` and `bash -n scripts/cleanup-preview.sh` clean.

## Dependencies

None. Prod is untouched by this work (staging is a separate project; prod path doesn't use Neon branching). The dependency on "`deploy-production.yml` first-run completion" in the original draft of this issue was a product of the old single-project truncate-first approach; it no longer applies.

## Agent Assignment

- Phase 1 + 1b + 3: orchestrator (direct execution — shell commands against Neon + dev DB)
- Phase 2: platform-agent (deploy script + CI workflow + docs)

## Progress Notes

_(Updated during execution.)_
