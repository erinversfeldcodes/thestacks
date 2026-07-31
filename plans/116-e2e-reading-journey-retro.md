# Retro — Issue #116: E2E Reading Journey

## What worked well
- **The Feature-Completeness live-drive at planning caught a shipping-blocker no audit had:** the
  `move_book/3` shelf_id defect made the epic's core story silently wrong at the browse layer while
  every formal AC (history/event/audit/ownership) passed. Code-reading and the existing "green"
  move E2E (overlay-text-only assertions) both missed it. The gate's cost (~1 agent-hour) bought
  the single most valuable finding of the epic.
- **Pre-epic sequencing paid off exactly as argued:** #192's mint helper became the backbone of
  every destructive spec (and the Phase-2/3/5 proving drives); #276 landed the capacity semantics
  before the tests that pin them; #278 kept live-drive logs readable and asset watch alive for the
  Elm phase.
- **Audit re-baselining before planning** shrank the 18-item punch list materially (payload cells
  → PayloadContract n/a; #112 had resolved the vacuous-guard item) — phases were scoped against
  reality, not a stale baseline.
- **TC verification with sharp probes** (vacuity of no-op guards, audit count-vs-target, rollback
  seam determinism) upgraded three test sets from plausible to load-bearing.
- **Batched reviewer rounds** (4 reviewers parallel, one batched fix pass, targeted re-review)
  held two revision cycles for the largest phase and zero for three others.

## What caused friction
- **Idle-notification-without-report from teammates** was near-universal (~10 occurrences): every
  agent needed an explicit "submit your completion report" nudge. Cost: one round-trip each.
- **zsh glob aborts** hit the orchestrator twice mid-verification (`echo ===`, `ls issues/${num}-*`)
  despite the documented convention — the pattern recurs under time pressure.
- **The :auth bucket poisoned preview retries:** back-to-back full-suite runs + unmigrated
  registerAndConfirm specs produced rotating failures that took four diagnostic rounds to
  root-cause (now #280). The suite is still competing with itself.
- **`just ci` late surprise:** the semgrep non-literal-RegExp finding surfaced only at the final
  integration gate because per-phase gates run `just verify` (no semgrep). One avoidable loop.
- **Concurrent phases vs shared local resources:** Phase 6's DB reset attempt collided with Phase
  5's live stack (caught, non-destructive fallback used) — parallel phases in one tree need an
  explicit "who owns the dev DB" convention.
- **UX review found the UI shipped unstyled + two a11y P1s** — the implementer treated "tests
  green" as done for a user-facing surface; the styling/a11y bar wasn't in the phase prompt.

## What should change in the agent system
1. **`docs/agents/orchestrator-agent.md` (subagent template):** append to the completion-report
   constraint: "Ending your turn without the completion report is a protocol violation — the
   idle notification is not a report." (Targets the ~10 nudge round-trips.)
2. **`docs/agents/elm-agent.md`:** add a "user-facing surface bar" to the self-review: any new
   visible component ships WITH styles (project palette), programmatic labels, announced errors
   (`role="alert"`), disclosure semantics, and focus management — before requesting review.
   (Targets the Phase-2 ux NEEDS_REVISION.)
3. **`docs/agents/standards/testing.md`:** add the Phase-5 wait-hygiene patterns as canon:
   presence-signal-before-absence, response-registered-before-goto, specific-element-not-count
   assertions for browse listings. (The move bug survived precisely because the old E2E asserted
   overlay text, not listings.)
4. **`justfile` / phase gates:** run the fast semgrep scan in `just verify` (or a `verify-sec`
   recipe the orchestrator runs per phase) so blocking findings surface at the phase, not the
   final `just ci`.
5. **Orchestrator protocol (parallel phases):** when phases share the main tree, declare a
   resource manifest at spawn ("dev DB owner: Phase 5; Phase 6 must run non-destructively") —
   the Phase-5/6 collision was luck-limited.
6. **`docs/agents/testing-coordinator-agent.md`:** encode the two probe patterns that paid off:
   (a) count-assertions must pin the row's target, (b) simulated-effect mirrors don't prove the
   real update — require a paired model assertion.

## Deferred-work ledger (all tracked)
#279 (mart drop-to-zero) · #280 (E2E auth migration + seed guarantees) · #281 (shelving/books
hardening + frontend polish) · #282 (DbtRunner dev path) · #269 (env skips: mail/observability).
