# Issue #331: Convert the remaining ad-hoc vision-client modules to the steering seam

## Summary
`Stacks.AI.MockClient` gained a real steering API in #327, and the five ad-hoc replacement modules in `upload_pipeline_test.exs` (plus four siblings) were deleted against it. **35 further ad-hoc vision-client modules remain across 8 test files** — each a hand-rolled `ClientBehaviour` implementation that exists only because the seam was previously unsteerable. They are now mechanically convertible.

## User Stories
None — test-suite hygiene. Discovered during #327 (Wave 3, staff-campaign-2026-07-30) and deliberately not absorbed: it exceeds that issue's ~300 LOC budget.

## Goal
No test file defines its own vision-client module; every vision behaviour is steered through `MockClient.put_response/2`, so the seam has one implementation and the mock-echo class cannot regrow.

## Scope Check
Test files only, mechanical. ⚠️ 8 files is over the usual comfort — **split by file group if the conversion is not purely mechanical**: (a) `moderation_test.exs` (15 modules — its own issue if it fights back), (b) the telemetry trio (`moderation_telemetry_test.exs`, `upload_telemetry_test.exs`, `upload_terminal_telemetry_test.exs`), (c) the rest (`identify_book_job_test.exs`, `upload_dbt_test.exs`, `metrics_endpoint_test.exs`, `enrichment_diagnostics_test.exs`).

## Wiring
Router wiring: n/a — test-only.

## Feature-Completeness Pre-Check
n/a — no user stories.

## Technical Requirements
- Replace each ad-hoc module with `MockClient.put_response(endpoint, response)` in the test's setup or body. Function-valued responses (`fn payload -> … end`) cover the payload-dependent cases the ad-hoc modules used pattern-matching for.
- Where a module encodes a *sequence* of responses (first call X, second Y), check whether `put_response` last-wins semantics suffice or whether the test genuinely needs a counter — if the latter, say so rather than contorting the seam.
- Watch for tests that relied on `Application.put_env` client swapping: steering is process-local, so `async: true` may become safe — note any test that can be un-serialised as a bonus, don't chase it.
- Each converted file must keep its assertions unchanged; this is a seam swap, not a verdict change (#330 owns verdicts).

## Reviewer Context
- The seam and its semantics are documented in `apps/core/test/support/mocks/ai/mock_client.ex` (moduledoc) and pinned by `upload_pipeline_test.exs` "Suite 6 — MockClient steering seam".
- `$callers` walking means steering survives `Task.async_stream` — that is what makes `moderation_test.exs`'s candidate-resolution tests convertible at all.
- Long suite runs under `caffeinate -i`; all mix via `just run`.

## Test Audit
| Layer | Applies? | Verdict |
|-------|----------|---------|
| Test seams | yes | ❌ `grep -c "@behaviour Stacks.AI.ClientBehaviour" apps/core/test` → 0 outside `test/support/mocks/` |
| Suite | yes | ❌ elixir suite green at unchanged count (assertions must not change) |
| 1–13 | no | n/a — test hygiene |

## Definition of Done
- [ ] Zero ad-hoc `ClientBehaviour` implementations outside `test/support/mocks/` — evidence: grep→output
- [ ] Suite green at the same test count as before (no assertion drift) — evidence: before/after counts
- [ ] Any test needing sequenced responses documented rather than contorted — evidence: note
- [ ] `staff-review` verdict recorded below

## Dependencies
- #327 (the steering seam) — **complete**, merged 541d1471.
- Sequence after #330 to avoid colliding with its rewrites of `enrichment_diagnostics_test.exs` and the telemetry files.

## Agent Assignment
elixir-agent.

## Progress Notes
Filed 2026-07-30 by staff-execute, from #327's discovery (scope-locked out of that issue).

## Progress Notes
Built in worktree; commit 0181b7c7; merged into `feat/campaign-w5-315`. 8 files, **+383/−1182**.
**staff-review verdict: LGTM** (2026-07-31, Mode B on 0181b7c7). Praise: (a) it **measured rather than inherited the estimate** — the issue said "35 across 8 files" from a Wave 3 survey; the truth was **34 across 7**, because #330 had already cleared `enrichment_diagnostics_test.exs`. Reporting the discrepancy is worth more than matching the number; (b) it built one place where the `/analyze` contract is written down (`test/support/vision_fixtures.ex`) rather than 34 places, and preserved a genuinely subtle invariant: `book_candidate/1`'s base map has **no `"confidence"` key**, because the #167 gate distinguishes *absent* from *present-nil* — a naive builder defaulting `confidence: 0.9` would have silently broken it; (c) **zero production changes** (`git diff -- apps/core/lib apps/vision frontend apps/scraper` empty), exactly as scope-locked; (d) it found **two tests that passed only because their fixture was permissive** — `moderation_test.exs`'s excluded-ISBN drop tests assert `{:error, :isbn_not_found}`, but with no `book_attrs` the pipeline reaches that error via a *failed lookup* regardless of whether the exclusion works, so both passed with the exclusion logic entirely removed. It added the `book_attrs` negative control the third test in that block already had, **changing no assertions**, and its probe then reddened all three.
**Lead independent verification (the claim that matters for a −1,182-line deletion):** counted test declarations across the three main converted files at the pre-merge commit and at HEAD — **52 before, 52 after** — and `git diff -U0 -- apps/core/test | grep -cE '^- *test "'` → **0 removed test lines**. The deletion is all mock scaffolding, no coverage. Also confirmed only two files still reference `@behaviour Stacks.AI.ClientBehaviour`: the seam itself, and a **prose mention inside the new fixtures moduledoc** (verified by reading line 6, not by trusting the grep count).
Probes (child's, reverted, `git diff -- apps/core/lib` empty): `build_payload/2` stops forwarding `excluded_books` → reddened the converted capture tests in **both** files, proving the closure-based steering that replaced a `:persistent_term` PID stash actually observes the payload; `drop_excluded_isbn_candidates/2` neutered → 1 red before the permissive-fixture fix, **3 after**; `check_confidence/2` failing closed on `nil` → reddened exactly the missing-confidence and explicit-nil tests, proving the absent-vs-nil fixture distinction is load-bearing.
Suites: converted files **163/0** (163 test declarations before and after), full Elixir **3330/0** (15 properties, 9 excluded); credo `--strict` clean (4101 mods/funs), format clean, `proto.sync --check` clean, all five proto targets green.
**Findings carried forward:** (1) two stale `async: false` comments claiming their file "swaps `Application.put_env(:core, :vision_client)`" when it no longer does — `upload_pipeline_test.exs:17`, `upload_controller_test.exs:2` (it corrected the equivalent comments in the three files it converted); (2) `moderation_test.exs` and `identify_book_job_test.exs` are now un-serialisable **on vision grounds** since steering is process-local, though both still need `async: false` for sandbox/global-telemetry reasons; (3) worktree bootstrap needs three steps beyond the documented brief — `mix deps.get` before `gen-ecto-proto.sh`, plus generating the Python/Rust/Elm proto artifacts (all gitignored, all absent in a fresh worktree) before `lint-proto.sh` passes. Worth folding into the bootstrap instructions.
