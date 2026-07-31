# Issue #312: [EPIC] Campaign Wave 2 — Deletions (~2k LOC)

## Summary
Epic for Wave 2 of `plans/staff-campaign-2026-07-30.md`: remove genuinely dead code before anything is refactored or test-hardened on top of it. Owner ruling 2026-07-30: `DiscoverBookstoreEventsJob` is NOT in scope (being wired instead — #321).

## User Stories
None — carrying-cost removal. Validation = suites stay green + deletion completeness checks.

## Goal
Three dead workers, the reviews mock scaffolding, orphaned functions, the `Route.Settings` alias, phantom CSS tokens, dead env vars, and superseded routes are gone; nothing that remains references them; both suites green at unchanged coverage of surviving behaviour.

## Scope Check
Epic. Children are deletion-only; no child mixes deletion with refactor.

## Wiring
Router wiring: removes two superseded routes (`POST /api/upload`, `POST /api/upload/identify`) after re-confirming zero callers; otherwise implementation-only.

## Feature-Completeness Pre-Check
n/a — no user stories; deletions verified by absence.

## Technical Requirements (child phases)
1. **Workers**: delete `RecalculateWearJob` (30 LOC — logs and discards; no `wear_level` column exists to recalculate), `ConfirmDeletionJob` (24 LOC stub), `FetchReviewsJob` (126 LOC, no enqueue path) + their test files (~750 LOC incl. the 682-line bookstore-events test ONLY if #321 rewrites it — coordinate); delete the reviews scaffolding per owner ruling D6: `ReviewFetcherBehaviour`, `MockReviewFetcher` (currently the *production* implementation — `config.exs:189-192`), `Enrichment.Reviews`, `Components/ReviewSummary.elm` "coming soon" cards. Story US-2.1.1 survives; re-scope in #320.
2. **Orphaned functions**: `Shelving.spine_data/1` (`shelving.ex:635-666`) + its ~200 test lines (`shelving_test.exs:724-913`); `open_token_family/1` (subset of rotate); `LogoutCompleted` → `FocusResult` idiom.
3. **Route.Settings collapse**: `Parser.map SettingsProfile (s "settings")` (`Route.elm:83`), delete the constructor + duplicate init branch (`Main.elm:718-740`); fixes sidebar-highlights-nothing on `/settings`; add the `fromUrl (toPath r) == r` property test to `RouteTest.elm`.
4. **Small kills**: 3 phantom CSS tokens (`--link-color`, `--link-hover`, `--parchment-ink` — 6 sites); dead env vars (`REQUIRE_EMAIL_CONFIRMATION`, `OPEN_LIBRARY_BASE_URL`, `VISION_MODEL_NAME`, `RELEASE_COOKIE` from .env/.env.example); superseded upload route pair (grep-confirm zero callers first — wiring-trace found none); stale comments: `Api.elm:688` presigned-URL fiction, `enrichment_diagnostics_test.exs:661-666` false exclusion claim, `UploadProgramTest.elm:428-433` stale docstring.

## Reviewer Context
- D6 (2026-07-27): reviews *story* survives — delete the mock scaffolding only; a real, sanctioned-source fetcher is future work.
- `MockReviewFetcher` deletion changes `config.exs` in ALL envs — the vision-adjacent test seams move to #313; do not pre-empt them here.
- `spine_data` deletion strands nothing: wear is computed inline (`compute_wear_level/1`); verify by grep + suite, not grep alone.
- Worktree agents: `notes/` is gitignored — goal-checked deletions stay in main tree.

## Test Audit
| Layer | Applies? | Verdict |
|-------|----------|---------|
| Suites post-deletion | yes | ❌ full `just run mix test` + `elm-test` green after each child; deleted-test coverage notes written (what each removed test claimed, and why nothing must replace it) |
| Route property | yes | ❌ `fromUrl∘toPath == id` test added (RouteTest.elm) |
| 1–13 | no | n/a — deletions; no new behaviour |

Punch: (1) coverage-note per deleted test file; (2) route round-trip property; (3) `grep -r` zero-reference proof per deleted module, captured in PR.
Verdict: baseline ❌ ×3.

## Definition of Done
- [x] Children landed (2, as kicked off); zero-reference greps ×10 all 0 — evidence: #325 Progress Notes 2026-07-30
- [x] Coverage-safety notes per removed test — evidence: #325 Progress Notes (lead-reconstructed, sourced from campaign test-inventory)
- [x] Round-trip property + entry-mapping pin — evidence: RouteTest.elm, both probed red/green (#326 Progress Notes, c34b302b)
- [x] Suites green — evidence: elixir 3,187/0 (caffeinated coveralls, b2z0yx18i); elm 1331/0
- [x] Standards — evidence: `just ci` all groups PASS except documented dockle-daemon local exception; squawk clean
- [x] Test audit GREEN — evidence: both punch items delivered (property test; census-style greps)
- [x] `completion-audit` passed — evidence: 2026-07-30 run, Progress Notes below
- [x] Completion Bar — evidence: /settings live drive ss_0513sacfo + DOM `settings-hub__nav-item--active :: Profile`; select "Profile"; title correct
- [x] `staff-review` per child — evidence: #325 LGTM, #326 LGTM WITH NOTES→strengthen, on disk

## Dependencies
- #311 (Wave 0) — 0d touches `trigger_price_scrape_job.ex`; land first to avoid churn. Reason: file-level conflict avoidance only.
- MUST precede #313/#314/#315 (never harden tests for, or refactor, code being deleted — sequencing rule 1).

## Agent Assignment
Orchestrator; children to elixir-agent + elm-agent.

## Progress Notes
Filed 2026-07-30 by staff-campaign Stage 7.
**completion-audit: PASS** (2026-07-30). Sweep notes: suite instability across runs (81→27→0→7→1→29→0) was adversarially chased to two infra causes — machine sleep mid-run (trivial tests "timing out" at wall-clock; fixed procedurally with caffeinate) and a Postgres connection flap (canary-verified recovered) — with the final clean run under full coverage instrumentation; deletion evidence is greps + green suite (no live-drive class applies to removals beyond the /settings state fix, which was driven); no phantom refs; no dropped scope (bookstore-events exclusion is owner-ruled, recorded in kickoff + plan); reviewer notes routed (#320 §4a exists; #326's deviations accepted in-review). Server logs for the small /settings drive were not separately captured — noted as the one soft edge, accepted for a state-only UI check.
**staff-review (epic cumulative): LGTM** — the wave is two reviewed children + two lead commits (strengthen, timeout bump), disjoint stacks, no interaction surface.
**PR deferred by owner ruling 2026-07-30** — all wave PRs batch until the final wave; branch feat/campaign-w2-312 stays local, stacked on feat/campaign-w0-311.
