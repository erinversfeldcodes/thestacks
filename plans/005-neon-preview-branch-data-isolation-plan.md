# Plan: Neon Preview Branch Data Isolation
**Issue**: #005
**Created**: 2026-03-13
**Status**: Draft
**Trial**: Hybrid (Branch 3 of Issue #024 evaluation)

## Context
Preview deployments currently branch from Neon's default parent (production), inheriting all user data. This is a data exposure risk. We need a `staging` intermediary branch containing only fixture data, and a seed gate so production never runs seeds.

## Research Summary
- `deploy-preview.sh` line 123 creates branches without `parent_id` — defaults to project default (production)
- `Stacks.Release.seed/0` runs unconditionally — no environment gate
- `deploy-preview.sh` line 292 calls `Stacks.Release.seed()` via `fly machine exec` — this is a cross-cutting integration point: if we gate seeds behind an env var, the exec command must pass that env var
- The `staging` Neon branch already exists (created during Agent Teams trial)
- `.env.example` has no `NEON_PARENT_BRANCH` entry

## Approach Options
- **Option A (chosen):** `NEON_PARENT_BRANCH` env var in deploy script + `ALLOW_SEEDS` env var gate in Elixir — simple, explicit, no framework changes needed. Recommended.
- **Option B:** Gate seeds by checking `PHX_HOST` or Fly app name pattern — couples seed logic to deployment naming, fragile. Not recommended.
- **Option C:** Remove `seed/0` entirely and seed staging manually via psql — loses the convenience of `Stacks.Release.seed()` for dev. Not recommended.

## Phases

### Phase 1: Deploy Script + Environment Documentation (platform-agent)
**Objective**: Update `deploy-preview.sh` to branch from `staging` and document the env var
**Agent(s)**: platform-agent
**Steps**:
1. Add `NEON_PARENT_BRANCH` to script header docs (optional env vars section, line 15)
2. Before the Neon branch creation block (line 96), resolve `NEON_PARENT_BRANCH` (default: `staging`) to its Neon branch ID via GET /branches API
3. Fail fast if the parent branch doesn't exist
4. Add `parent_id` to the branch creation JSON payload (line 123)
5. Update the seed exec command (line 292) to pass `ALLOW_SEEDS=true` so the gated `seed/0` still runs in preview
6. Add `NEON_PARENT_BRANCH=staging` to `.env.example` under the Neon section
**Regression Gate**: `bash -n scripts/deploy-preview.sh`
**DoD Items**:
- [ ] `deploy-preview.sh` reads `NEON_PARENT_BRANCH` (default: `staging`) and branches from it
- [ ] Lookup for `NEON_PARENT_BRANCH_ID` by name implemented
- [ ] `.env.example` documents `NEON_PARENT_BRANCH`
- [ ] Seed exec passes `ALLOW_SEEDS=true`

### Phase 2: Seed Gate (elixir-agent)
**Objective**: Gate `Stacks.Release.seed/0` behind `ALLOW_SEEDS=true` env var
**Agent(s)**: elixir-agent
**Steps**:
1. Add `seeds_allowed?/0` private function that checks `System.get_env("ALLOW_SEEDS") == "true"`
2. Wrap `seed/0` body: if allowed, run seeds; if not, print skip message and return `:ok`
3. Update `@moduledoc` to document the `ALLOW_SEEDS` gating
**Regression Gate**: `mix compile --warnings-as-errors && mix format --check-formatted` (from `apps/core/`)
**DoD Items**:
- [ ] `Stacks.Release.seed/0` is not called in the main production deploy path

### Phase 3: Topology Documentation (platform-agent or orchestrator)
**Objective**: Create `docs/deployment/NEON_BRANCH_TOPOLOGY.md`
**Agent(s)**: orchestrator (small enough to handle directly)
**Steps**:
1. Create `docs/deployment/` directory
2. Write topology doc covering: branch hierarchy, rationale, lifecycle table, configuration table, staging setup instructions
**DoD Items**:
- [ ] `docs/deployment/NEON_BRANCH_TOPOLOGY.md` created

### Parallel Execution
**Independent phases**: Phases 1 and 2 have no data dependency — they can run simultaneously
**Merge order**: Phase 2 first (Elixir), then Phase 1 (deploy script relies on seed gate being present), then Phase 3 (docs)
**Integration point**: Phase 1 step 5 (`ALLOW_SEEDS=true` in exec) depends on Phase 2's gate existing. The orchestrator verifies this at the regression gate.

## Open Questions
None — all requirements are specified in the issue.

## Integration Handoffs
Phase 1 (platform) and Phase 2 (elixir) have a cross-cutting dependency at the seed exec line. The orchestrator explicitly handles this: Phase 1's prompt includes the instruction to pass `ALLOW_SEEDS=true` in the exec command, ensuring both sides of the integration are addressed.
