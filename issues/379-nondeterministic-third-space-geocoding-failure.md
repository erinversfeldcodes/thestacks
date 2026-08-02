# Issue #379: A third-space test fails in the full suite, passes in isolation, and does not reproduce at its own seed

## Summary
Found by the Wave 7 integration gate, 2026-08-02. `just run just ci` on `feat/campaign-w7-317`, on a
**quiet machine with no concurrent agents**, produced exactly one Elixir failure out of 3506:

```
1) test geocoding at approval a space that cannot be geocoded is still created, unpositioned
   (Stacks.DiscoveryThirdSpaceProductionTest)
   apps/core/test/stacks/discovery_third_space_production_test.exs:132
   Expected truthy, got false
   code: assert is_nil(space.latitude)
```

The test approves a source for which **no** geocoder response is registered, and asserts the space is
created unpositioned. It got a space **with coordinates**.

## What has been ruled out — do not redo this work
| Hypothesis | Check | Result |
|---|---|---|
| Machine contention (the Wave 7 agents' usual explanation) | `pgrep` before the run; tree quiet | **Not it** — uncontended |
| A defect in that file | `mix test <file>` in isolation | **Not it** — 17 tests, 0 failures |
| Deterministic test-order dependence | full suite re-run at the **same seed** `268546080243028` | **Not it** — 3506 tests, **0 failures** |
| The mock inventing coordinates | read `Stacks.Geocoding.Mock` | **Not it** — unmatched queries return `{:error, :not_found}` **by design**, documented: *"A mock that invented coordinates would make every test look like geocoding succeeded"* |
| Mock state leaking via a shared geocoder process | `Geocoding.geocode/1` is called **inline** at `discovery.ex:464` | **Not it** — no Task/job indirection, so the process dictionary *is* the test process |

⚠️ **`--seed` fixes ordering but not concurrency.** It does not control which `async: true` tests run
simultaneously, on which schedulers, or how they interleave. A race therefore survives a same-seed
re-run — which is consistent with everything above and is the leading remaining explanation.

## Where to look next
The mock is process-local and defaults to failure, and the geocode call is inline — so the coordinates
did not come from the mock in this test's process. That leaves the **database**: `spaces()` returned
exactly one row (the `[space] =` match succeeded) and that row was positioned.

1. **Is this test's own space the one being returned?** If another test's positioned third space is
   visible here, the failure is a sandbox/visibility leak, not a geocoding bug. ⚠️ Assert on the
   space's id or name, not just its shape — `[space] =` cannot tell you *whose* space it is, which is
   why the failure message is about latitude rather than about identity.
2. **Check `async:` and Ecto sandbox mode** across the third-space tests and anything else writing
   `op.third_spaces`. A test running `async: false` in `:shared` mode concurrently with an `async: true`
   test is the classic source of exactly this nondeterminism.
3. **Consider whether `spaces()` should be scoped.** A helper that queries the whole table is only safe
   under perfect isolation, and it fails in the least legible way when isolation slips.

## Why it matters more than one flaky test
This project's stated rule is that a flaky test is never dismissed as "not ours". It also has an active
finding (**#377**) that a *different* suite failure was a live network call hiding behind a mock — found
only because someone chased it instead of re-running. ⚠️ **A one-in-N failure in the integration gate is
the gate working.** Leaving it unexplained trains people to re-run until green, which is how #377 sat
undiagnosed.

## User Stories
None — test-suite integrity / third-space production path (US-3.1.1 family).

## Scope Check
Investigation first. Likely one helper or one `async:`/sandbox declaration. If it turns out to be a
production-path race rather than a test-isolation one, re-scope and say so.

## Technical Requirements
1. **Reproduce it deterministically before fixing it.** ⚠️ Do not "fix" it by adding a
   `MockGeocoder.clear()` or scoping `spaces()` until you can make it fail on demand — otherwise you
   cannot tell whether the fix worked or the race simply did not fire. Running the suite N times and
   seeing green is not proof.
2. **Establish which space is being returned** (id/name), which answers test-isolation vs geocoding.
3. **Fix the isolation, then prove it** — the same repro must now pass, and the mechanism must be
   named in the diff.
4. **Sweep for siblings.** If a sandbox mode or a global query helper is the cause, it is unlikely to
   affect only this test. Report the count.

## Reviewer Context
- ⚠️ **`Stacks.Geocoding.Mock` is not the defect** — it is well built, and its default-to-failure
  design is deliberate and documented. Do not "harden" it into inventing coordinates or silently
  clearing state; that would destroy the unpositioned-space path this very test protects.
- The unpositioned-space behaviour is a real product decision (`discovery.ex:402`): *"A space that
  cannot be geocoded is still created, with null coordinates"* — because losing an owner's approval to
  a third-party geocoder's miss would silently discard a human decision. Keep it.
- Related: **#377** (a suite failure that turned out to be a live network call behind a mock) — same
  posture, different cause.
- Commit: agent commits are DENIED. Stage, ONE-LINE message to scratchpad, never push.

## Test Audit
| Layer | Applies? | Verdict |
|-------|----------|---------|
| Elixir | yes | ❌ deterministic reproduction exists before any fix |
| Elixir | yes | ❌ the returned space is asserted by identity, not just shape |
| Elixir | yes | ❌ isolation fixed; the repro passes; mechanism named |
| Sweep | yes | ❌ count of sibling tests sharing the cause reported |

## Definition of Done
- [ ] Deterministic repro — evidence: the command and its failing output
- [ ] Space identity asserted; isolation-vs-geocoding answered — evidence: the finding
- [ ] Fixed, with the mechanism named — evidence: diff + the repro now passing
- [ ] Sibling sweep count — evidence: the number
- [ ] `staff-review` verdict recorded below

## Dependencies
Found by the Wave 7 integration gate. Independent of Wave 7's changes — nothing in #340/#349/#350/
#351/#352/#373/#374/#375/#376 touches `Stacks.Discovery` or the geocoder. ⚠️ It makes `just ci`
intermittently red, so it belongs before the campaign's remaining gates.

## Agent Assignment
elixir-agent.

## Progress Notes
Filed 2026-08-02 by the lead. Every rule-out in the table above was executed, not assumed: the
uncontended full run (1 failure), the isolated file run (17/0), the same-seed full re-run
(3506/0, seed `268546080243028`), and reads of `test/support/mocks/geocoding/mock.ex` and
`lib/stacks/discovery.ex:464`.
