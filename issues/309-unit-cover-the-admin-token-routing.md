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
- [ ] A test failing on the reintroduced defect — evidence: `adminToken = Nothing` at
      `Main.elm:2060` → named test fails; reverted → 1285+ green
- [ ] `initPage` and `update` cannot disagree about which token to use — evidence: a shared
      resolver, or a test covering both entry points
- [ ] `e2e/tests/admin-session.spec.ts` untouched and still passing
- [ ] `just run just verify` passes
- [ ] `gdpr-review`: n/a — no personal data; token routing only. Stated, not skipped.

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
