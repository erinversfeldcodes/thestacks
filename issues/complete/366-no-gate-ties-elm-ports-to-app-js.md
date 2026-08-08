# Issue #366: Nothing checks that an Elm port name matches the JS that answers it

## Summary
Found by #362 while wiring the connectivity banner. An Elm port is connected to its JavaScript by a **string name matched at runtime**. Misspell it on either side and `app.ports.<name>` is simply `undefined` — the usual guard shape (`if (app.ports.foo) { … }`) then skips the block **silently**, forever. No compiler error, no test failure, no console warning.

This is the campaign's dominant defect class — *built but not wired* — in a place where nothing is watching. #362 identified it as **the only unprotected hop** in the connectivity chain it had just built: every other link (the port declaration, the `update` branch, the `view` read, the model field) is covered by the type system or a test, and this one is a bare string.

## Why the existing gates do not cover it
- **Elm's compiler** verifies the port's *type*, never that a JS subscriber exists.
- **`elm-test`** cannot reach ports at all — a `Cmd`/`Sub` is opaque, which is the same reason #361 needed `check-session-expiry-coverage.sh` and #362 needed `check-http-timeouts.sh`.
- **The E2E suite** only catches it if a spec happens to exercise that exact port, and a silently-skipped block usually looks like "the feature didn't fire", not like an error.

This project already has three precedents for exactly this shape — a script gate covering a hop no unit test can reach: `check-session-expiry-coverage.sh` (#361), `check-http-timeouts.sh` (#362) and `check-admin-token-routing.sh`. Each was written because a green suite proved nothing about the link in question. This is the fourth.

## User Stories
None — infrastructure correctness. Protects every port-based feature: connectivity, stored auth, the door animation, upload progress.

## Scope Check
One script plus its CI wiring. Single concern. ⚠️ Expect it to find existing mismatches — measure before deciding whether fixing them belongs here.

## Wiring
Router wiring: none. CI gate over the Elm↔JS boundary.

## Technical Requirements
1. **Enumerate both sides and diff them.** Elm `port` declarations in `frontend/src/**` versus `app.ports.<name>` references in `apps/core/assets/**`. Fail on a name that exists on one side only.
2. **Distinguish direction.** An outbound port (Elm → JS, `Cmd`) with no JS subscriber is dead on arrival. An inbound port (JS → Elm, `Sub`) that JS never sends to may be legitimate — a feature awaiting a trigger — so decide per direction and say why rather than flagging both identically.
3. **Fail closed on anything unparseable.** A port declaration the script cannot read must be an error, not a silent skip — that is the exact failure mode being fixed. (#354's classifier is the precedent: `untracked` fails closed.)
4. **Counterfactual acceptance test**, the #330 precedent: rename one side of a live port, show the gate fail; restore, show it pass. Quote both transcripts. Also confirm the Elm suite stays **green** under the mismatch — that contrast is the justification for the gate existing.
5. **Measure existing mismatches** and report the count before fixing any. If there are several, agree the disposition rather than silently absorbing them.

## Reviewer Context
- ⚠️ The guard idiom `if (app.ports.foo)` is *correct defensive JS* — do not remove it. The problem is that it cannot distinguish "this build has no such port" from "I typo'd the name". The gate supplies what the guard cannot.
- ⚠️ **This project has six known gate blind spots** (#337, #354, #356, #365, `check-prose-assertions.sh`'s `ensureViewHasNot`, and the coverage gate counting generated code). When writing a new gate, state plainly what it does **not** cover, so the next person does not read a green run as more than it is.
- Read `scripts/check-session-expiry-coverage.sh` first — it is the best-built gate in this repo: it *discovers* rather than lists, its one exemption is an exemption map rather than a roster, and it prints its reasoning every run.
- Commit: agent commits are DENIED. Stage, ONE-LINE message to scratchpad, never push.

## Test Audit
| Layer | Applies? | Verdict |
|-------|----------|---------|
| CI/gate | yes | ❌ counterfactual: rename one side of a live port → gate fails, Elm suite stays green |
| CI/gate | yes | ❌ unparseable declaration fails closed, not skipped |
| Regression | yes | ❌ a clean tree passes; existing mismatches counted and dispositioned |
| Others | no | n/a |

## Definition of Done
- [ ] Both sides enumerated and diffed — evidence: diff
- [ ] Direction handled deliberately, with reasoning — evidence: the decision
- [ ] Fails closed on unparseable input — evidence: probe
- [ ] Counterfactual red + Elm suite green under the same mismatch — evidence: both transcripts
- [ ] Existing mismatch count reported and dispositioned — evidence: the number
- [ ] `staff-review` verdict recorded below

## Dependencies
Surfaced by **#362**. Same family as **#361** and **#362**'s own gates. Needs an owner wave assignment — Wave 11 sits beside the other gate work (#336, #337), though this one protects features shipping sooner.

## Agent Assignment
elm-agent / devops.

## Progress Notes
Filed 2026-08-01 by the lead from #362's finding 1. #362 built the connectivity chain and observed that every hop but this one is covered — the port name is the single link where a typo produces silence rather than a failure.
