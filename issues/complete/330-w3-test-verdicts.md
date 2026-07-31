# Issue #330: W3 child — Execute the test-critique verdicts

## Summary
Child of epic #313, final level. The campaign's test inventory named specific tests that cannot fail, skip exactly when the thing they guard is broken, or assert a mock's own literals. Execute those verdicts now that the seams (#327), the wire format (#328) and the factories (#329) have moved underneath them.

## User Stories
None — test truthfulness. Each rewrite is validated by a probe.

## Goal
Every test named below either fails when its behaviour breaks, or is gone with a written note naming what still covers the behaviour.

## Scope Check
Test files only (plus the one E2E spec). No production code.

## Technical Requirements
1. **The unfalsifiable "SECURITY" test.** `frontend/tests/Page/BookshelfReadOnlyTest.elm:233-241` asserts zero mutating requests from a read-only public shelf — but its effect translator is `TestHelpers.elm:907-911`, `libraryEffects msg = case msg of _ -> SimulatedEffect.Cmd.none`: **no `Bookshelf.Msg` can produce any effect in any bookshelf harness**, so the assertion cannot fail. Give it a real translator and a **positive control** (a msg that *does* produce a request in the owner case), mirroring the correct pattern at `Page/BookshelfProgramTest.elm:258-263`. Probe: add a mutating effect → must redden.
2. **Fail-open rate-limit spec.** `e2e/tests/rate-limit.spec.ts:86-89` is `test.skip(!sawRateLimit, "…rate limiting appears disabled")` — it skips precisely when the limiter is broken, and it is the only E2E proof of the `:auth` bucket. Make it assert the 429. If a stack legitimately runs with limiting off, gate on an explicit env expectation (the `assertSeedOrSkip` pattern at `helpers.ts:444-451`), never on the observation itself.
3. **Mock-echo removals/strengthens**, each with a one-line coverage note (what covered it, or "never a real guarantee"):
   - `apps/core/test/stacks/discovery/searxng_client_test.exs:88-117` — the whole describe asserts `put_response` then reads it back; never references the real client. Remove or rewrite against the real module.
   - `discovery/brave_client_test.exs:7-34` — same shape (its second describe, `:36-86`, is genuinely good — keep).
   - `books_test.exs:552-565` and `:595-620` — assertions are `is_list(candidates)` and `title != nil` against a fully-populated fixture; strengthen to assert the actual resolved values now that #327 makes the seam steerable.
   - `stacks/transparency_test.exs:34-38,104-111,115-127` — configures a value then asserts `is_number/1`; assert the configured value.
   - `stacks_web/book_controller_test.exs:352-353` — `assert conn.status in [201, 409]` is a disjunction over the two opposite outcomes; pick the one the test means.
4. **The missing guarantee.** Reset-token single-use was proven live on 2026-07-30 (replay → 400) but has no test: add one to `apps/core/test/stacks/email_test.exs` that consumes a token then asserts a second `reset_password/2` with it fails. Probe it (remove the token-clear → must redden).
5. **Tag truth.** `upload_pipeline_test.exs:336-343` is the suite's only latency assertion and is `@tag :sla`, permanently excluded (`test_helper.exs`) with no explaining comment — either run it (with a defensible threshold) or delete it, and say which. `books/enrichment_diagnostics_test.exs:661-666` claims 4 tests are excluded by a tag that is not in the exclude list — the tests do run; correct the comment (Wave 2 touched this file; verify current state first).

## Reviewer Context
- BOOTSTRAP (worktree): `git merge --ff-only feat/campaign-w3-313` FIRST — you need #327/#328/#329 underneath you. Copy `.env`; regenerate proto artifacts; `just run` + `caffeinate -i` for long runs; elm-test via the main checkout's binary with `proto/gen/elm` copied in.
- Every removal needs its coverage note — a removal that silently shrinks coverage is the failure this wave exists to prevent.
- Probe discipline: one probe at a time, revert with Edit (never `git checkout`), `git diff --stat` clean before reporting.
- Commit: agent commits are denied. Stage; ONE-LINE message (no body/trailers) to `.../scratchpad/commit-msg-330.txt`. NEVER push.

## Test Audit
| Layer | Applies? | Verdict |
|-------|----------|---------|
| Test truthfulness | yes | ❌ probes: read-only SECURITY test reddens on a mutating effect; rate-limit spec fails (not skips) with limiting off; reset-token test reddens when the clear is removed |
| Coverage safety | yes | ❌ note per removed/rewritten test |
| Suites | yes | ❌ elixir + elm + e2e-compile green, counts cited |
| 1–13 | no | n/a |

## Definition of Done
- [x] Three named probes run with red output quoted — evidence: SECURITY test (0 vs 1 expected), rate-limit counterfactual (old `1 skipped` → new `1 failed`), reset-token replay (`{:ok, %User{}}` — the replay set the attacker's password)
- [x] Coverage note per removal/rewrite — evidence: in-file notes at each site; searxng/brave echoes covered for real by source_discovery_job_test + discover_author_sources_job_test
- [x] Tag decisions — evidence: `:sla` RUN IT at 1s bound (measured 31.9/30.9/35.2ms; ~240× margin vs the 240s SSE budget), removed from test_helper.exs; enrichment-diagnostics needed no action (Wave 2 already corrected it, verified by --only=4 tests / default 0 excluded)
- [x] Suites green — evidence: elixir 3,206/0 (9 excluded), elm 1,332/0; production diff EMPTY (lib/src untouched)
- [x] `staff-review` verdict recorded below — evidence: LGTM + independent verification of the handleOrganiser finding → #332, Progress Notes

## Dependencies
Epic #313. **Depends on #327, #328, #329** (rewrites the files they move; verdicts assume the new seams). Level 3 — last.

## Agent Assignment
elixir-agent + elm-agent (mixed; may split if the orchestrator prefers).

## Progress Notes
Filed 2026-07-30 (Wave 3 kickoff approved). Built in worktree; commit 1ce49621; merged.
**staff-review verdict: LGTM** (2026-07-30, Mode B on 1ce49621). Praise: (a) **production diff is empty** — the whole wave-closing child changed test files and one CI env var, exactly as scope-locked; (b) the rate-limit fix was proven by *counterfactual on an identical no-limit stub* — old form `1 skipped`, new form `1 failed` — which is the only way to prove a fail-open repair, and both gate directions were checked (localhost skips, `E2E_EXPECT_RATE_LIMITING=1` enforces, now wired into CI); (c) the reset-token probe produced the campaign's most alarming single line — with the token-clear removed, **the replay set the attacker's password**, and the pre-existing test asserted the column (the mechanism) rather than the guarantee; (d) the `:sla` decision was *measured* (31.9/30.9/35.2 ms) rather than guessed, and correctly reasoned that the regression is categorical — a 1s bound keeps ~240× margin against the 240s SSE budget while being genuinely runnable, so the suite's only latency assertion stops being permanently excluded; (e) every removal carries its coverage note, and two rewrites found real holes: `books_test`'s `shelf_name` test never looked at the placement at all (would have passed with `shelf_name` ignored), and `is_integer(cache_ttl)` passed for `0`, which disables the cache.
**Reviewer verification of the flagged production defect**: confirmed independently — `handleOrganiser` (`Page/Bookshelf.elm:352`) dispatches on `( subMsg, token, shelves )` with `config.readOnly` absent from every mutating branch; `grep readOnly` over the module shows it only in config records and one view check at `:205`. The child's severity read is right and worth preserving: the request carries the *viewer's* token, so the server scopes it to the viewer's own bookshelf — not a cross-reader write, but a guarantee living in the view rather than the update function. Correctly left unfixed (production change, scope-locked) → **filed as #332**.
**Honesty noted and accepted**: the child reported an unidentified 4th failure in its first full-suite run that did not reappear in two subsequent runs, and flagged it rather than dismissing it — the right call under this campaign's no-flaky-dismissal rule. The wave gate (`just ci` on the integration branch) is the arbiter; recorded here so it is not silently forgotten.
Suites: elixir **3,206/0** (9 excluded — `:sla` no longer among them), elm **1,332/0**.
