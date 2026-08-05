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
- [x] Deterministic repro — evidence: the command and its failing output
- [x] Space identity asserted; isolation-vs-geocoding answered — evidence: the finding
- [x] Fixed, with the mechanism named — evidence: diff + the repro now passing
- [x] Sibling sweep count — evidence: the number
- [x] `staff-review` verdict recorded below

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

## 2026-08-03 — mechanism located, repro still needed
The lead carried the investigation further. Three concrete facts, each read from source:

1. **`Core.DataCase` puts the repo into SHARED sandbox mode for every non-async test**
   (`apps/core/test/support/data_case.ex:31`):
   ```elixir
   pid = Sandbox.start_owner!(Core.Repo, shared: not tags[:async])
   ```
   Ecto documents shared mode as unsafe alongside async tests: the shared connection serves any
   process without its own checkout. ⚠️ This is suite-wide, not specific to this test.
2. **`spaces/0` is unscoped** — `Repo.all(ThirdSpace)` over the whole table
   (`discovery_third_space_production_test.exs:51`). It cannot tell its own row from anyone else's,
   which is why the failure surfaced as "wrong latitude" rather than "wrong space".
3. **Every test in the file uses the same name.** `pending_source/1` defaults to
   `name: "The Reading Room"` (`:41`), and sibling tests register exactly that string with
   `MockGeocoder.put_point("The Reading Room", …)`. The mock matches by `String.contains?`, so ANY
   leaked registration or row for that name positions this test's space.

**Named suspect:** `geocode_bookstores_job_test.exs` is the only `async: false` file among those
touching third spaces / the geocoder — so it is the one that runs in shared mode.

⚠️ **Caveat on that suspect, stated so the next person does not waste a day:** ExUnit normally runs
`async: true` modules concurrently and `async: false` modules serially *afterwards*, which would mean
no overlap and would sink this theory. **Verify the actual interleaving before building on it** —
`--trace` or a timestamped `setup` hook will show whether the two ever overlap in practice.

### The concrete path to closing this
1. **Make `spaces/0` assert identity, not shape** — scope it to the source/name under test, or assert
   the returned row's id. Do this first: it converts an unexplained latitude into a named row, which
   answers isolation-vs-geocoding immediately and is worth doing on its own merits.
2. **Log the interleaving** — a `setup` that records module + timestamp, then run the full suite until
   it fails and read whether a shared-mode module was live at that moment.
3. **Only then fix.** ⚠️ Still do not add `MockGeocoder.clear()` or scope the query as *the fix* before
   a deterministic repro exists — with a one-in-N failure you cannot distinguish a fix from a race
   that did not fire.

## 2026-08-03 — RESOLVED. It was a live network call, not a sandbox leak.

**The leading theory was wrong, and the caveat about it was right.** Ecto shared-mode never came
into it, and the named suspect (`geocode_bookstores_job_test.exs`, `async: false`) is innocent — it
runs in the sync phase and cannot overlap. The actual partner is **`discovery_removal_review_test.exs`,
an `async: true` file the investigation never named.**

### Mechanism
`:core, :geocoder` was **unset in `apps/core/config/test.exs`** — the only outbound seam missing from a
list that already mocks `:vision_client`, `:isbn_http_client`, `:scraper_client`, `:brave_client`,
`:searxng_client`, `:together_client`, `:rss_fetcher`, `:storage`, `:dbt_runner` and
`:transparency_prometheus_client`. So `Geocoding.provider/0` fell back to **`Stacks.Geocoding.Nominatim`
— a live Finch request to the public `nominatim.openstreetmap.org`**.

Four test files supplied the key themselves and restored it asymmetrically:

```elixir
if original, do: Application.put_env(...), else: Application.delete_env(:core, :geocoder)
```

Whichever async module's `setup` ran first saw `original == nil`, so **its `on_exit` deleted the key**
— globally — while the *other* `async: true` module's test was mid-flight. That test's `approve_source`
then geocoded against the real internet, which returned real coordinates for "The Reading Room"
(51.4333326, -1.4528617 — a real reading room in Berkshire, UK), and `assert is_nil(space.latitude)`
failed. Same class as **#377**.

### Reproduction (both deterministic)
1. **Mechanism, 1/1:** a probe that deletes the key mid-test — exactly what the sibling's `on_exit`
   does — printed `Geocoding.geocode/1 -> {:ok, %{latitude: 51.4333326, longitude: -1.4528617}}` and
   failed on the issue's exact assertion.
2. **The real race, 1-in-10:** the two `async: true` files run together with a 800 ms window widening
   the gap between `setup` and the geocode call reproduced the issue's **verbatim** failure, with the
   smoking gun on the same line: `env at geocode time = nil`.

### Fix
One line, at the seam, in the place the project already establishes as the pattern:
`config :core, :geocoder, Stacks.Geocoding.Mock` in `apps/core/config/test.exs`. This makes the mock
the floor, so no test can reach the live service by omission — and it kills the race **by
construction**, not by coincidence: `original` is now always truthy, so the `delete_env` branch is
unreachable. Same repro: 10/10 green, env never `nil` again.

Also: `spaces/0` is now `spaces/1`, scoped by `website_url` (the key production's `space_exists?/1`
uses as business identity). This answered isolation-vs-geocoding immediately — **the row was always
this test's own**; nothing leaked. And a regression gate in `geocoding_test.exs` fails if the config
line is ever removed.

### Sibling sweep
Over all 48 test files that mutate a global `:core` app-env key: on the criterion that actually made
#379 reachable — *no config default + two or more concurrently-running `async: true` mutators* —
`:geocoder` was the **only** key in the suite. Count now **0**.
On the looser structural criterion (*no config default + ≥2 mutators + ≥1 async + `delete_env`
restore*) **1** remains: **`:public_shelf_cap`** (`profile_controller_test.exs` `async: true` +
`discovery_telemetry_test.exs` `async: false`). Not reachable today for the same reason the original
suspect was innocent — only one of the two is async — but it becomes live the moment someone flips
that file to `async: true`. Left unfixed under scope lock; worth its own one-line issue.
Corroboration: `:isbn_http_client` has **2** async mutators and would be the identical bug — it is
safe only because it *is* configured. The geocoder was simply missed.

## Progress Notes (review)
- 2026-08-04: **staff-review: LGTM.** The fix is the right *kind*: a config floor in `test.exs` rather
  than repairing the four `put_env`/`delete_env` dances — the race was global state shared by
  `async: true` modules, and any per-test fix leaves the next module free to reintroduce it. The floor
  makes the mock the default no test can fall below by omission, and the guard test asserts the floor
  itself, so removing it fails loudly ("the :test geocoder is nil — tests would hit the live Nominatim
  service") instead of resurfacing as a once-a-week geocoding flake. Probed: deleting the config line →
  exactly 1 failure with that message; restored → 12/12. The diff also converts the four self-supplying
  test files to rely on the floor, which is what actually removes the race rather than papering it.

