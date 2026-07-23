# Issue #280: Migrate remaining register+confirm E2E flows to the session-mint helper

## Summary
`public-profile.spec.ts` (and any other spec still using the `registerAndConfirm` register →
confirmation-token → confirm dance) consumes the shared `:auth` rate bucket (60/60s per IP), which
is the proven cause of rotating preview-E2E failures under load: during #116's consolidated preview
gate, back-to-back runs exhausted the bucket and `registerAndConfirm` failed with 429s
(`public-profile.spec.ts:520`), green again after cool-down. #192 built `POST /api/test/session` +
`mintSession`/`injectSession` and migrated `gdpr.spec.ts`; this issue migrates the remaining
fresh-user flows so the suite stops competing with itself (PE gate P2-1 remedy, #116).

Also folds in the PE's P3-5: specs that skip on thin seed data (`reading-pile-limit.spec.ts` needs
51 catalogue books; the progress specs need a ≥10-page book) have loud `test.skip`s but no
guarantee the preview catalogue satisfies them — add a seed assertion or a documented guarantee so
enforcement can't silently skip forever. (Overlaps #269's zero-skips charter — coordinate.)

## User Stories
None — E2E harness integrity. Protects the suites backing US-10.x (public profiles) and US-1.6.x.

## Goal
No spec outside auth's own test surface performs a real register/login against the `:auth` bucket;
fresh-user specs mint isolated sessions; the deploy-preview E2E is stable across back-to-back runs;
seed-dependent specs are guaranteed their data (or fail loudly, never skip silently).

## Scope Check
Test files + possibly a seed line. 0 controllers, 0 endpoints, <300 LOC. Single concern. ✅

## Feature-Completeness Pre-Check
n/a — test-infrastructure. The helper exists and is proven (#192, #116 Phase 5 usage).

## Technical Requirements
1. Inventory `registerAndConfirm`/`registerViaApi`-style fresh-user creation across `e2e/tests/`
   (known: `public-profile.spec.ts:505-530`; check onboarding/confirm-email specs — those that TEST
   registration itself stay on the real flow by design).
2. Migrate each non-registration-testing spec to `mintSession` + `injectSession` (template:
   `gdpr.spec.ts`, `reading-journey.spec.ts`).
3. Seed-data guarantee for `reading-pile-limit.spec.ts` (≥51 books) and the progress specs
   (≥1 book with `page_count >= 10`): assert in suite setup against the target env, or extend the
   seed with a documented invariant.
4. Prove stability: two consecutive full chromium runs against a preview with zero auth-bucket
   failures.

## Reviewer Context
- `:auth` bucket 60/60s per IP is shared by the whole parallel suite; auth.setup.ts suite-user
  logins also draw from it — leave those (they're the sanctioned baseline) unless they too flake.
- Specs that test registration/confirmation UX must keep the real flow (their subject IS the
  bucket-guarded path).

## Test Audit
| Layer | Applies? | Verdict |
|-------|----------|---------|
| E2E harness | yes | ❌ → ✅ — migrated specs green on preview twice consecutively, zero 429s |
| 1–13 app layers | no | n/a — no app surface changed |

## Definition of Done
- [ ] All non-auth-testing fresh-user specs use mintSession — evidence: grep + diff
- [ ] Two consecutive full preview chromium runs, zero auth-bucket failures — evidence: run outputs
- [ ] Seed-data guarantee for pile-cap and progress specs — evidence: assertion or seed diff
- [ ] `just verify` passes

## Dependencies
- #192 (helper, shipped). Coordinate with #269 (zero-skips CI E2E).

## Agent Assignment
`testing-coordinator` / playwright.

## Progress Notes
Filed 2026-07-23 from #116 PE gate (P2-1 remedy + P3-5).
