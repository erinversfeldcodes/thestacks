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
- [ ] The test fails when the transport bound is removed — evidence: probe output
- [ ] The test passes on a loaded machine — evidence: green while a dev server runs alongside, the
      condition that produced the 33,041 ms failure
- [ ] Both transport-bound tests use the same mechanism
- [ ] `just run just verify` passes
- [ ] `gdpr-review`: n/a — test-only. Stated, not skipped.

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
