# Issue #202: Privacy & Visibility UX polish

## Summary
Child of the #122 epic (integration `feat/122-e2e`). Addresses the actionable ux-review findings on the block-user (#193) and placement-visibility (#194) features. Frontend-only (Elm); all backends already exist.

## User Stories
Polishes US-10.1.2 (Block a User) and US-10.2.2 (Override Placement Visibility) — no new stories claimed.

## Scope Check
- Controllers: 0. Endpoints: 0. Single concern (UX polish of two shipped features). Elm only. OK.

## Wiring
- [x] Frontend polish on already-wired features.
- [ ] Implementation only.

## Feature-Completeness Pre-Check
n/a — polishing already-built + claimed stories (US-10.1.2 in #193, US-10.2.2 in #194). Live-drive of the polished flows rides with E2E #199/#200.

## Technical Requirements
**Block (#193):**
- Add `aria-label "Reader actions"` + `aria-haspopup`/`aria-expanded` to the `⋯` overflow trigger in `Components/BlockUserModal.elm` (screen-reader dead-end at the feature entry).
- Show a per-row/section error message when an **unblock** fails on a non-401 error (`Page/Settings/Privacy.elm` — currently silent: row kept, `unblocking` cleared, no message).
- **Blocked-users pagination UI:** the list API is paginated (20/page); add a "Load more" affordance (or paging) so heavy blockers can see the full list. Backend pagination already exists (`list_blocked_users/2`).
- Confirm hidden-after-self-block on a blog post lands on a graceful "no longer available" state, not a technical error (verify; fix the empty/error render if needed).

**Placement (#194):**
- Rename the `platform` visibility **label** to **"Members"** (Public / Members / Only me) in `Types/Visibility.elm` — keep the wire value `"platform"`.
- Replace the ceiling-explanation `title` tooltip on the disabled `<option>` (browsers don't render it) with **always-visible helper text** below the select, e.g. "This shelf is set to <ceiling> — a book can't be more visible than its shelf." (`Page/BookDetail.elm`, `Types/Visibility.elm`).
- **Optimistic rollback:** on `PlacementVisibilityUpdated (Err _)`, revert the select to the prior visibility instead of leaving the server-rejected value shown (`Page/BookDetail.elm:405-441`).
- Typography/tone: use the ellipsis char `…` consistently (match the block modal), warm up the placement error copy, drop the redundant `aria-label "Placement visibility"` where the visible `<label>` already reads "Visibility".

## Reviewer Context
- The `platform` wire value must not change — only the display label. `Types.Visibility` deliberately scopes out `group` (shelf/profile code keeps its own String handling).

## Test Audit
| Layer | Applies? | Verdict |
|-------|----------|---------|
| Elm state machine / view | yes | ❌ elm-test updates for the new error state, helper text, label, rollback, aria (→ ✅) |
| E2E | downstream | #199/#200 exercise the polished flows |
| 1–13 backend | no | n/a — frontend only |

## Definition of Done
- [ ] All block + placement findings above implemented
- [ ] `"Members"` label; `platform` wire value unchanged
- [ ] elm-test covers: unblock-error state, ceiling helper text, optimistic rollback, aria attributes
- [ ] `just verify` passes (elm-test, elm-review, elm-format)

## Dependencies
Epic #122. Polishes #193 + #194 (both merged). No child deps.

## Agent Assignment
elm-agent.

## Progress Notes
- 2026-07-14: Created from the ux-review of #193/#194 (fix-everything decision). "Members" label chosen by maintainer.
