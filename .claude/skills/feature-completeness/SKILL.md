---
name: feature-completeness
description: Before an issue whose job is to validate user stories (E2E / coverage / test-hardening) writes any tests, prove each named user story's happy path is actually BUILT end-to-end in the running app — not just that tests are missing. Answers "is it built?", the gate that must pass before test-audit's "is it tested?". Use at planning time for any E2E/validation issue that names user stories, before authoring tests, or whenever you must decide whether a gap is "test missing, feature exists" vs "feature not implemented".
---

# feature-completeness

The pre-check that #124 lacked. A validation/E2E issue named six user stories, went
GREEN, and yet one of them (US-14.3.2, session expiry & refresh) was never actually
built in that issue — its core behaviour was silently deferred to #173, and the test
audit went green by reclassifying those cells `n/a (see #173)`. That deferred feature,
implemented later without a design pass, then spawned the #178/#179/#180/#182 cascade.

This skill closes that hole. It answers **"is this user story actually built,
end-to-end, in the running app?"** — the question that must pass *before* `test-audit`
answers "is it tested?". "Audit GREEN" must mean *every named story is built and
correct*, not just *everything in the test-only charter is covered*.

## When to use
- Any E2E / test-coverage / validation / test-hardening issue that names user stories
  (the 110–127 family), at **planning time** and **before authoring any test suite**.
- **Any infra / observability / platform / pipeline deliverable — not just named user
  stories.** These have no "user story" but the same failure mode: a metrics/events/
  ingestion pipeline can be fully coded, tests green, and deliver **nothing** end-to-end.
  For these, "built" means a **real signal traverses the whole path and is observed at the
  far end** (a metric emitted → landed in the store → queried back → rendered), *not* that
  the producing code exists. (The #248 lesson: the observability stack shipped blank because
  no sample ever reached the store — invisible to every code-read and synthetic gate.)
- When a `test-audit` cell is about to be classified and you're unsure whether it is
  "test missing, feature exists" (a punch item) or "feature not implemented" (this skill).
- When picking up any issue/epic that *claims* to deliver something you have not confirmed
  works end-to-end with a real signal.

## The pre-check — per named user story
1. **Trace the happy path end-to-end through the real code.** Every hop, with file:line:
   route wired (`router.ex`) → controller/context returns *real* data (not a stub or a
   default-value struct) → any event/job/side-effect the story implies actually fires →
   the frontend decoder/page renders it → the flow is reachable from nav. A story is not
   "built" because the backend exists; it is built when a real user can complete the
   journey the story describes.
2. **Drive it live — reading code is necessary but NOT sufficient.** Use the `run` /
   `verify` skills to exercise the story the way a user reaches it, against a running
   stack (local `just dev`, or a preview). #124's three worst bugs — logout not revoking
   server-side, onboarding not triggering on fresh login, owner role not propagating —
   all passed code-reading and only fell to a live drive. If you cannot drive it, say so;
   a claim of "implemented" with no live observation is at most 🟡.
3. **Assign a verdict:**
   - ✅ **IMPLEMENTED** — happy path exists end-to-end AND was observed working live.
   - 🟡 **PARTIAL** — exists but incomplete: some hop is stubbed, it's wired on only some
     pages/routes, a promised side-effect is missing, or it only works read-only. Enumerate
     *exactly* which hops are missing.
   - ❌ **MISSING** — the core behaviour is not built.

## Resolving anything less than ✅ — NON-NEGOTIABLE
A 🟡/❌ on a **named** story's happy path is a **blocking finding**, not a test-audit
cell. There are exactly two legitimate resolutions — never a silent `n/a (see #NNN)`:

- **(a) Build it in-scope.** Add implementation phases to this issue. For any non-trivial
  feature — auth/session, payments, anything with security or multi-surface/stateful
  behaviour — do a **short design pass FIRST** (a design doc or a `docs/decisions/` record),
  not a "Phase 4 stretch, last, before PR". The #173 refresh work is precisely what a
  skipped design pass costs: the session model (absolute cap, rotation families, reuse
  detection, multi-tab races, in-flight races, mid-compose data loss) was discovered one
  follow-up at a time instead of designed once.
- **(b) De-scope it.** Remove the story from THIS issue's `## Summary` and
  `## User Stories`, and spin it into its own feature issue (`create-issue`). **Editing the
  Summary is mandatory** — an issue may not *claim* a story it is not delivering. The
  spin-out gets its own feature-completeness pre-check when it is worked.

**Forbidden:** writing an E2E/acceptance test against a missing or stubbed feature. It
either fails forever or passes vacuously against the stub — both are worse than an honest
❌. And **forbidden:** reaching GREEN by reclassifying a named story's *core behaviour* to
`n/a`. `n/a` is only ever for a genuinely-not-applicable *layer* of a *built* story
(e.g. "logout emits no events by design"), never for the story's own happy path.

## Output
- A per-US table, embedded under `## Feature-Completeness Pre-Check` in the issue,
  placed **above** the `## Test Audit` (completeness precedes coverage):

  | User Story | Happy-path hops (file:line) | Live-drive result | Verdict | Resolution |
  |-----------|------------------------------|-------------------|---------|------------|

- Add the DoD item: *"Feature-Completeness Pre-Check (above) is ✅ for every named user
  story — each happy path built end-to-end and observed working on a live stack; any
  🟡/❌ story is either built in-scope or de-scoped (Summary edited + spin-out issue). No
  named story reaches GREEN via `n/a (see #NNN)`."*
- Return a concise summary: per-US verdicts, any blocking 🟡/❌, and the recommended
  resolution (in-scope build vs de-scope) for each — not the whole trace.

## Relationship to other skills
- **Runs BEFORE `test-audit`** — "built?" then "tested?". Any `❌ [feature not implemented]`
  a test-audit would otherwise record on a *named* story should already have been caught
  and resolved here; test-audit then only ever sees built features + genuine test gaps.
- Uses **`run` / `verify`** for the mandatory live drive.
- Uses **`create-issue`** for de-scope spin-outs.
- **`verify-and-followup`** handles residual *out-of-scope test* gaps; this skill handles
  *missing features*. Different problems — don't conflate them (that conflation is the bug).

## Scale
Many issues → fan out one agent per issue (independent). Each agent traces + live-drives
its own stories and writes its own `## Feature-Completeness Pre-Check` section. Spot-check
a sample of the cited file:line hops afterward.
