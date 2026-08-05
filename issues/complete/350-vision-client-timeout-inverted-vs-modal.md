# Issue #350: The vision client gives up 90 seconds before Modal does

## Summary
Found by the lead answering an owner question about the SSE deadline (2026-07-31). Two services disagree about how long the same call may take, and the disagreement is silent:

| Side | Value | Source |
|---|---|---|
| Elixir client receive timeout | **210s** | `apps/core/lib/stacks/ai/client.ex:64` |
| Modal function timeout | **300s** | `apps/vision/modal_app.py:191` |

The Elixir constant's own comment states the intent backwards:

> `# 210s gives the Modal service headroom beyond its own 300s inference timeout.`

**210 is less than 300.** It gives the service *less* time, not headroom.

## Why this is worse than an off-by-one
Modal's 300s is justified in its own comment as cold start (~60s) + queue wait (up to 120s when concurrent jobs serialise on a single A10G) + inference (~60s). Those are precisely the conditions under which the client now hangs up first. When it does:

1. the GPU work continues and completes — **we pay for it** — and nobody reads the result;
2. Elixir sees a transport timeout, which #342 classifies as **transient**, so it **retries**;
3. the retry enqueues another cold-start-and-queue cycle behind the same contended GPU.

So the mis-set timeout is a **retry amplifier under exactly the load it was sized for**. It converts "slow" into "slow, three times, at triple the GPU cost".

## User Stories
None directly — protects US-1.1.1 (upload failure UX) and US-1.1.3 (photo → book).

## Goal
One number, derived once, that both sides agree on: the client waits at least as long as the service may legitimately take.

## Scope Check
Two constants and their single source. Small — but do **not** change it before #349 provides real latency data.

## Wiring
Router wiring: none.

## Feature-Completeness Pre-Check
n/a — no new story surface.

## Technical Requirements
1. **Land #349 first and read the p99.** Both current numbers are estimates; the fix should be evidence-led. If p99 is genuinely ~8s as the comment at `prom_ex/plugins/stacks.ex:41` estimates, then *both* 210s and 300s are enormously over-provisioned and the right answer may be to bring both **down**, not to raise the client.
2. **Make the two derive from one source.** #342 set the precedent: three copies of `210_000` became `AIClient.receive_timeout_ms/0` because "three copies of a number that must agree is three chances for it to stop agreeing." The same argument applies across the language boundary — decide how (generated config, a documented single owner, or a startup assertion) and state why.
3. **Assert the invariant, don't just fix the values.** A test or startup check that fails when `client_timeout < modal_timeout` is what stops this recurring. The values will drift again; the invariant should not be re-derivable by hand each time.
4. **Fix the comment.** It currently documents the opposite of what the code does, which is how this survived.
5. **Note the knock-on** to `IdentifyBookJob.worst_case_lifetime_ms/0` — the SSE deadline is derived from this number (#342), so changing it moves the ceiling. Raising the client to ~330s pushes the worst case from ~23 to ~35 minutes; that is an argument for **#351**, not against this fix.

## Reviewer Context
- ⚠️ **Do not "fix" this by shortening the client further.** That deepens the retry amplification. If cost is the concern, the lever is Modal's timeout and concurrency, not the client's patience.
- `AIClient.receive_timeout_ms/0` is already the single Elixir source — three modules bound themselves by it. Do not reintroduce a literal.
- Proto enums are closed types with a build-failing coverage gate; if a new error code is needed for "service still running when we gave up", expect the gate to fail until every consumer handles it.
- Related: **#349** (the data), **#351** (the reader-facing consequence), **#342** (the terminal guarantee and the derivation).
- Commit: agent commits are DENIED. Stage, ONE-LINE message to scratchpad, never push.

## Test Audit
| Layer | Applies? | Verdict |
|-------|----------|---------|
| Contracts | yes | ❌ invariant asserted: client timeout ≥ service timeout, failing when inverted |
| External services | yes | ❌ a call that outlives the client is classified deliberately, not as an anonymous transport error |
| Oban jobs | yes | ❌ `worst_case_lifetime_ms/0` still consistent after the change (#342's test) |
| Others | no | n/a |

## Definition of Done
- [x] The basis is stated and it is NOT #349's p99 — evidence: the client timeout is a *structural backstop* (`@modal_function_timeout_ms 300_000` + `@transport_slack_ms`), documented at length as deliberately not a quantile, because #349's measurement is silent about the timeout condition it would be used to justify cutting. The honest basis, recorded in the module.
- [x] Both sides derive from one source — evidence: `@receive_timeout_ms @modal_function_timeout_ms + @transport_slack_ms`; the Finch call reads `@receive_timeout_ms`, and `modal_function_timeout_ms/0` mirrors `modal_app.py`'s `timeout=300`. One literal, one addition.
- [x] Invariant test that fails when inverted — evidence: `vision_timeout_test.exs` asserts `receive >= modal` and that the slack is derived (>0, >=10s). Probe: setting `@receive_timeout_ms = @modal_function_timeout_ms - 90_000` (the literal inversion this issue is named for) → 2 failures incl. "the receive timeout is at least Modal's own function timeout"; restored → 20/20.
- [x] Comment corrected — evidence: the stale comment now reads that the value is a backstop plus slack, not a quantile (client.ex:126).
- [x] SSE knock-on stated — evidence: the module records the new worst case in `receive_timeout_ms/0`'s docs — the client now outlasts Modal, so the stream ceiling must clear `receive_timeout_ms`, not Modal's 300s alone.
- [x] `staff-review` verdict recorded below

## Dependencies
**Depends on #349** (measure before sizing). Related to **#351**. Needs an owner wave assignment.

## Agent Assignment
elixir-agent + vision/python agent.

## Progress Notes
Filed 2026-07-31 by the lead. Both constants read directly from source; the contradiction is in `client.ex:64`'s own comment.

## Progress Notes (review)
- 2026-08-04: **staff-review: LGTM.** The judgement worth endorsing is the *refusal* to derive the
  timeout from #349's p99 — the module argues, correctly, that a latency measurement taken when
  nothing timed out cannot justify cutting the timeout, and makes the value a structural backstop
  instead. The invariant (`receive >= modal`, from one source) is pinned by a test that the inversion
  probe reddens. Modal's own timeout is mirrored, with a test asserting `modal_app.py` is readable
  from here so the mirror is checkable rather than a number nobody verifies.
