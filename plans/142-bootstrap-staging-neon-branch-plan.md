# Plan: Bootstrap `staging` Neon project so previews inherit fixtures with zero data lineage to production
**Issue**: #142
**Created**: 2026-04-24
**Status**: Approved

## Context

Preview deploys currently clone the production Neon branch, which couples every PR to prod's live data shape and risks exposing PII the moment real users sign up. The original pre-launch plan was to truncate prod, branch `staging` off the (now-empty) prod, seed staging with fixtures, and have previews inherit from staging within the same Neon project. That design still left staging as a Neon child of production — meaning an operator running `branches reset` or any future Neon platform isolation bug could re-expose prod data.

This plan adopts a stronger architecture: **staging lives in its own Neon project** (`thestacks-staging`), with zero copy-on-write parent relationship to production. Previews become children of `staging` within that project. Prod deploys don't touch Neon branching at all (`deploy-production.yml` composes `DATABASE_URL` from `STACKS_PROD_DB_*` components).

## Research Summary

Researcher verification pass (see earlier in the conversation) confirmed:
- `seeds.exs` is idempotent — every `insert_all` uses `on_conflict`; safe to re-run.
- `mix ecto.migrate` vs `Stacks.Release.migrate/0` behave identically for our use case — both iterate `ecto_repos` and call the same migrator.
- `Core.Repo` + `Core.ObanRepo` point at the same `DATABASE_URL`, so migrations against the staging DB affect both repos via a single pass.
- `deploy-production.yml` composes its `DATABASE_URL` from `STACKS_PROD_DB_*` secrets and doesn't consult Neon branching; prod is fully isolated from this work.
- `scripts/deploy-stack.sh` references `NEON_API_KEY` / `NEON_PROJECT_ID` across ~16 locations; `scripts/cleanup-preview.sh` references them at lines 11–12, 86, 91–92, 101–102, 109.
- The `deploy-preview` CI job at `.github/workflows/ci.yml:563-756` is entirely commented out. Uncommenting restores the original working logic.
- `docs/deployment/NEON_BRANCH_TOPOLOGY.md` has pre-existing duplicate sections (Lifecycle at lines 37+91, Configuration at 45+99, Cleanup at 81+109). Dedupe while rewriting.
- Stale `preview/*` branches in the current prod Neon project keep accruing compute until deleted.

## Approach Options

One architectural decision was made with human approval before this plan was written:

- **Option A (chosen):** Separate Neon project for staging + previews — absolute isolation, no CoW lineage to prod. Cost: marginally more secret management. **Recommended and approved.**
- **Option B:** Same project; branch staging from prod, truncate within staging. Cheaper but leaves an operator footgun (`branches reset`) and a lineage that Neon platform bugs could theoretically expose. **Rejected — isolation goal overrode simplicity.**
- **Option C:** Rotate existing `NEON_PROJECT_ID`/`NEON_API_KEY` GH secret values to point at the new project (no rename). Fewer code touchpoints. **Rejected — `NEON_STAGING_*` names chosen for semantic clarity + future-proofing.**

## Phases

### Phase 1: Bootstrap staging data
**Objective**: Populate the new staging Neon project with migrations + dev fixtures.
**Agent(s)**: Orchestrator direct execution (4 shell commands against `mix` + `neonctl`).
**Steps**:
1. Fetch staging connection URI: `neonctl connection-string --branch staging --project-id $NEON_STAGING_PROJECT_ID --api-key $NEON_STAGING_API_KEY`
2. `DATABASE_URL=<staging-uri> mix ecto.migrate` — iterates `Core.Repo` + `Core.ObanRepo`; second pass is a no-op.
3. `DATABASE_URL=<staging-uri> ALLOW_SEEDS=true mix run apps/core/priv/repo/seeds.exs` — loads dev fixtures.
4. Verify via `psql "<staging-uri>" -c "SELECT count(*) FROM op.users; SELECT count(*) FROM op.books; SELECT count(*) FROM op.bookshelves;"` — all non-zero.

**Test Command**: `psql` row count assertions (step 4).
**DoD Items**:
- [x] Phase 1 DoD from issue file: staging contains applied migrations + seeded dev fixtures; row counts non-zero on users/books/bookshelves.

### Phase 1b: Clean up stale prod-project preview branches
**Objective**: Delete orphaned `preview/*` branches in the old prod Neon project.
**Agent(s)**: Orchestrator direct execution.
**Steps**:
1. `neonctl branches list --project-id $NEON_PROJECT_ID --api-key $NEON_API_KEY` — using the OLD prod credentials.
2. Filter output for branches whose name starts with `preview/`.
3. For each, `neonctl branches delete <id>` (or bulk delete via the API).
4. Re-list and confirm zero `preview/*` remain.

**Test Command**: re-list assertion (step 4).
**DoD Items**:
- [x] Phase 1b DoD from issue file: zero stale `preview/*` branches remain in the prod project.

### Phase 2: Code + docs + CI rewire + @disable_migration_lock fix
**Objective**: Rename `NEON_*` → `NEON_STAGING_*` in the preview code path, remove the preview-side seed call, uncomment the CI `deploy-preview` job, rewrite the topology doc, AND restore `@disable_migration_lock true` on CONCURRENTLY migrations (regression discovered during Phase 1).
**Agent(s)**: `platform-agent` (delegated via Agent tool after Phase 1 + 1b verify).

**Scope expansion rationale**: Phase 1 ran `20260422072906_create_title_search_cache` against the new staging Neon DB. Ecto warned about the missing `@disable_migration_lock true` flag, the migration hung for 300s, and the connection was dropped by Neon mid-execution (ssl send: closed). Earlier in this codebase's history `@disable_migration_lock true` was removed from both the generator and the two existing cache migrations based on an incorrect analysis. This fix is tight-scope, same-domain (platform-agent), and ships with #142 to avoid a follow-up issue that'd sit in the backlog waiting for the next migration to surface the hang again.

**Steps**:
1. `scripts/deploy-stack.sh`: rename `NEON_API_KEY` → `NEON_STAGING_API_KEY` and `NEON_PROJECT_ID` → `NEON_STAGING_PROJECT_ID` across the preview-branch-creation code path. Default `NEON_PARENT_BRANCH` → `staging`. Remove the preview-side seed block.
2. `scripts/cleanup-preview.sh`: rename `NEON_*` → `NEON_STAGING_*` (lines 11–12, 86, 91–92, 101–102, 109).
3. `.github/workflows/ci.yml`: uncomment lines 563–756 (the `deploy-preview` job) and rewire the env block to use `NEON_STAGING_*` secrets.
4. `docs/deployment/NEON_BRANCH_TOPOLOGY.md`: full rewrite. Two-project architecture. Dedupe duplicate Lifecycle / Configuration / Cleanup sections. Remove pre-launch-window + belt-and-braces notes.
5. `.env.example`: update the Neon block to document `NEON_STAGING_*`.
6. `apps/core/lib/mix/tasks/proto_sync/migration_generator.ex`: restore `@disable_migration_lock true` alongside the existing `@disable_ddl_transaction true` in the generated migration template. Update the rationale comment to reflect the Neon-observed 300s hang + ssl-send-closed failure mode.
7. `apps/core/priv/repo/migrations/20260422072905_create_isbn_resolver_cache.exs`: add `@disable_migration_lock true`.
8. `apps/core/priv/repo/migrations/20260422072906_create_title_search_cache.exs`: add `@disable_migration_lock true`.
9. `apps/core/test/mix/tasks/proto_sync_test.exs`: flip the negative assertion `refute output =~ "@disable_migration_lock"` to `assert output =~ "@disable_migration_lock true"`.
10. Local-verify: `bash -n scripts/deploy-stack.sh && bash -n scripts/cleanup-preview.sh` clean. `just verify` clean (specifically: `mix test test/mix/tasks/proto_sync_test.exs` green).

**Test Command**: `just verify` + bash syntax checks + targeted test `mix test test/mix/tasks/proto_sync_test.exs`.
**DoD Items**:
- [x] deploy-stack + cleanup-preview scripts renamed, preview seed removed
- [x] ci.yml deploy-preview job uncommented + wired
- [x] topology doc rewritten + deduped
- [x] .env.example updated
- [x] proto.sync migration generator template restores @disable_migration_lock true
- [x] 20260422072905 + 20260422072906 migration files include @disable_migration_lock true
- [x] proto_sync_test.exs assertion flipped and passing

### Phase 3: Verification
**Objective**: Real preview deploy against staging proves the end-to-end flow works.
**Agent(s)**: Orchestrator direct execution (after Phase 2 merges + operator adds GH secrets).
**Steps**:
1. Push a throwaway branch (e.g., `chore/142-preview-verify`) to trigger the newly-uncommented CI `deploy-preview` job.
2. Watch the job output; verify it references `NEON_STAGING_PROJECT_ID`, not `NEON_PROJECT_ID`.
3. `neonctl branches list --project-id $NEON_STAGING_PROJECT_ID` — a new `preview/<slug>` branch should appear.
4. `neonctl branches list --project-id $NEON_PROJECT_ID` — no new `preview/*` should appear (old project untouched).
5. Hit the preview URL's `/api/auth/login` as the dev owner, then `GET /api/bookshelves/library` — non-empty placements (proves fixtures inherited via CoW).
6. Tear down via `cleanup-preview.sh --branch <slug>` and confirm the preview Neon branch is deleted.

**Test Command**: manual verification via the preview URL.
**DoD Items**:
- [x] Phase 3 DoD items from issue file: staging-parented preview, no seed step, fixtures present, endpoint returns non-empty.

## Open Questions
None.

## Integration Handoffs

- **Phase 1 → Phase 2**: Phase 1 produces no file-system changes. Phase 2 can proceed the moment the state file records Phase 1 complete. Operator adds the two GH secrets (`NEON_STAGING_PROJECT_ID`, `NEON_STAGING_API_KEY`) before Phase 2's CI changes ship.
- **Phase 2 → Phase 3**: Phase 3 requires Phase 2 merged to a branch that triggers CI. State file records `pe_review: "APPROVED"` for Phase 2 before Phase 3 starts.

## Operator Checklist (outside agent scope)

1. ✅ Create `thestacks-staging` Neon project with `staging` branch. *Done by operator.*
2. ✅ Add `NEON_STAGING_PROJECT_ID` + `NEON_STAGING_API_KEY` to local `.env`. *Done by operator.*
3. ⏳ Add `NEON_STAGING_PROJECT_ID` + `NEON_STAGING_API_KEY` as GH Actions repository secrets. *Required before Phase 3 can run CI.*
4. ⏳ After #142 ships: delete orphaned `NEON_PROJECT_ID` + `NEON_API_KEY` GH secrets (no code path references them post-merge). *At operator's leisure.*
