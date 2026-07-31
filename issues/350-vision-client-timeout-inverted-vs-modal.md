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
- [ ] #349's p99 cited as the basis for the chosen value — evidence: the number
- [ ] Both sides derive from one source — evidence: diff + stated mechanism
- [ ] Invariant test/startup check that fails when inverted — evidence: probe transcript
- [ ] Comment corrected — evidence: diff
- [ ] Knock-on to the SSE ceiling stated — evidence: the new worst case
- [ ] `staff-review` verdict recorded below

## Dependencies
**Depends on #349** (measure before sizing). Related to **#351**. Needs an owner wave assignment.

## Agent Assignment
elixir-agent + vision/python agent.

## Progress Notes
Filed 2026-07-31 by the lead. Both constants read directly from source; the contradiction is in `client.ex:64`'s own comment.
