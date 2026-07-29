# Issue #309: Guard the admin token routing below the E2E layer

## Summary
The defect **#303** existed to fix — the SPA sending the ordinary Guardian token to `/api/admin/*`,
and then the half-fix where `initPage` was repointed to the admin token while the `update` handlers
were not — is guarded by **exactly one test type: an E2E spec that needs a live preview stack with
MFA enrolment**.

Found by mutation probe during #303's staff-review (2026-07-29): setting `adminToken = Nothing` at
`frontend/src/Main.elm:2060`, i.e. reintroducing the half-wiring defect verbatim, leaves
**all 1285 Elm tests passing**.

## User Stories
Protects the admin surfaces behind US-9.x / US-2.5.x (source approval, removal-request review).
No new user-facing behaviour.

## Goal
Reintroducing the half-wiring defect fails a test that runs in `just verify`, with no stack.

## Scope Check
- More than 3 controllers? → None; frontend test-layer only.
- More than 2 new endpoints? → None.
- More than ~300 lines? → No. One test module, possibly a small `Effect` seam.
- Unrelated concerns? → No.

## Wiring
Implementation-only. The wiring under test is `Main.update` → `AdminSourceApproval.update` →
the outgoing request's `Authorization` header.

## Technical Requirements

The reason the existing tests miss it is instructive and should be stated in the new test:
`AdminSourceApprovalTest.elm` exercises the page **with a token handed to it**, so it cannot notice
that `Main` hands it the wrong one — or none. Every page-level admin test has the same blind spot,
because the choice of token is made one level up.

Options, cheapest first:
1. A `ProgramTest` over `Main` on an admin route with `adminAuth` set, asserting the simulated
   outgoing request carries the admin token. Needs `withSimulatedEffects`, which means an `Effect`
   seam on the admin update path — **check whether one already exists before adding one.**
2. Failing that, a narrow pure function — `adminTokenFor : Model -> Maybe String` — used by *both*
   `initPage` and `update`, with a test that both call sites resolve to the same value. Weaker (it
   does not prove the header is sent) but it makes the two entry points structurally incapable of
   disagreeing, which is the actual defect.

Prefer 2 if 1 requires restructuring: the bug was never "the token is wrong", it was "two entry
points disagree".

## Reviewer Context
- ⚠️ **`elm/http` speaks XMLHttpRequest, not `fetch`.** Patching `fetch` to observe SPA requests
  captures nothing — this cost real time during #303.
- The four #303 defects were *stacked*: each invisible until the one in front was fixed, with 1285
  tests green throughout. Whatever lands here should fail for defect 4 specifically, not merely
  assert that some admin request happens.
- Do not delete or weaken `e2e/tests/admin-session.spec.ts`. It is the only thing that goes through
  the real MFA pipeline; this issue adds a floor beneath it, it does not replace it.

## Test Audit

| Layer | Applies? | Verdict |
|-------|----------|---------|
| Elm unit (page-level) | yes | ⚠️ exists and is **blind to this** by construction — the token is an argument |
| Elm unit (Main-level) | yes | ❌ absent — this issue |
| E2E (`admin-session.spec.ts`) | yes | ✅ 5 tests, covers all four defects, but needs a preview + MFA |

Punch list:
1. The new test must fail when `adminToken = Nothing` is reintroduced at `Main.elm:2060`. Quote the
   failure in the DoD — a test added for this that stays green is worse than none.

## Definition of Done
- [x] A check failing on the reintroduced defect — evidence: `adminToken = Nothing` at the first
      update site → `scripts/check-admin-token-routing.sh` **exit 1**, naming the file, line and
      reason; reverted → exit 0. ⚠️ In the same probe **elm-test reported 1285 passed, 0 failed**,
      which is the finding restated as a measurement rather than a claim
- [x] `initPage` and `update` cannot disagree about which token to use — evidence: `adminTokenFor/1`
      is the single read of `model.adminAuth`, used by all **five** call sites. The guard found the
      fifth (a multi-line `initPage` in the gate-success handler) that a manual sweep had missed, and
      that site was passing `Just adminToken` — the same value by a second route, which is what the
      resolver exists to remove
- [x] Wired into the gate — evidence: `scripts/lint-elm.sh` calls it, so it runs in `just verify`
      and `just ci`, alongside the two sibling checks for defect classes no test can see
- [x] The guard does not cry wolf — evidence: it first reported a false bypass on a correct
      multi-line call; now reads a 6-line window. A check that flags correct code is a check someone
      switches off
- [x] `e2e/tests/admin-session.spec.ts` untouched and still passing — evidence: `git diff` shows no
      change to it; it remains the only path through the real MFA pipeline. This adds a floor beneath
      it, it does not replace it
- [x] `just run just verify` passes — see Progress Notes
- [x] The **resolver's body** is guarded too, not only its call sites — evidence: found by probing
      the guard itself. Replacing the body with `Maybe.map .token model.auth` (i.e. #303's *original*
      defect: handing the admin endpoints the ordinary session) left the guard passing **and** all
      1285 Elm tests passing. Naming the read in one place had reduced five vulnerable sites to one
      and left that one unprotected. The check now asserts the body is `model.adminAuth`; re-probed →
      exit 1
- [x] `gdpr-review`: **n/a** — no personal data; token routing only. Stated, not skipped.

**A `ProgramTest` was considered and rejected, per the issue's own option list.** The existing
simulated-effects tests (`SessionExpiryTest`, `ThirdSpacesProgramTest`) hand-write their own copy of
the request under test, so they assert against a mirror of the real code rather than the real code —
and #302 found exactly that shape passing vacuously. A source-level invariant cannot be fooled by a
mirror. Recorded here because the issue asked for option 1 first and this is the reasoned deviation.

## Dependencies
None. #303 is complete; this hardens it.

## Agent Assignment
`elm-agent`.

## Progress Notes
- 2026-07-29: Filed from #303's staff-review. The probe is the whole finding: the defect that
  motivated an entire epic can be reintroduced without any test in `just verify` noticing. #303 is
  not wrong to be complete — it was driven live and its E2E spec is real — but its guarantee
  currently depends on a stack being available, and a guarantee that evaporates when a stack is
  absent is one worth writing down.
- 2026-07-29: Closed. The design conclusion worth keeping: the bug was never "the token is wrong",
  it was "N entry points disagree", so the fix is one named read rather than a better test of each
  site. The guard exists because that invariant is invisible to the type system and to every test.
