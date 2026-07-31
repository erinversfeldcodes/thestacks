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
