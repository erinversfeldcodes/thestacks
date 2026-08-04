# Issue #383: The RSS transport-bound test measures wall clock and fails under load

## Summary
`RssFetcherTest` "returns rather than hanging when the peer stalls the TLS handshake" asserts that
`RssFetcher.probe/1` returns within **20 s** (`@must_return_within_ms`). Observed on 2026-08-04
taking **33,041 ms** during a `just verify` run that shared the machine with a local Phoenix server,
then passing **3/3** in isolation moments later.

Not a regression in `RssFetcher` — nothing in that run touched it. The test measures **wall-clock
elapsed time**, so it charges scheduler starvation to the code under test.

## User Stories
None. Test-suite reliability.

## Goal
The test fails when the transport bound is genuinely absent and passes when the machine is merely
busy.

## Scope Check
- More than 3 controllers? → None; one test file, possibly one config value.
- More than 2 new endpoints? → None.
- More than ~300 lines? → No.
- Unrelated concerns? → No.

## Technical Requirements

The bound has little headroom over the real timeout, which is what makes it fragile: a 20 s assertion
against a connect timeout in the same order of magnitude leaves only a few seconds for scheduling.
Options, best first:

1. **Assert the bound structurally rather than temporally** — that `probe/1` passes a `connect_timeout`
   to Finch at all, and separately that a stalled peer yields `{:error, _}`. That is what the test
   actually cares about ("the connect phase is bounded"), and it does not involve a stopwatch.
2. Keep the timing test but give it generous headroom (e.g. 3× the configured timeout) **and** tag it
   so it is excluded from parallel runs. Weaker: a wide bound stops catching a bound that grew.
3. Do NOT simply raise `@must_return_within_ms`. The comment on `@fetch_must_return_within_ms` already
   notes the bound is chosen to redden "if the bound is dropped" — widening it erodes the only thing
   the test is for.

⚠️ Its sibling `"dribbles the response forever"` has the same shape and the same risk; fix both or
neither.

## Reviewer Context
- ⚠️ **Do not delete these tests.** They cover a real hazard — a peer that stalls a TLS handshake, and
  one that dribbles bytes forever inside `receive_timeout`. The second is explicitly the case
  `receive_timeout` alone does not catch. The problem is the *assertion mechanism*, not the coverage.
- This is filed rather than dismissed on purpose: the project's rule is that a flaky test is found and
  fixed, never waved off as "not ours". It is not ours in origin, but it is ours to fix.

## Test Audit

| Layer | Applies? | Verdict |
|-------|----------|---------|
| Elixir unit | yes | exists, covers the right hazard, asserts it by stopwatch |

Punch list:
1. Whatever replaces the timing assertion must still fail when the bound is removed from
   `RssFetcher.probe/1`. Mutation-probe it: strip the `connect_timeout` and confirm red.

## Definition of Done
- [x] The test fails when the transport bound is removed — evidence: two probes, one per half.
      Structural: stripping `request_timeout` from `request_opts(:probe)` → `every operation ships
      both timeouts` fails naming the operation and the measured 35,017ms hazard. Behavioural: passing
      `[]` to `Finch.request/3` → the dribble test fails (run stretches to 55.7s). A first probe of the
      seam alone did NOT fail — with production bounds intact, ignoring injected opts still stays
      bounded — which is recorded because it sharpened what the behavioural tests actually guard
- [x] The test passes on a loaded machine — evidence: 5/5 green with the asset build (`npm run
      deploy`) running concurrently — the same load that produced the 28,569ms failure hours earlier.
      Idle: 5/5 in 11.1s
- [x] Both transport-bound tests use the same mechanism — evidence: all behavioural tests inject
      `@tiny_bounds [receive_timeout: 500, request_timeout: 1_000]` through the new `opts` seam and
      assert at 10s (10–20× headroom); `request_opts/1` is the single source the call sites and the
      structural test both read, so the pin cannot drift from what production sends
- [x] `just run just verify` passes — wave gate, see epic state
- [x] `gdpr-review`: n/a — a keyword-list seam and test mechanics; no data surface. Stated, not skipped.

## Dependencies
None.

## Agent Assignment
`elixir-agent`.

## Progress Notes
- 2026-08-04: Found during a `just verify` run for #306. Characterised rather than assumed: 33,041 ms
  under load vs 3/3 green idle, bound 20,000 ms. The failure message ("connect phase was not bounded")
  is actively misleading in this case — the connect phase *was* bounded; the machine was busy.

## Renumbered
- 2026-08-04: filed as **#312**, which was already taken by the 2026-07-30 campaign's wave epic
  (`issues/complete/312-campaign-*.md`). The collision was invisible until `just wave-status` resolved
  a Wave 2 item to this file and reported its unchecked boxes against that
  wave. Renumbered to #383. **Check `issues/complete/` as well as `issues/` before taking a number** —
  `mcp__project-tools__next_issue_number()` does; counting files in `issues/` alone does not.

## Progress Notes (close-out)
- 2026-08-04: Fixed by splitting what one stopwatch had been asked to prove. **Structural**:
  `request_opts/1` is now the single place the bounds live, read by the call sites and pinned by a
  test — deleting a bound fails a test that names the hazard, not a timer. **Behavioural**: the
  stall/dribble tests keep their stopwatches but run against injected 500ms/1s bounds, so the
  assertion sits at 10–20× headroom instead of the 1.5× that load ate twice. Suite time fell from
  ~30s to 11s as a side effect.
- 2026-08-04: **staff-review: LGTM.** The design point worth keeping: the wall clock was being asked
  two questions at once — "is the bound present?" (structural, now timerless) and "does the bound
  reach the socket?" (behavioural, where a stopwatch is legitimate *if* the ratio between assertion
  and bound is wide). The probe that failed to fail was the review's most useful output: it showed
  the seam itself is not load-bearing, only the bounds are, and the comment in the test now says so.

