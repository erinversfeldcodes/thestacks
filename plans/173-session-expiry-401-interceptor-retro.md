# Retrospective — Issue #173 (session-expiry 401 interceptor + token refresh)

**Date**: 2026-07-10 · **Agents**: elixir-agent (P1), elm-agent (P2) · **Revision cycles**: 1 · **Outcome**: merged into `feat/124-e2e-auth` (epic complete)

## What worked well
- **Phase 1 as a clean contract anchor.** Building the refresh endpoint first, and having the
  contract-reviewer confirm its 200 body is byte-identical to login, meant Phase 2 reused
  `authResponseDecoder` with zero changes — the cross-phase handoff held with no rework.
- **The nested-TEA `OutMsg` channel was the right seam.** Once research found the per-page OutMsg +
  single `Main.sessionExpired` pattern, the interceptor was idiomatic and DRY (one handler, mirrors
  logout). Options B (57 Expect wrappers) and C (global-effect refactor) were correctly rejected.
- **The elm-agent surfaced the untestable-Main constraint honestly** rather than faking coverage —
  and adapted: page-seam RED, a pure `renewAuthToken` unit test, the Login view seam, and the live
  E2E as the redirect proof. The 2B-iii E2E ("Session expiry" redirect, 8.8s) was the load-bearing
  verification and it passed on real Fly.
- **The PE gate earned its keep on a security feature.** It confirmed the backend pipeline is the
  real gate (so partial page coverage is UX-only, not a bypass), verified rotation fails closed and
  interacts cleanly with #124 A2 + #174, and found the free boot-time `GotPlacementCheck` coverage
  win — turning a fuzzy "is this safe?" into precise, evidenced answers.
- **Reviews caught a real gap, not a nit.** The ux-reviewer found the expiry notice had NO CSS (it
  rendered as unstyled text), which quietly failed the DoD's "visually distinct" intent — a genuine
  find dressed as polish.

## What caused friction
- **The scope was mis-estimated up front — "all authed pages" was 2x bigger than assumed.** Planning
  said ~13 pages; the reality was 8 pages with an OutMsg channel + 11 without one that need a
  3-tuple conversion. This only became visible after the code was written, forcing a mid-flight
  human decision (ship 8 + renewal, file #178). The issue's own Scope Check ("< 300 LOC, no split")
  was optimistic for a cross-cutting interceptor over a heterogeneous page set.
- **Elm test-first is structurally limited for `Browser.application`.** The Main-level end-state and
  the timer-driven renewal couldn't be pre-written as failing tests (referencing not-yet-existing
  constructors = compile errors, not valid RED). Test-first degraded to page-seam RED + test-alongside
  for the seams the implementation had to expose.
- **Including the refresh stretch + the interceptor + renewal in one issue made it the largest of the
  epic** — a ~270k-token Phase 2 implementation. Cohesive, but big.

## What should change in the agent system
| File to change | Recommended change | Evidence |
|---|---|---|
| `docs/agents/orchestrator-agent.md` (Phase 1 / scoping) | For cross-cutting frontend interceptors, spend a research pass mapping the *dispatch/channel* topology (which pages have OutMsg vs 2-tuple) BEFORE estimating scope — the "all pages" cost depends on it. Don't trust the issue's own LOC estimate for cross-cutting UI changes. | #173's 8-vs-19-page surprise mid-flight. |
| `.claude/skills/write-validation-test/SKILL.md` (or elm-agent) | Add an Elm note: `Browser.application` Main isn't program-testable (real Nav.Key + opaque Cmd + NoUnused.Exports); for Main-level behaviour, extract pure key-free helpers (like `renewAuthToken`) + cover the end-state with E2E — don't force a compile-error "RED". | The Main.sessionExpired testability constraint. |
| `docs/agents/reviewers/ux-reviewer.md` | Keep the "is the styled state actually implemented?" check explicit — a notice can exist in the DOM (passes functional tests) yet be unstyled (fails the visual-distinctness intent). | The missing `.login-card__notice` CSS. |
| `docs/agents/elm-agent.md` | When adding a cross-page signal, check for pages WITHOUT the shared channel up front and flag the conversion cost in the completion report's Pre-implementation Flags (this was flagged, but late). | The 11 OutMsg-less pages. |

## Candidate follow-ups (filed)
- #178 (coverage + boot-time hook), #179 (session cap / reuse detection, P2), #180 (multi-tab race),
  #181 (revoke-failure metric), #182 (CreateListing form-loss). All non-blocking; carried to the backlog.
