# Issue #207: Retro tracking reconciliation (#121/#124 families to shipped reality)

## Summary
Completion-bar item 5 requires tracking to reflect reality. The #124 embedded Test Audit and several DoDs across the #124 and #121 families still describe pre-implementation state — including a shipped story greened via `n/a — not implemented`. Reconcile all of it to shipped code. **Docs/tracking only — no code changes.**

## User Stories
None (tracking reconciliation). Note US-14.3.2 is the story mis-tracked as unimplemented.

## Goal
No shipped story greens via `n/a`; every reconciled issue's DoD, audit, and completion-bar line match the code that actually shipped.

## Scope Check
- Touches 0 controllers/endpoints/production code. OK — issue-file edits only.
- Under 300 LOC of prod code (zero). OK.
- Single concern (tracking reconciliation). OK.

## Wiring
- [ ] This issue includes router wiring and is user-facing when complete.
- [x] This issue is implementation only (tracking/docs — no wiring).

## Feature-Completeness Pre-Check
n/a — no user stories; this issue reconciles tracking, it does not build features. (The features it re-tracks are already shipped and verified elsewhere.)

## Technical Requirements
- **(a) Regenerate #124's embedded Test Audit** so US-14.3.2 is no longer `n/a — not implemented`: the session-expiry E2E ships and is driven live (`e2e/tests/auth.spec.ts:165-297` — three "Session expiry" tests covering the interceptor, a #178-covered page, and the boot-hook path). Remove the `n/a (see #173)` layer-table reclassifications that hid the shipped behaviour.
- **(b) Backfill DoD checkboxes to shipped state** on #124, #178, #179, #180, #181, #182 and #121, #184, #185, #186, #187, #188, #189.
- **(c) Add the "Meets the Completion Bar" DoD line** (`docs/agents/standards/completion-bar.md`, all 7 items) to each of those issues that lacks it.
- **(d) Fix #124 §1 prose:** onboarding is the shipped **4-step** overlay (Welcome → AgeVerification → Privacy → Complete), not 3-step.
- Verify each backfilled checkbox against real tests/code before ticking (no ticking on assumption) — a green DoD on unshipped work is itself a completion defect.

## Reviewer Context
- Rule: a NAMED story's shipped happy path must NOT stay `n/a (see #NNN)` in an audit — that pattern is only for genuinely-not-applicable layers of a built story. US-14.3.2 is the exact anti-pattern this issue removes.
- Onboarding overlay steps are Welcome → AgeVerification → Privacy → Complete (4), confirmed by the shipped flow — do not re-introduce the 3-step description.
- Use `mcp__project-tools__update_progress` / issue tooling rather than hand-editing where applicable.

## Test Audit
| Layer | Applies? | Verdict |
|-------|----------|---------|
| tracking accuracy (audits/DoDs match shipped code) | yes | ❌ stale (US-14.3.2 `n/a`, unchecked DoDs, 3-step prose) → ✅ reconciled |
| 1–13 app layers | no | n/a — tracking/docs issue, no runtime behaviour |

Punch list:
1. #124 Test Audit regenerated; US-14.3.2 GREEN via `auth.spec.ts:165-297`; `n/a (see #173)` reclassifications removed.
2. DoD checkboxes backfilled on the #124 family (124/178/179/180/181/182) and #121 family (121/184–189).
3. Completion-bar DoD line added to each.
4. #124 §1 onboarding corrected to 4-step.

Verdict: ❌ until tracking matches shipped code and no shipped story greens via `n/a`.

## Definition of Done
- [ ] #124 Test Audit regenerated; US-14.3.2 no longer `n/a — not implemented`; cites `auth.spec.ts:165-297`.
- [ ] `n/a (see #173)` layer-table reclassifications removed from #124.
- [ ] DoD checkboxes backfilled to shipped state on #124/#178/#179/#180/#181/#182 and #121/#184–#189 (each verified against code/tests).
- [ ] "Meets the Completion Bar" DoD line present on each of those issues.
- [ ] #124 §1 onboarding prose corrected to the 4-step overlay.
- [ ] No shipped story greens via `n/a`.
- [ ] Standards compliance verified (`just verify` passes — docs-only, still run).
- [ ] **Test audit (above) is GREEN** — 0 ❌, 0 ⚠️.
- [ ] **Meets the Completion Bar** (`docs/agents/standards/completion-bar.md`) — all 7 items (tracking regenerated to reality).

## Dependencies
#124 + #178–#182 (auth family), #121 + #184–#189 (GDPR family) — all shipped. #204/#206 close the live-drive/metrics gaps this issue references.

## Agent Assignment
docs.

## Progress Notes
_none yet._
