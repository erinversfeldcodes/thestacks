# Issue #182: Preserve an in-progress listing when the session expires mid-compose

## Summary
When a session expires (or is revoked) while a user is composing a marketplace listing, #173's global
interceptor redirects to `/login` and the in-progress `CreateListing` form is **silently lost** — no
draft, no "your work couldn't be saved" acknowledgment. `CreateListing` is the worst-case interruption
in the interceptor's covered set (it's the only covered page with substantial unsaved input). Preserve
the draft (or at minimum acknowledge the interruption) so an expiry mid-compose doesn't discard work.

## User Stories
US-14.3.2 (Session Expiry) — the graceful-degradation edge the interceptor currently misses.

## Goal
A user composing a listing whose session expires does not lose their input: on return from `/login`
the draft is restored (or they are clearly told the work couldn't be saved), instead of a silent wipe.

## Scope Check
- Frontend only — `Page/Marketplace/CreateListing.elm` + a small hook in the expiry/redirect path.
  One concern (draft preservation on expiry). < 300 LOC.

## Wiring
- [x] UI behaviour (SPA). No new endpoint.

## Technical Requirements
Pick one after weighing UX:
1. **Draft persistence:** on `SessionExpired` from `CreateListing` (or on any redirect), stash the
   form state to localStorage; on return to `CreateListing` after re-login, restore it.
2. **Acknowledged loss:** carry a "your listing draft couldn't be saved — please re-enter" note into the
   post-login CreateListing view (lighter than full persistence).
3. **Refresh-then-resubmit:** attempt a silent refresh and resubmit before falling to the interceptor
   (coordinates with the #173 renewal path) — only if the action was a submit in flight.
Scope to `CreateListing`; note if the pattern should generalize to other input-heavy pages.

## Reviewer Context
- `CreateListing` routes `SessionExpired -> Main.sessionExpired` (Main.elm ~1234); the redirect
  re-inits the page, so any draft must be stashed BEFORE the redirect and restored on re-init.
- Reuse the existing `saveAuth`-style localStorage approach; avoid a new port if possible.

## Test Audit
_Compact — SPA UX/state. Green when a mid-compose expiry preserves (or acknowledges) the draft._

| Layer | Applies? | Verdict |
|-------|----------|---------|
| 10 Elm state machine | yes | ✅ `CreateListingDraftTest.elm` — "matching userId hydrates all six fields", "mismatched userId does NOT hydrate and clears the draft", "network error → NoOut (stays local, no SessionExpiredWithDraft)". |
| 7 Storage | yes | ✅ `CreateListingDraftTest.elm` — "encoded value round-trips to the six fields + current userId" (localStorage draft round-trip, option 1 chosen). |
| others | no | n/a |

## Definition of Done
- [x] A session expiry while composing a listing does not discard the input — draft stashed to localStorage on `SessionExpiredWithDraft` and restored (userId-scoped) on re-init (option 1)
- [x] Validation path: `CreateListingDraftTest.elm` — round-trip, userId-scoped hydrate/clear, non-401 stays local
- [x] `elm-test` + `just verify` pass
- [x] Test audit (embedded) is GREEN
- [x] **Meets the Completion Bar** (`docs/agents/standards/completion-bar.md`) — draft preserved across expiry, round-trip + guard tested.

## Dependencies
- #173 (the interceptor / redirect on expiry).

## Agent Assignment
elm-agent.

## Progress Notes
- 2026-07-10: Filed from #173's PE gate (P3, ux). CreateListing loses in-progress form data on expiry;
  this preserves or acknowledges it.
