# Issue #NNN: [Title]

## Summary
[1-2 sentence description of what needs to be done.]

## User Stories
[List US-X.Y.Z numbers this relates to, if any. "None" for infra/CI/harness work — but see Test Audit: even story-less work must be validatable.]

## Goal
[What does success look like?]

## Scope Check
<!-- If any of these are true, split the issue before implementation. -->
- Does this issue touch more than 3 controllers? → Split.
- Does this issue add more than 2 new endpoints? → Split.
- Does this issue exceed ~300 lines of production code? → Split.
- Does this issue combine unrelated concerns (e.g. settings + RLS + retrofit)? → Split.

## Wiring
<!-- Every issue must declare whether it includes router/UI wiring. -->
- [ ] This issue includes router wiring and is user-facing when complete.
- [ ] This issue is implementation only. Wired by issue #___.

## Feature-Completeness Pre-Check
<!--
REQUIRED for any issue whose job is to VALIDATE user stories (E2E / coverage /
test-hardening). Run the `feature-completeness` skill BEFORE writing any test suite.
It proves each named user story's happy path is actually BUILT end-to-end — and driven
live — not merely that tests are missing. This is the gate #124 lacked: a validation
issue must not go GREEN while a named story's core behaviour is silently deferred to
another issue (US-14.3.2 → the #173/#178/#179/#180/#182 cascade).

Rule: a 🟡 PARTIAL / ❌ MISSING verdict on a named story's happy path is a BLOCKING
finding, NOT a Test-Audit cell to reclassify `n/a (see #NNN)`. Resolve it exactly one
of two ways — (a) build it in-scope (add implementation phases; a design pass FIRST for
non-trivial features), or (b) de-scope it: delete the story from Summary + User Stories
above and spin out a feature issue. Baseline = "to verify"; fill verdicts + file:line
evidence when the issue is picked up. Delete this whole section only for issues with no
user stories (pure infra/CI/harness — note "n/a — no user stories" and move on).
-->

| User Story | Happy-path hops (file:line) | Live-drive result | Verdict | Resolution |
|-----------|------------------------------|-------------------|---------|------------|
| <one row per named US> | ⬜ to verify | ⬜ to verify | ⬜ | — |

Verdict: ✅ implemented (built end-to-end + observed live) · 🟡 partial (enumerate missing hops) · ❌ missing (build in-scope or de-scope).

## Technical Requirements
[Specific technical details, constraints, architecture references.]

## Reviewer Context
<!-- List non-obvious project conventions that reviewers need to know. -->
<!-- Example: "migration_timestamps config renames inserted_at → created_at globally." -->
[Any global config overrides, unusual patterns, or project conventions relevant to this issue.]

## Test Audit
<!--
Generate this with the `test-audit` skill. It is the pre-implementation BASELINE
(the work queue) and becomes the exit criterion — the issue is Done when it is GREEN.

Every aspect of the system must be validatable and verifiable. Each behaviour in
this issue gets a validation PATH — and where Playwright/browser E2E is the wrong
tool (backend-only behaviour, security invariants, harness/CI changes), that does
NOT excuse skipping validation: specify an acceptance/live-stack test that exercises
the behaviour the way a real user reaches it (see the `write-validation-test` skill).
"Required unless justified": a missing validation path is either a punch-list item
or an explicit `n/a` with a one-line rationale — never a silent gap.

Pick ONE format:

A. COMPACT (harness/CI/single-plug/security-hardening issues — little or no US surface):
   | Layer | Applies? | Verdict |
   |-------|----------|---------|
   | <the one or two layers that apply> | yes | ❌ <what's needed>  (→ ✅ when done) |
   | 1–13 (app/US layers) | no | n/a — <one-line reason> |

B. FULL (feature issues with user stories) — 13 layers × each US, happy/sad columns:
   Legend: ✅ = real coverage | ⚠️ = shallow | ❌ = missing | n/a = not applicable (one-line reason).
   Layers: API calls · auth & middleware guards · DB interactions · event flow/lifecycle ·
   Oban jobs · external service calls · storage · cache · dbt models · Elm state machine ·
   operational metrics · performance & usability · cost tracking.
   Include: framework-layer summary, coverage tally, full per-layer × US tables, a numbered
   punch list (every ❌/⚠️: cell, test needed, which suite/file), and a Verdict line.

Rules (from the test-audit skill — non-negotiable):
- Never invent a test name. Every ✅ cites a real test file + description you verified by grep/Read.
- Distinguish "test missing, feature exists" (punch item) from "feature not implemented" (spin-out issue).
- A NAMED user story's missing/partial happy path is NOT a Test-Audit concern and must NOT be
  reclassified `n/a (see #NNN)` here — it is resolved in the Feature-Completeness Pre-Check above
  (build in-scope or de-scope). `n/a` in this audit is only ever a genuinely-not-applicable *layer*
  of a *built* story, never the story's own core behaviour.
- Layers 11/12 are usually `n/a — covered by SLO gate` (scripts/check-slo-gate.sh).
-->

[Baseline audit table(s) + punch list + Verdict — generated by the `test-audit` skill.]

## Definition of Done
- [ ] [Specific, measurable criterion]
- [ ] [Specific, measurable criterion]
- [ ] **Feature-Completeness Pre-Check (above) is ✅ for every named user story** — each happy path
      built end-to-end and observed working on a live stack; any 🟡/❌ story is either built in-scope
      or de-scoped (Summary edited + spin-out issue). No named story reaches GREEN via `n/a (see #NNN)`.
- [ ] Every behaviour has a validation path — unit/integration where sufficient; an
      acceptance or live-stack test (realistic user behaviour, `TEST_TARGET=deployed`) where
      Playwright/browser E2E is inappropriate; or `n/a` with a one-line rationale.
- [ ] Tests written and passing (`mix test` / `elm-test` / etc. for the touched stacks)
- [ ] Standards compliance verified (`just verify` passes)
- [ ] **Test audit (embedded above) is GREEN** — every applicable cell `✅` or `n/a`-with-rationale;
      0 `❌`, 0 `⚠️`. Regenerate as the final step.
- [ ] **Meets the Completion Bar** (`docs/agents/standards/completion-bar.md`) — all 7 items: every named
      story driven live (local stack, not just unit/code-read); all 13 layers validated (events + metrics
      **asserted**, not assumed); no dangling reviewer findings (P2/P3 fixed or de-scoped to a tracked
      issue); logs clean under the live drive; tracking regenerated to reality; live-driven locally
      before spending on a preview.

## Dependencies
[Other issues or infrastructure that must exist first.]

## Agent Assignment
[Which specialist agent(s) should handle this.]

## Progress Notes
[Updated by agents during execution.]
