# Issue #140: Groups — Elm UI

## Summary
Build the Elm pages for group browsing, group detail, and the invitation accept/decline flow. Uses the API from Issue #139.

## User Stories
US-11.1.1–US-11.1.4

## Goal
Users can create a group, see their groups, view a group's members, invite someone by username/email, and accept or decline a pending invitation — all through the Elm SPA with no page reloads.

## Scope Check
- Does this issue touch more than 3 controllers? → No — Elm only.
- Does this issue add more than 2 new endpoints? → No — consumes existing API.
- Does this issue exceed ~300 lines of production code? → 3 Elm modules, ~250 LOC each is ~750 LOC total. Split further if needed.
- Does this issue combine unrelated concerns? → No.

## Wiring
- [x] This issue includes router wiring and is user-facing when complete.

## Technical Requirements

**New Elm modules:**
- `Page.Groups` — list of user's groups; "Create group" button; pending invitations panel
- `Page.Groups.Detail` — group member list; "Invite" input field; member remove (owner only)
- `Components.InvitationCard` — reusable card for pending invitation with Accept/Decline buttons

**Routing additions (`Main.elm`):**
- `/groups` → `Page.Groups`
- `/groups/:id` → `Page.Groups.Detail`

**State machines:**
- `Page.Groups`: `Loading | Loaded { groups, pendingInvitations } | Failed`
- `Page.Groups.Detail`: `Loading | Loaded { group, members, inviteState } | Failed`
- `inviteState`: `Idle | Sending | Success | Failed String`

**RemoteData** for all HTTP calls (standard project pattern).

**Navigation:** After creating a group, navigate to `/groups/:new_id`. After accepting an invitation, refresh the group list.

## Reviewer Context
- Follow `Page.Bookshelf` for list-with-empty-state pattern.
- `Components.Overlay` wrapping pattern is used for confirmations — use it for "Remove member?" confirmation.
- All API calls use `Api.request` helper, not raw `Http.request`.
- Error messages extracted from JSON `{"error": "..."}` response body.

## Definition of Done
- [ ] `/groups` renders user's groups and pending invitations
- [ ] Create group form validates name (non-empty) before submit
- [ ] Group detail shows member list with roles
- [ ] Invite input accepts email or username; shows inline success/error
- [ ] Owner sees "Remove" button per member; non-owner does not
- [ ] Accept/Decline buttons on invitation cards update list immediately (optimistic)
- [ ] Elm unit tests for all Msg handlers
- [ ] `just verify` passes

## Dependencies
#139 (Groups API)

## Agent Assignment
elm-agent

## Progress Notes
