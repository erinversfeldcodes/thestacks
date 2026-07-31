# Issue #327: W3 child — Steerable vision seam; mocks out of the production release

## Summary
Child of epic #313 (Wave 3, staff-campaign-2026-07-30). `Stacks.AI.MockClient` documents a configuration API it does not have, which is why the suite carries five ad-hoc replacement modules and a family of mock-echo tests. Give it the real API, delete the replacements, and move every remaining mock out of `lib/` so no mock compiles into the production release.

## User Stories
None — test infrastructure. Validated by probes + suite.

## Goal
Any test can steer the vision seam by endpoint; zero `Mock*` modules under `apps/core/lib`; the mock-echo cluster that existed *because* the seam was unsteerable is gone at its root.

## Scope Check
Test-infrastructure only; no production behaviour changes. Config keys move, implementations do not.

## Wiring
Router wiring: n/a. One production-visible change: mocks leave the release artifact.

## Feature-Completeness Pre-Check
n/a — no user stories.

## Technical Requirements
1. **Steerable `AI.MockClient`** (`apps/core/lib/stacks/ai/mock_client.ex`, 72 LOC): implement the process-dictionary steering its moduledoc (`:2-5`) already claims — `put_response(endpoint, response)` keyed on the endpoint string (`"is_book"`, `"extract_isbn"`, `"analyze"`, `"associate"`), falling back to today's literals when unset. Must survive `$callers` (the pipeline runs work in `Task.async` — copy `MockHttpClient`'s caller-walking idiom, `books/mock_http_client.ex:63-84`).
2. **Delete the five ad-hoc replacements** the missing API forced: `NotABookClient`, `AmbiguousClient`, `ErrorClient`, `NoIsbnClient`, `CircuitOpenClient` (defined in `upload_pipeline_test.exs`, referenced ~:1652–1689) plus the local replacements in `books_test.exs:571-575` and `ai/client_test.exs:1-7`. Rewrite each consuming test to steer the real mock instead.
3. **Mocks out of `lib/`**: move all remaining `Mock*` modules (`ai/mock_client.ex`, `ai/mock_together_client.ex`, `books/mock_http_client.ex`, `discovery/mock_brave_client.ex`, `discovery/mock_searxng_client.ex`, `enrichment/mock_rss_fetcher.ex`, `enrichment/mock_scraper_client.ex`, `transparency/mock_prometheus_client.ex`, plus `storage/mock.ex` and `geocoding/mock.ex` if present) into `apps/core/test/support/`. `mix.exs:39-40` already puts `test/support` on the `:test` elixirc path. Config keys referencing them must move to `test.exs` only — `config.exs` may no longer name a mock in any environment.
4. **Doc truth**: `MockHttpClient`'s moduledoc says first-registration-wins; the code prepends then `Enum.find`s, so last wins (`:34-37`). Fix whichever is wrong (prefer fixing the doc — last-wins is the useful semantic for per-test overrides) and say which you chose.

## Reviewer Context
- BOOTSTRAP (worktree): `git merge --ff-only feat/campaign-w2-312` FIRST (worktrees share refs with the main repo — no fetch needed; the branch is local and unpushed by owner ruling). Then copy `.env` from `/Users/erinversfeld/thestacks/.env`, and regenerate the gitignored Ecto/proto artifacts: `bash scripts/gen-ecto-proto.sh && bash scripts/gen-elixir-proto.sh` from the repo root of your worktree. All mix via `just run`.
- Long suite runs on this machine must be wrapped in `caffeinate -i` — an un-caffeinated `just run just test-elixir` slept mid-run twice on 2026-07-30 and produced phantom `ExUnit.TimeoutError`s on trivial tests.
- `config.exs:161-164`-style comments admitting "no real X integration exists" belong with the config move — carry the rationale, don't drop it.
- SCOPE-LOCK: do not touch `factory.ex` (that is #329) and do not rewrite the mock-echo *assertions* beyond what deleting the ad-hoc modules forces (that is #330). Your job is the seam.
- Commit: agent commits are denied here. Stage everything and write a ONE-LINE commit message (no body, no trailers — repo rule) to `/private/tmp/claude-501/-Users-erinversfeld-thestacks/78bc6659-34d4-45c2-b5b7-9a0337db2154/scratchpad/commit-msg-327.txt`; the lead commits it. NEVER push.

## Test Audit
| Layer | Applies? | Verdict |
|-------|----------|---------|
| Test seams | yes | ❌ steering probe: a test that sets a non-default vision response observes it (proves the API works, not the literal) |
| Release hygiene | yes | ❌ `grep -rl "defmodule.*Mock" apps/core/lib` returns nothing |
| Suite | yes | ❌ full elixir suite green post-move at cited count |
| 1–13 | no | n/a — infrastructure |

## Definition of Done
- [x] Steering works end-to-end — evidence: `upload_pipeline_test.exs` "Suite 6 — MockClient steering seam" 5 tests incl. "a steered response is consumed by the IdentifyBookJob pipeline, not just echoed" (reads the DB row back); 114 tests 0 failures
- [x] Nine ad-hoc replacement modules deleted (4 more than specified, same construct); consumers rewritten — evidence: builder mutation probe neutering `put_response/2` → 30 failures across 3 files, restored green
- [x] Zero mocks under `lib/` — evidence: `grep -rl "defmodule.*Mock" apps/core/lib` → empty (lead re-verified 2026-07-30); MIX_ENV=prod 266 files vs test 281
- [x] `config.exs` names no mock in any env — evidence: grep across config.exs/dev/prod/runtime → no output; all 10 bindings in test.exs; invariant documented + ADR-012 amended
- [x] Full elixir suite green under `caffeinate` — evidence: 3,194 tests 0 failures at merge; 3,206/0 at wave gate
- [x] `staff-review` verdict recorded below — evidence: LGTM + independent $callers probe (1 failure), Progress Notes

## Dependencies
Epic #313. Level 1 — parallel with #328 (disjoint stacks). **Blocks #329** (factories building through the public API need this seam) and #330.

## Agent Assignment
elixir-agent.

## Progress Notes
Filed 2026-07-30 (Wave 3 kickoff approved). Built in worktree; commit 2bfeccd2; merged 541d1471.
**staff-review verdict: LGTM** (2026-07-30, Mode B on 2bfeccd2). This is the strongest child of the campaign so far. Praise: (a) the steering probe *consumes* the steered response through `IdentifyBookJob` and reads the DB row back rather than echoing it — exactly the distinction the mock-echo finding was about; (b) the mutation probe (neuter `put_response/2` → 30 failures across 3 files) proves the seam is load-bearing, not decorative; (c) `MIX_ENV=prod` 266 files vs `MIX_ENV=test` 281 is real release-artifact evidence, not a grep; (d) the API design earns its shape — process-local so `async: true` survives, `:any` plus exact-endpoint precedence, function-valued responses for payload-dependent steering, and last-wins pinned by its own test; (e) the doc-vs-code call went the right way (fix the doc; changing the code would have silently altered every existing test) and ADR-012's stale file-layout section was amended rather than left to rot.
**Reviewer independent probe** (different from the builder's, aimed at the subtlest part): broke the `$callers` walk (`find_in_callers([])`) → `upload_pipeline_test.exs` 114 tests, **1 failure** — precisely "a steered response reaches work the caller farms out to a Task"; restored via Edit, 114/0, `git diff --stat` clean. The Task-visibility guarantee is real and singly-pinned.
Deviations reviewed and accepted: 9 ad-hoc modules deleted rather than the 5 named (the extra 4 use the same `with_client` construct — leaving them would have defeated the deliverable); `mock_dbt_runner` relocated for consistency; `books_test` assertion tightened to `{:error, :simulated_failure}` (also removes a global-env mutation from an async test); the spec's cited `config.exs:161-164` comment does not exist (config already named no mock — now an explicit documented invariant).
**Discovery → filed as #331** (not absorbed): 35 further ad-hoc vision-client modules across 8 test files are now mechanically convertible against this seam, well past this issue's budget.
