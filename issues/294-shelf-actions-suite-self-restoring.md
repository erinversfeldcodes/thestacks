# Issue #294: Make the shelf-actions E2E Suite Self-Restoring

## Summary
`e2e/tests/shelf-actions.spec.ts`'s real-mutation tests (move/remove) drain the suite user's seeded library shelf on every local run and never restore it — repeated local runs flake the pre-existing "move library→wishlist" test once the shelf empties (hit during #114 Phase 3, 2026-07-24; recovered by manually resetting `removed_at = NULL` on three placements in stacks_dev). CI/preview reseed per run, so this bites local iteration only.

## User Stories
None — E2E-infrastructure hygiene. Validation: two consecutive full local runs of the suite both green with no manual reseeding.

## Goal
The shelf-actions suite leaves the seeded state it depends on intact (or provisions its own), so repeated local runs are deterministic.

## Scope Check
All four checks: No (one spec file + possibly a helper).

## Wiring
Router wiring: n/a — test infrastructure.

## Feature-Completeness Pre-Check
n/a — no user stories (test infra).

## Technical Requirements
- Preferred: have the mutating tests provision their own placements via `mintSession` + the placement API (the #113 spine spec pattern — each test seeds what it mutates), instead of consuming the shared suite user's seed.
- Alternative: an afterEach/afterAll restore (move back / un-remove via API).
- Respect the active-placement unique index (one active placement per book) — the #114 recovery had to un-remove one placement per distinct book.
- Prove with two consecutive full local runs, both green.

## Reviewer Context
- `assertSeedOrSkip` (helpers.ts:428) exists for seed sufficiency; the fix should make the suite independent of it for mutated rows rather than skip-happy.

## Test Audit
| Layer | Applies? | Verdict |
|-------|----------|---------|
| E2E infra | yes | ❌ self-provisioning/restore needed → ✅ when two consecutive local runs green |
| others | no | n/a — spec-internal change |

## Definition of Done
- [x] Mutating tests provision or restore their placements — evidence: every test now mints its OWN fresh empty-collection user and provisions exactly the placement(s) it mutates via the new `provisionBookOnShelf` helper (helpers.ts) — no test consumes the shared suite seed. `test.use({ storageState })` and serial mode removed; the shared-user `ensureBookOnLibrary`/`ensureBookOnShelf` dependency dropped (`git diff` on `e2e/tests/shelf-actions.spec.ts` + `e2e/tests/helpers.ts`).
- [x] Two consecutive full local `npx playwright test shelf-actions.spec.ts --project=chromium` runs green, no reseed between — evidence: RUN 1 `9 passed (8.0s)`; RUN 2 `9 passed (7.2s)` (7 spec tests + 2 setup, all ✓; verbatim outputs in the completion report).
- [x] `check-e2e-vacuous-guards.sh` clean (`✓ No vacuous E2E assertion guards (Issue #275).`); **`completion-audit` basis met** — the self-restoration claim is proven by two live consecutive green runs with no manual reseed (the exact flake #294 describes), not by code-reading.

## Dependencies
None (pattern reference: e2e/tests/spine-rendering.spec.ts per-test placement provisioning, #113).

## Agent Assignment
`testing-coordinator`.

## Progress Notes
- 2026-07-24 — Created from #114 Phase 3 incident report (local seed drain flaking a pre-existing move test).
- 2026-07-24 — Fixed. Converted the suite to per-test provisioning (#113 pattern): each test mints a fresh user via `POST /api/test/session` and provisions its own placements through `provisionBookOnShelf` (new helper). Move/remove tests drain only their own throwaway user's shelf, so repeated local runs are deterministic. Discovered during implementation: a placement-free minted user triggers the onboarding overlay which intercepts catalogue clicks — the two catalogue add-flow tests therefore provision ONE placement (suppresses the overlay) while leaving the rest of the catalogue unplaced for the add flow. Two consecutive local runs green with no reseed; vacuous-guards clean; tsc clean on both touched files.
