# Retrospective — Issue #178 (session-expiry interceptor: remaining pages + boot hook)

**Date**: 2026-07-11 · **Agent**: elm-agent (2 phases) · **Revision cycles**: 0 · **Outcome**: gates green (199 E2E passed), ready to merge into `feat/124-e2e-auth`

## What worked well
- **Grounding scope in a real topology map before planning paid off directly.** The #173 retro's
  lesson ("don't trust the issue's LOC estimate for a cross-cutting interceptor; map the dispatch
  topology first") was applied: a read-only recon pass confirmed all 11 pages make a token-required,
  401-capable request (0 no-ops) and pinned each page's `update` signature, authed recv-Msg, and Main
  wiring line. The two implementation agents then had zero discovery to do — 0 revision cycles, no
  mid-flight surprises (the exact failure mode #173 hit).
- **Splitting 11 pages into 2 focused passes kept each agent sharp.** Phase 1 (6 pages + boot hook)
  established the pattern; Phase 2 (5 pages) reused it verbatim. Neither pass hit the context-dilution
  the #173 8-page single pass warned about, and the shared seam-test file accumulated cleanly.
- **The template was genuinely mechanical, and the agents respected it.** Both correctly handled the
  one non-leaf case (SourceApproval's `handleActionResult` helper) by converting the helper rather than
  guessing, and correctly left Catalogue's *public* `getCatalogue` branch local — with a guard test
  that proves the exclusion is deliberate, not an oversight.
- **Chasing the reviewer's boot-hook test-gap nit was the right call.** The boot hook is Main-level
  (untestable by unit), so its only honest coverage is E2E. Adding a dedicated boot-path E2E (`/` with
  a poisoned token, redirect with no click) turned "trust the code" into a live proof — matching the
  user's "everything verifiable" philosophy. The agent's route choice (Home, whose page init is
  `Cmd.none`) made the redirect unambiguously attributable to the boot hook, not a page action.
- **Test non-vacuity was cheap here because RED was compile-level.** Referencing a not-yet-existing
  `SessionExpired` constructor is a genuine compile failure, and the paired `*_non401_stays_local`
  tests pin the other direction — over-routing would fail them. Both directions covered per page.

## What caused friction
- **Almost none — this was a well-understood mechanical extension.** The only real judgment calls
  (Blog optional-auth 401 routing; the Catalogue public exclusion) were surfaced at plan time and
  decided before implementation, so nothing churned.
- **One intended semantics change slipped in quietly** (`Catalogue.UserPlacementsLoaded` 401 no longer
  degrades to `Success []`). It's correct — an authed request's 401 *should* expire the session — but
  it's the kind of behaviour change a purely mechanical "add NoOut" framing could have hidden. The
  reviewer caught and confirmed it; worth noting that "mechanical" refactors can still shift behaviour
  at the branch that previously swallowed the error.

## What should change in the agent system
| File to change | Recommended change | Evidence |
|---|---|---|
| `docs/agents/elm-agent.md` (or the conversion playbook) | When converting an `Err _ ->` branch that previously *swallowed* an error into a routed one, explicitly call out in the report any case where the prior code masked a 401 as success/empty (e.g. `Success []`) — that's a real semantics change, not a pure `NoOut` add. | Catalogue's `UserPlacementsLoaded` degrade-to-`Success []`. |
| `scripts/test-e2e.sh` / vision preview warmup | The `upload.spec.ts:12` barcode-OCR test flakes on vision-service cold start (2× ~2m timeout, passed on retry). Mirror the #175 preview warmup guard for the **vision sidecar** (warm `/classify`+`/extract` before the upload specs) or raise the first-attempt timeout. File as its own issue. | This run's 1 flaky; `project_vision_stack_dfef1333_baseline` notes vision cold-start cost. |
| `docs/agents/orchestrator-agent.md` (scoping) | Reinforce (now with a second data point) that a topology-recon pass before planning a cross-cutting frontend change is worth it — #178 went 0-cycle where #173 (no recon) surprised mid-flight. | #178 vs #173 outcome delta. |

## Candidate follow-up (not filed)
- **OCR barcode E2E flake** — vision cold-start; own issue (warmup guard or timeout bump). Out of #178
  scope.

## Batch position
Follow-up #2 of #178–182 complete (order 181 → 178 → 182 → 179 → 180, per-issue gates). Next: **#182**
(preserve CreateListing form on expiry).
