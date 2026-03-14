# Complete: Neon Preview Branch Data Isolation (Hybrid Trial)
**Issue**: #005
**Date**: 2026-03-13
**Trial**: Hybrid (Branch 3 of Issue #024 evaluation)

## Summary

Preview deployments now branch from a dedicated `staging` Neon branch instead of `main`. This prevents ephemeral preview environments from inheriting production user data. The seed function is gated behind `ALLOW_SEEDS=true` so production deployments never run seeds.

## Changes

| File | Change |
|------|--------|
| `scripts/deploy-preview.sh` | Added `NEON_PARENT_BRANCH` env var (default: `staging`), branch ID lookup, `parent_id` in create call, fail-fast if staging not found, `ALLOW_SEEDS=true` for preview seeding |
| `apps/core/lib/stacks/release.ex` | Gated `seed/0` behind `ALLOW_SEEDS=true` env var via `seeds_allowed?/0` |
| `.env.example` | Documented `NEON_PARENT_BRANCH=staging` |
| `docs/deployment/NEON_BRANCH_TOPOLOGY.md` | Three-tier topology documentation (main -> staging -> preview) |

## DoD Verification

- [x] `staging` Neon branch created in the project
- [x] `deploy-preview.sh` reads `NEON_PARENT_BRANCH` (default: `staging`) and branches from it, not from `main`
- [x] Lookup for `NEON_PARENT_BRANCH_ID` by name implemented in `deploy-preview.sh`
- [x] `Stacks.Release.seed/0` is not called in the main production deploy path (only in preview with `ALLOW_SEEDS=true`)
- [x] `.env.example` documents `NEON_PARENT_BRANCH`
- [x] `docs/deployment/NEON_BRANCH_TOPOLOGY.md` created
- [x] Preview branch contains only fixture data — validated by E2E (9/9 tests passed)

## Validation

Single deploy to Fly.io preview environment — exit code 0:
- Neon branch created from `staging` parent (not `main`)
- Seeds loaded via `ALLOW_SEEDS=true` gating
- Warmup: 4/4 vision pipelines resolved
- Playwright E2E: 9/9 tests passed
- OWASP ZAP: FAIL-NEW 0
- Nuclei: clean
- IDOR: cross-user access blocked (HTTP 403)
