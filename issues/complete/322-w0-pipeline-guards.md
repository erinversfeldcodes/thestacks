# Issue #322: W0 child A — Pipeline guards: rate-limited scrape outcome + 0-byte upload gate

## Summary
Child of epic #311 (staff-campaign-2026-07-30 Wave 0). Two server-side guards: handle `SCRAPE_OUTCOME_RATE_LIMITED` as a determination (stops the price retry-storm; prices have produced 0 rows for three campaigns), and reject empty/undersized image uploads at commit before any GPU spend.

## User Stories
US-2.2.1 (prices — unblocking), US-1.1.1 (upload).

## Goal
`interpret/2` treats RATE_LIMITED like ROBOTS_BLOCKED (`{:determined, :rate_limited}`, `Monitoring.record_success/2`, NO Oban retry); `verify_object_exists/1` refuses objects below a minimum byte floor so a 0-byte commit fails fast with a rejection the SSE stream reports.

## Scope Check
2 functions, 2 test files, ~40 LOC. No split needed.

## Wiring
Router wiring: none — behaviour change on existing paths.

## Feature-Completeness Pre-Check
n/a — defect fixes on built paths (epic-level live drive covers observation).

## Technical Requirements
- `apps/core/lib/stacks/workers/trigger_price_scrape_job.ex`: add the `"SCRAPE_OUTCOME_RATE_LIMITED"` clause to `interpret/2` mirroring the ROBOTS_BLOCKED shape (~:208); provenance: commit `f28c032e` added the value to proto (`scraper.proto:273`) + Rust (`main.rs:213`) but not this consumer; the catch-all at `:267` currently converts it into `{:error, {:unrecognised_outcome,…}}` → retry loop.
- `apps/core/lib/stacks/books.ex` `verify_object_exists/1` (`:489-495`): match `{:ok, size} when size >= @min_image_bytes` (define the module attr; a sensible floor ~1KB); the failure path must produce the same rejection flow as not-a-book (row marked, SSE event) — reuse the existing rejection machinery, do not invent a parallel path.

## Reviewer Context
- `just run` for all mix invocations (bare mix corrupts _build). Proto files untouched — no codegen needed.
- The RATE_LIMITED clause is interim by design; #314's enum codegen makes the class structural later. Keep the clause shape identical to ROBOTS_BLOCKED for easy migration.
- `record_capability(_store, nil)` is a no-op (`prices.ex:240`) — safe on the empty-capability response.

## Test Audit
| Layer | Applies? | Verdict |
|-------|----------|---------|
| Oban/external | yes | ❌ interpret RATE_LIMITED → determined + no retry (`trigger_price_scrape_job_test.exs`); ❌ commit-with-empty-object → rejected, no IdentifyBookJob enqueued (`upload_pipeline_test.exs`) |
| Others | no | n/a — two-function change |

## Definition of Done
- [x] RATE_LIMITED test green — evidence: `trigger_price_scrape_job_test.exs` "a rate-limit is a determination, not a failure" + "records source-health success and does not retry"; 17 tests, 0 failures (2026-07-30)
- [x] Empty-object test green — evidence: `upload_pipeline_test.exs` "a 0-byte stored object is rejected at commit and enqueues no vision job" + controller 422 test; live: preview commit → 422 `image_too_small` (2026-07-30 drive)
- [x] Mutation probes — evidence: builder transcripts (2 red / 3 red, quoted in report) + reviewer re-probe on integration branch: size guard reverted → 147 tests/3 failures, restored → 147/0, `git diff --stat` clean
- [x] Scoped suites green — evidence: 164 tests 0 failures (touched files); 147/0 re-run post-merge; smoke 17/0 on fresh-migrated DB
- [x] `staff-review` verdict recorded below — evidence: LGTM, Progress Notes 2026-07-30

## Dependencies
Epic #311. No sibling dependencies (level 1, parallel with #323/#324).

## Agent Assignment
elixir-agent.

## Progress Notes
Filed 2026-07-30 (Wave 0 kickoff approved).
Built in worktree; commit 4d902253; merged to feat/campaign-w0-311 (0f712b08) after the base correction (see epic note).
**staff-review verdict: LGTM** (2026-07-30, Mode B on 4d902253). Praise: extracting `Books.reject_image/2` as THE rejection path (doc comment says exactly that) instead of parallel-pathing at commit is the deep-module move — both callers now share terminal-state + telemetry + SSE + event emission, and the in-flight-status scoping preserves retry idempotence; the commit message records f28c032e provenance. Reviewer re-probed independently on the integration branch: size guard reverted → 147 tests / 3 failures (422 became 202-accepted; 0-byte and sub-1KB objects enqueued GPU jobs); restored → 147/0, `git diff --stat` clean. Child's RATE_LIMITED probe transcript accepted (2 named failures incl. the exact unrecognised-outcome warning). Note (process, not code): the child caught the epic's wrong integration base (main vs feat/staff-engineer) and self-corrected by fast-forwarding — the epic branch was re-based accordingly. 0d/0e live-signal evidence lands at finalization drive.
