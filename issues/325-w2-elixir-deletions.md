# Issue #325: W2 child A — Elixir deletions: dead workers, reviews scaffolding, orphans

## Summary
Child of epic #312 (Wave 2, staff-campaign-2026-07-30). Delete the three dead Oban workers, the reviews mock scaffolding (owner ruling D6 — the story survives, re-scoped in #320), the orphaned `spine_data/1`, `open_token_family/1`, the superseded upload route pair, and the false tag comment. `DiscoverBookstoreEventsJob` is EXCLUDED (owner ruling: wired in Wave 11 / #321).

## User Stories
None — carrying-cost removal (~1.5k LOC). Validation = zero-reference greps + suites green + coverage notes.

## Goal
Nothing that remains references anything deleted; every removed test has a written coverage note; suites green at cited counts.

## Scope Check
Deletion-only; no refactors ride along.

## Wiring
Removes `POST /api/upload` + `POST /api/upload/identify` (router.ex:171-172) after a fresh zero-caller grep (wiring-trace 2026-07-30 found none in frontend/e2e).

## Feature-Completeness Pre-Check
n/a — no user stories.

## Technical Requirements
1. Workers + tests: `recalculate_wear_job.ex` (30 LOC; logs and discards — no wear column exists; real logic inline at `shelving.ex:635-666` stays until item 3), `confirm_deletion_job.ex` (24 LOC stub), `fetch_reviews_job.ex` (126 LOC, zero enqueue sites) + their test files.
2. Reviews scaffolding per D6: `Stacks.Enrichment.Reviews`, `ReviewFetcherBehaviour`, `MockReviewFetcher` (wired as PROD impl at `config.exs:189-192` — remove the config key everywhere), `fetch_reviews_job_test.exs`. Leave `op.review_snapshots` table + migration alone (schema history; #320 records the re-scope).
3. Orphans: `Shelving.spine_data/1` + `compute_wear_level` ONLY if unreferenced after worker deletion (verify — the inline wear computation on moves must SURVIVE; delete only the aggregation fn the dead worker consumed) + its test block (`shelving_test.exs:724-913`); `Accounts.open_token_family/1` (strict subset of `rotate_token_family/1` — repoint any caller).
4. Routes: delete `POST /api/upload` + `/upload/identify` + their controller actions + tests after grep-proof of zero client callers (capture the grep in the report).
5. Comments: fix `enrichment_diagnostics_test.exs:661-666` (claims a tag exclusion that does not exist — either wire the exclusion or correct the comment to match reality; check whether the 4 tagged tests pass today and choose accordingly).

## Reviewer Context
- BOOTSTRAP (worktree): first `git fetch origin feat/campaign-w0-311 && git merge --ff-only FETCH_HEAD` (your worktree branches from origin/main; the epic base is the Wave 0 head). Then copy `.env` from the main checkout, run `bash scripts/gen-ecto-proto.sh` + `bash scripts/gen-elixir-proto.sh` to regenerate gitignored `apps/core/lib/stacks/gen/` before compiling. All mix via `just run`.
- Coverage-note discipline: for every deleted test file/block, one line in the report — what it claimed, and which surviving guarantee (or explicit "never a real guarantee — see mock-echo finding") covers it.
- `Components/ReviewSummary.elm` is child B's file — do NOT touch frontend here; coordinate via the "What People Think" section: child B removes the rendering, you remove the backend. Both note the seam.
- Commit pathspec only your files; NEVER push.

## Test Audit
| Layer | Applies? | Verdict |
|-------|----------|---------|
| Suites post-deletion | yes | ❌ full `just run mix test` green; zero-reference grep per module captured |
| Route removal | yes | ❌ 404 test or router test updated; grep-proof archived |
| 1–13 | no | n/a — deletions |

## Definition of Done
- [x] Zero-reference greps — evidence: 10 modules × 0 refs (lead-run, quoted in Progress Notes)
- [x] Coverage note per deleted test — evidence: Progress Notes (lead-reconstructed from campaign test-inventory findings)
- [x] Full suite green — evidence: 3,187 tests 0 failures (run 3; runs 1–2 failed on diagnosed infra: contention then Postgres flap, subset+canary green in isolation)
- [x] Mutation-probe N/A — deletions add no assertions; the guarantee is zero references + green suite — evidence: 10× grep = 0 refs (Progress Notes, 2026-07-30) + `just run mix test` → 3,187 tests, 0 failures
- [x] `staff-review` verdict recorded below — evidence: LGTM, Progress Notes

## Dependencies
Epic #312; base = Wave 0 head (#311 merged work). Sibling #326 independent (disjoint files, shared seam noted).

## Agent Assignment
elixir-agent.

## Progress Notes
Filed 2026-07-30 (Wave 2 kickoff approved).
Built in worktree (builder hit the monthly spend limit after completing the work, before its final run/commit/report); lead committed 45ddcc44 and merged (9a929af3), then produced the verification the report would have carried: 10× zero-reference greps (RecalculateWearJob, ConfirmDeletionJob, FetchReviewsJob, MockReviewFetcher, ReviewFetcherBehaviour, Enrichment.Reviews, spine_data, open_token_family, upload/identify, ReviewSummary — all 0 refs across lib/test/frontend/e2e/config); full suite 3,187/0 (third run — first two hit local contention then a Postgres connection flap, both diagnosed and cleared: failing subsets green in isolation, canary 11/11, DB pg_isready).
**Coverage-safety notes (lead-reconstructed):** recalculate_wear_job_test (32 LOC) asserted only `:ok`/`:cancel` — tautological, guarded nothing (campaign test-inventory finding); confirm_deletion_job_test tested a stub's log lines; fetch_reviews_job_test + reviews_test asserted MockReviewFetcher's own literals (mock-echo class, test-inventory §3 item 8) — no real guarantee lost; shelving spine_data block (195 LOC) tested the deleted aggregation fn only — the inline wear computation on moves keeps its own coverage in the surviving move/reread tests; upload controller superseded-route tests covered endpoints with zero client callers (wiring-trace).
**staff-review verdict: LGTM** (2026-07-30, Mode B on 45ddcc44). The deletion is faithful to spec incl. the two exclusions (DiscoverBookstoreEventsJob, review_snapshots migration); consequential edits (open_token_family repoint in auth_controller/test_helper_controller, config key removal, enrichment-diagnostics comment fix) are minimal and correct; −1,312 LOC with the suite green and every name at zero references. Note: the reviews config key removal leaves `:review_fetcher` unread anywhere — matches #320's re-scope plan.
