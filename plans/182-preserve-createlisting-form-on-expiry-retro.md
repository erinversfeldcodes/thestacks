# Retrospective — Issue #182 (preserve CreateListing draft on expiry + repair the sell-flow)

**Date**: 2026-07-11 · **Agents**: elm-agent (P1, P2b), elixir-agent (P2a) · **Revision cycles**: 1 ux + 1 test-mechanism fix · **Outcome**: gates green (live round-trip passes), ready to merge

## What worked well
- **The live E2E caught a real, pre-existing, user-facing P1 that everything else missed.** The whole
  "Create Listing" UI was broken (form sent an empty `placement_id`; backend wants `book_id`; dropdown
  showed "Untitled"). Unit tests passed, and the marketplace E2E passed — because it POSTs `book_id`
  *directly*, bypassing the form. Only driving the REAL form as a user would exposed it. This is the
  strongest possible vindication of the "every aspect verifiable via realistic user behaviour" stance.
- **Grounded design over the issue's premise.** The issue offered three options; recon proved the target
  scenario is *revocation* (proactive #173 renewal already covers passive expiry), which killed the
  tempting Option 3 (refresh-then-resubmit — a revoked token can't refresh) before any code was written.
- **The cross-user leak guard was designed in from the plan, not bolted on.** userId-stamp-at-save +
  compare-at-hydrate was in the plan and the AskUserQuestion; the reviewer signed it off as airtight.
- **Additive-only proto discipline held.** `book_id=7` / `title=3` with `placement_id` kept+deprecated
  → `buf breaking` clean, `mix proto.sync` idempotent (zero churn — the messages are API DTOs). No
  migration, no schema drift.
- **Distinguishing environmental noise from real failure.** A mid-run network drop produced 19
  cross-spec failures; reading the errors (`ERR_INTERNET_DISCONNECTED`) rather than the pass/fail tally
  correctly classified the run as invalid, and a clean re-run then isolated the ONE real issue.

## What caused friction
- **The E2E 401-trigger mechanism was subtly wrong and only failed live.** Copying the auth.spec
  "poison localStorage" trick missed that those tests *reload* (`page.goto`) so the SPA re-reads the
  poisoned token — whereas an in-session submit uses the *in-memory* token, which localStorage-poison
  doesn't touch. The fix (revoke server-side via `DELETE /api/auth/logout`) is both correct and more
  realistic, but it cost a diagnosis cycle. The unit tests couldn't have caught this (it's a
  Main/Nav/real-HTTP concern).
- **Two long deploy+E2E cycles were spent before the round-trip went green** — one lost to the network
  drop, one to the test-mechanism bug. A cheaper "does the form even submit?" smoke check against the
  preview before the full gate would have surfaced both faster.
- **Recon twice fingered the wrong JS host** (`frontend/index.html` instead of the served
  `apps/core/assets/js/app.js`), nearly leading a reviewer to flag the draft ports as unwired.
- **Scope grew mid-issue.** Folding the sell-flow fix into #182 (user-approved) made it by far the
  largest of the batch, crossing proto + Elixir + Elm + E2E. Correct call for verifiability, but it
  stretched a "frontend-only, <300 LOC" issue well past its Scope Check.

## What should change in the agent system
| File to change | Recommended change | Evidence |
|---|---|---|
| `.claude/skills/write-validation-test/SKILL.md` (E2E section) | Add: to force a 401 on an **in-session** authed action (no reload), REVOKE SERVER-SIDE (`DELETE /api/auth/logout` + the current token) — do NOT poison localStorage, which only takes effect on the next reload (the SPA holds the token in memory). Poison+`page.goto` is only for boot/next-load expiry. | #182's line-84 failure. |
| `docs/agents/orchestrator-agent.md` (2B-iii) | Before the full deploy+E2E gate on a UI-flow change, run a cheap single-spec smoke against the preview first (warm the app, run just the new spec). Catches setup/mechanism bugs in ~1 min instead of a ~15 min full cycle. | Two full cycles burned on a network drop + a test bug. |
| `.claude/skills/*` recon guidance + `docs/agents/elm-agent.md` | Record that the served JS port host is `apps/core/assets/js/app.js` (esbuild, served by Phoenix), NOT the standalone `frontend/index.html` (stale dev build). Recon must check the served build. | Recon mis-identified it twice. |
| `docs/agents/reviewers/*` (or a marketplace note) | The marketplace E2E `createActiveListing` bypasses the UI (direct `book_id` POST) — a "green marketplace E2E" does NOT imply the create-listing FORM works. Flag UI flows that lack a real-form E2E. | The broken sell-flow hid behind a passing API-level E2E. |

## Candidate follow-ups
- **Encoder still emits a deprecated `placement_id: ""`** on every create-listing request (harmless;
  backend ignores it). Clean up once no client references field 1.
- **Preview login-path cold-start 502** keeps surfacing as `auth.setup` flakes (first attempt 502 →
  retry passes). The #175 warmup guard warms `/api/health` but not the first heavy authed login; a
  warm-login step (or a longer setup retry budget) would remove it. (Also noted in #178's retro.)

## Batch position
Follow-up #3 of #178–182 complete (order 181 → 178 → 182 → 179 → 180, per-issue gates). Next: **#179**
(absolute session-lifetime cap + refresh-reuse detection).
