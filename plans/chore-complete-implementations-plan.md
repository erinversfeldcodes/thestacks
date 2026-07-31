# Plan: Complete Implementation Gaps (Issues #138–#152)
**Branch**: `chore/complete-implementations`
**Created**: 2026-03-28
**Status**: Complete — all 14 phases merged, 1598 tests passing, 13/13 E2E upload tests passing against deployed PR stack (2026-03-31)

## Context

A test audit against US-1.1.1–1.1.8 revealed two categories of gap: (1) features that are partially implemented — schemas and changesets exist from the proto.sync work (Issue #131) but the context functions, endpoints, and Elm pages were never written; (2) features that are fully unimplemented despite being defined in user stories.

This plan sequences 15 new issues across 6 logical work streams. Each phase delivers working, testable software. The implementation order minimises dependency friction: standalone features first, dependency chains next, structurally risky work (physical shelf migration) near the end, and marketplace/notification work last.

## Marketplace Scope (updated 2026-03-30)

Phases 13 and 14 are now **unblocked**. The marketplace is scoped to listing + messaging only — no checkout, payment (Stitch Money), or shipping (Pargo). #054a (listing CRUD + state machine) is complete and provides sufficient foundation. #054b and #054c remain deferred until payment/shipping is needed.

---

## Work Streams & Sequence

```
Phase 1:  #148  Reading Progress Tracking
Phase 2:  #149  Onboarding Flow Backend
Phase 3:  #142  Blog Comments
          ↓ groups chain
Phase 4:  #138  Groups Context
Phase 5:  #139  Groups API
Phase 6:  #150  Visibility Grants CRUD
Phase 7:  #140  Groups Elm UI
Phase 8:  #141  Group Content Feed
          ↓ partner chain
Phase 9:  #145  Partner Entity & API Keys
Phase 10: #146  Partner Inventory & Events API
Phase 11: #147  Third Spaces UI
          ↓ structural
Phase 12: #151  Physical Shelf Entity
          ↓ marketplace
Phase 13: #143/#144  Marketplace Browse UI (contact-info only, Elm-only)
          ↓ cross-cutting
Phase 14: #152  Notification Trigger Wiring
```

---

## Phases

### Phase 1: Reading Progress Tracking (Issue #148)
**Agent(s)**: elixir-agent, elm-agent
**Objective**: Add `reading_status`, `current_page`, `started_at`, `finished_at` to placements. Wire through context, API, and placement card UI.

**Steps**:
1. Write migration adding 4 columns to `op.bookshelf_placements` (all nullable or with safe defaults so existing rows are unaffected)
2. Update `proto/stacks/shelving/v1/placement.proto` with new fields; run `mix proto.sync`
3. Add `update_reading_progress/3` and `list_in_progress/1` to `Stacks.Shelving`
4. Add `PUT /api/placements/:id/progress` endpoint to `BookshelfPlacementController`
5. Update `Components.PlacementCard` with status badge + page progress indicator
6. Add event emission for `placement.reading_started` and `placement.reading_completed`

**Regression Gate**: `mix test apps/core/test/stacks/shelving_test.exs && just verify`

**DoD**:
- [ ] Migration is non-destructive; all existing placements default to `reading_status = 'to_read'`
- [ ] `update_reading_progress/3` auto-sets `started_at` on first `:reading` transition only
- [ ] `update_reading_progress/3` auto-sets `finished_at` on `:completed` transition
- [ ] API returns 403 when user does not own placement
- [ ] Elm status badge renders on placement card
- [ ] Tests cover all state transitions including auto-timestamp logic
- [ ] `just verify` passes

---

### Phase 2: Onboarding Flow Backend (Issue #149)
**Agent(s)**: elixir-agent, elm-agent
**Objective**: Replace the `onboarding_completed` boolean with JSONB step tracking. Wire the existing `Components.OnboardingOverlay` to the new API so it resumes from the correct step.

**Steps**:
1. Migration: add `onboarding_steps jsonb` column; replace boolean with a `GENERATED ALWAYS AS` computed column
2. Add `onboarding_status/1`, `complete_onboarding_step/2`, `reset_onboarding/1` to `Stacks.Accounts`
3. Add `OnboardingController` with `GET /api/onboarding/status`, `PUT /api/onboarding/step/:step`, `POST /api/onboarding/reset`
4. Update `GET /api/auth/me` to include `onboarding_completed` and `next_onboarding_step`
5. Update `Components.OnboardingOverlay` to call `GET /api/onboarding/status` on mount and resume from `next_step`

**Regression Gate**: `mix test apps/core/test/stacks/accounts_test.exs && just verify`

**DoD**:
- [ ] Migration: computed `onboarding_completed` column replaces boolean
- [ ] `complete_onboarding_step/2` is idempotent
- [ ] After all 3 steps, `GET /api/auth/me` shows `onboarding_completed: true`
- [ ] `POST /api/onboarding/reset` resets all steps
- [ ] Overlay resumes from correct step on re-login
- [ ] Tests cover: fresh user, partial completion, full completion, reset
- [ ] `just verify` passes

---

### Phase 3: Blog Comments (Issue #142)
**Agent(s)**: elixir-agent, elm-agent
**Objective**: Add a comment thread to blog posts. Threaded one level deep. Block filtering silent. Author deletion rights.

**Steps**:
1. Write migration for `op.post_comments` table (id, post_id, author_id, parent_id, body, created_at)
2. Add `PostComment` proto message to `proto/stacks/content/v1/blog.proto`; run `mix proto.sync`
3. Add `list_comments/2`, `create_comment/3`, `delete_comment/2` to `Stacks.Blog`
4. Add block filtering in `list_comments/2` via `Stacks.Social.blocked_user_ids/1`
5. Add `CommentController` with `POST /api/posts/:post_id/comments` and `DELETE /api/comments/:id`
6. Add comment section to `Page.BlogPost` Elm page (list + form + nested replies)

**Regression Gate**: `mix test apps/core/test/stacks/blog_test.exs && just verify`

**DoD**:
- [ ] `list_comments/2` excludes comments from users the viewer has blocked
- [ ] `delete_comment/2` returns `:unauthorized` for non-author non-post-owner
- [ ] POST returns 404 for unpublished posts
- [ ] Elm renders one level of threading
- [ ] Author badge visible on post author's own comments
- [ ] `just verify` passes

---

### Phase 4: Groups Context (Issue #138)
**Agent(s)**: elixir-agent
**Objective**: Implement all group lifecycle operations in `Stacks.Social`. Schemas and changesets already exist. No UI or API changes in this phase.

**Steps**:
1. Add `create_group/2`, `get_group/2`, `list_user_groups/1`, `update_group/3`, `delete_group/2`
2. Add `invite_member/3`, `accept_invitation/2`, `decline_invitation/2`
3. Add `leave_group/2`, `remove_member/3`, `list_group_members/2`
4. Emit events: `group.created`, `group.invitation_sent`, `group.member_joined`, `group.member_left`, `group.member_removed`
5. Wire invite lookup by email and by username

**Regression Gate**: `mix test apps/core/test/stacks/social_test.exs && just verify`

**DoD**:
- [ ] `create_group/2` creates group with requesting user as owner member
- [ ] `invite_member/3` returns `:already_member` if user is already in group
- [ ] `accept_invitation/2` creates GroupMember and deletes the invitation
- [ ] `leave_group/2` returns `{:error, :is_owner}` when owner tries to leave
- [ ] All 5 events emitted
- [ ] `just verify` passes

---

### Phase 5: Groups API (Issue #139)
**Agent(s)**: elixir-agent
**Objective**: Expose Phase 4's context over HTTP. Add `GroupController` and `GroupMemberController`. Wire routes.

**Steps**:
1. Create `GroupController` (create, show)
2. Create `GroupMemberController` (invite, accept, decline, remove, leave)
3. Add `GroupJSON` and `GroupInvitationJSON` views
4. Wire 7 routes under `/api` with `[:api, :auth]` pipeline
5. Add integration tests for all endpoints including auth error cases

**Regression Gate**: `mix test apps/core/test/stacks_web/group_controller_test.exs && just verify`

**DoD**:
- [ ] All 7 endpoints return correct status codes
- [ ] Unauthenticated requests return 401
- [ ] Non-owner remove returns 403
- [ ] Owner leave returns 422 with reason
- [ ] `just verify` passes

---

### Phase 6: Visibility Grants CRUD (Issue #150)
**Agent(s)**: elixir-agent
**Objective**: Implement grant/revoke/list operations in `Stacks.Social` and update `Stacks.Visibility.resolve/2` so group-visibility bookshelves actually work end-to-end.

**Steps**:
1. Add `grant_visibility/3`, `revoke_visibility/3`, `list_visibility_grants/2`, `has_visibility_grant?/2`
2. Update `Stacks.Visibility.resolve/2` to call `has_visibility_grant?/2` for `visibility = "group"` bookshelves
3. Add `VisibilityGrantController` with POST, GET, DELETE
4. Wire 3 routes under `/api/bookshelves/:bookshelf_id/grants`
5. Add tests for visibility resolution through the grant layer

**Regression Gate**: `mix test apps/core/test/stacks/visibility_test.exs && just verify`

**DoD**:
- [ ] `has_visibility_grant?/2` returns true when viewer is in a granted group
- [ ] Group-visibility bookshelves are now accessible to group members
- [ ] Granting on non-group-visibility shelf returns `{:error, :not_applicable}`
- [ ] `just verify` passes

---

### Phase 7: Groups Elm UI (Issue #140)
**Agent(s)**: elm-agent
**Objective**: Build `Page.Groups` (list + create), `Page.Groups.Detail` (member management + invite), and `Components.InvitationCard`. Add routes.

**Steps**:
1. Create `Page.Groups` with group list, pending invitations panel, create-group form
2. Create `Page.Groups.Detail` with member list, invite input, remove button (owner only)
3. Create `Components.InvitationCard` with Accept/Decline
4. Add `/groups` and `/groups/:id` routes to `Main.elm`
5. Add Elm unit tests for all Msg handlers in both pages

**Regression Gate**: `cd frontend && npx elm-test && just verify`

**DoD**:
- [ ] `/groups` renders groups and pending invitations
- [ ] Create form validates non-empty name before submit
- [ ] Invite input accepts email or username; shows inline success/error
- [ ] Owner sees Remove button; non-owner does not
- [ ] `just verify` passes

---

### Phase 8: Group Content Feed (Issue #141)
**Agent(s)**: elixir-agent, elm-agent
**Objective**: Build `Social.feed_for_group/3` query, `GET /api/groups/:id/feed` endpoint, and the feed tab in `Page.Groups.Detail`.

**Steps**:
1. Implement `feed_for_group/3` querying event_log for placements + blog posts from group members
2. Apply visibility filtering using `Stacks.Visibility.resolve/2`
3. Add cursor pagination (ISO8601 `before` param)
4. Add `GroupFeedController` with `GET /api/groups/:id/feed`
5. Add feed tab + `Components.FeedItem` to `Page.Groups.Detail`
6. Add tests for visibility filtering and pagination cursor

**Regression Gate**: `mix test apps/core/test/stacks/social_test.exs && cd frontend && npx elm-test && just verify`

**Orchestrator note**: This phase completes the Groups work stream. Before starting Phase 9, confirm all Group tests are green and `just verify` passes clean.

**DoD**:
- [ ] Feed returns placements + blog posts from group members in chronological order
- [ ] Items from former members are excluded
- [ ] Visibility filtering excludes owner-only content
- [ ] `next_cursor` pagination works
- [ ] `just verify` passes

---

### Phase 9: Partner Entity & API Keys (Issue #145)
**Agent(s)**: elixir-agent
**Objective**: Introduce the `Partner` schema, `Stacks.Partners` context, registration + approval workflow, HMAC key lifecycle, and `PartnerAuthPlug`.

**Steps**:
1. Write migration for `op.partners` table
2. Add `Partner` proto message to `proto/stacks/internal/v1/partner.proto`; run `mix proto.sync`
3. Implement `Stacks.Partners`: `register_partner/1`, `approve_partner/2`, `reject_partner/3`, `rotate_key/1`, `authenticate_partner/1`, `list_pending_partners/0`
4. HMAC key format: `sk_partner_<40 hex>`. Store Argon2 hash. Return raw key once on approve.
5. Add `StacksWeb.PartnerAuthPlug` reading `Authorization: Bearer sk_partner_...`
6. Add `PartnerRegistrationController` (public, `POST /api/partners/register`)
7. Add `PartnerController` (platform-owner only: list pending, approve, reject)

**Regression Gate**: `mix test apps/core/test/stacks/partners_test.exs && just verify`

**DoD**:
- [ ] `approve_partner/2` returns raw key once; `authenticate_partner/1` validates it
- [ ] `rotate_key/1` invalidates old key immediately
- [ ] `PartnerAuthPlug` returns 401 for missing/invalid keys
- [ ] Approval endpoint returns 403 for non-platform-owner
- [ ] `just verify` passes

---

### Phase 10: Partner Inventory & Events API (Issue #146)
**Agent(s)**: elixir-agent
**Objective**: Build the inbound partner API for stock sync (JSON + CSV) and event creation. Uses `PartnerAuthPlug` from Phase 9.

**Steps**:
1. Write migration for `op.partner_inventory` table
2. Add `PartnerInventoryItem` proto message; run `mix proto.sync`
3. Implement JSON sync: upsert inventory rows, return `synced`/`unresolved` counts
4. Implement CSV upload using `NimbleCSV`; enforce 10,000-row limit
5. Add `PartnerInventoryController` (sync, import, index) and `PartnerEventController` (create, index, delete)
6. Wire routes under `/api/partner` with `[:api, :partner_auth]` pipeline
7. Test CSV edge cases: missing header, malformed rows, BOM prefix

**Regression Gate**: `mix test apps/core/test/stacks/partner_inventory_test.exs && just verify`

**DoD**:
- [ ] JSON sync returns correct `synced`/`unresolved` counts
- [ ] CSV with 10,001 rows returns 422
- [ ] Unknown ISBNs in `unresolved`, not silently dropped
- [ ] Event with `starts_at` in the past returns 422
- [ ] Partner can only manage their own events
- [ ] `just verify` passes

---

### Phase 11: Third Spaces UI (Issue #147)
**Agent(s)**: elixir-agent, elm-agent
**Objective**: Build `/third-spaces` browse page and wire partner inventory into book detail overlay as "Available at" section.

**Steps**:
1. Add `list_third_spaces/1` and `book_availability/1` to `Stacks.Enrichment`
2. Add `ThirdSpaceController` (`GET /api/third-spaces`) and `BookAvailabilityController` (`GET /api/books/:id/availability`)
3. Build `Page.ThirdSpaces` Elm page: cork-board card grid + `Components.ThirdSpaceDetail` overlay
4. Add "Available at" section to `Page.BookDetail` (hidden when empty)
5. Add `/third-spaces` route to `Main.elm`

**Regression Gate**: `mix test apps/core/test/stacks/enrichment_test.exs && cd frontend && npx elm-test && just verify`

**Orchestrator note**: This phase completes the Partner work stream. Before starting Phase 12, confirm `just verify` passes clean and the cork board page renders correctly.

**DoD**:
- [ ] `/third-spaces` renders cards and empty state
- [ ] Third space detail overlay opens on card click
- [ ] `GET /api/books/:id/availability` returns grouped partner stock
- [ ] "Available at" section hidden when stock is empty
- [ ] `just verify` passes

---

### Phase 12: Physical Shelf Entity (Issue #151)
**Agent(s)**: elixir-agent, elm-agent
**Objective**: Introduce the `Shelf` entity between `Bookshelf` and `Placement`. Back-fill all existing placements. Replace client-side row grouping in Elm with server-provided shelf data.

**Orchestrator note**: This is the highest-risk phase due to the multi-step migration and the breaking change to the bookshelf API response shape. Review the migration back-fill SQL carefully before approving. The reviewer should verify (a) zero placements have a null `shelf_id` after migration and (b) the Elm change from `groupIntoRows` to server-driven shelves does not regress the bookshelf rendering.

**Steps**:
1. Write migration: create `op.shelves`, back-fill one shelf per bookshelf, add `shelf_id` to `bookshelf_placements` as nullable, back-fill all placements, add NOT NULL constraint
2. Add `Shelf` proto message to `proto/stacks/shelving/v1/shelf.proto`; run `mix proto.sync`
3. Add `list_shelves/1`, `create_shelf/2`, `delete_shelf/2`, `reorder_shelves/3`, `move_placement_to_shelf/3` to `Stacks.Shelving`
4. Update `get_bookshelf_books/2` return shape to `[{shelf: Shelf, placements: [Placement]}]`
5. Add `ShelfController` with 4 routes; add `PUT /api/placements/:id/shelf` to `BookshelfPlacementController`
6. Update `Page.Bookshelf` to use server shelf grouping; remove `groupIntoRows 990`
7. Add back-fill correctness test: assert no placements have null `shelf_id` after migration

**Regression Gate**: `mix test apps/core/test/stacks/shelving_test.exs && cd frontend && npx elm-test && just verify`

**DoD**:
- [ ] Migration back-fills all existing placements (zero null `shelf_id` after)
- [ ] `delete_shelf/2` returns `:not_empty` when shelf has placements
- [ ] `move_placement_to_shelf/3` returns `:wrong_bookshelf` for cross-bookcase moves
- [ ] `GET /api/bookshelves/:name` response includes shelves with nested placements
- [ ] Elm renders books grouped by shelf (not by pixel-width)
- [ ] `just verify` passes

---

### Phase 13: Marketplace Browse UI (Issues #143 + #144 — collapsed)
**Agent(s)**: elm-agent

**Scope note (2026-03-30)**: Offer threads and Q&A are fully deferred. The marketplace is contact-info-only: listings include a `contact_info` field for offline negotiation. The backend is already complete from #054a (`GET /api/listings`, `GET /api/listings/:id`, create/activate/sold/deactivate all exist, `contact_info` field in schema). This phase is Elm-only.

**Objective**: Build `Page.Marketplace` (browse active listings) and a listing detail overlay showing contact info for offline negotiation.

**Steps**:
1. Create `Page.Marketplace` with listing card grid; call `GET /api/listings` on mount
2. Build `Components.ListingCard` (book title, author, condition, price, pricing mode badge)
3. Build listing detail overlay: opens on card click, shows full listing fields including `contact_info`
4. Add `/marketplace` route to `Main.elm`; add nav link
5. Add Elm unit tests for `Page.Marketplace` Msg handlers (Loading, Loaded, Failed states)

**Regression Gate**: `cd frontend && npx elm-test && just verify`

**DoD**:
- [ ] `/marketplace` renders active listing cards; shows empty state when none
- [ ] Listing card shows: book title, author, condition, price formatted as ZAR currency
- [ ] Clicking a card opens a detail overlay with `contact_info` visible
- [ ] Unauthenticated users can browse (no auth required)
- [ ] Elm unit tests cover Loading → Loaded and Loading → Failed transitions
- [ ] `just verify` passes

---

### Phase 14: Notification Trigger Wiring (Issue #152)
**Agent(s)**: elixir-agent
**Objective**: Wire the three undelivered email templates to their triggering events. Add the three notification preference flags to users.

**Steps**:
1. Migration: add `notify_group_invitations`, `notify_offers`, `notify_wishlist_availability` boolean columns to `op.users` (all default true)
2. Implement `Stacks.Notifications.GroupInvitationSubscriber` subscribing to `group.invitation_sent`
3. Implement `Stacks.Notifications.OfferNotificationSubscriber` subscribing to `offer.opened`
4. Implement `Stacks.Notifications.WishlistAvailabilitySubscriber` subscribing to `listing.activated`; add 24h Oban deduplication
5. Register all three subscribers in `Stacks.Application`
6. Test each subscriber: happy path, opt-out (flag false), deduplication (wishlist only)

**Regression Gate**: `mix test apps/core/test/stacks/notifications_test.exs && just verify`

**Orchestrator note**: This phase completes the full plan. After the regression gate passes, run `just verify` one final time across the whole codebase and confirm `mix test` is fully green before closing the branch.

**DoD**:
- [ ] `group.invitation_sent` triggers invitation email (respects flag)
- [ ] `offer.opened` triggers new-offer email to seller (respects flag)
- [ ] `listing.activated` triggers wishlist availability email only to matching wishlist users
- [ ] Wishlist emails deduplicated within 24h per book+user
- [ ] Users with flag false receive no email
- [ ] `just verify` passes

---

## Gate Checkpoints

Between each phase, the orchestrator verifies:
1. `just verify` exits 0 (format + credo + sobelow + elm-format + buf lint)
2. `mix test` is fully green (no new failures introduced)
3. The completed issue's DoD checklist is satisfied
4. No migration is left unapplied (`mix ecto.migrations` shows no pending)

If any gate fails, the phase is NOT considered complete. The agent is sent back to fix the issue before the next phase begins.

---

## Cross-Cutting Concerns

**Proto sync**: Issues #148, #149 (no proto), #142, #145, #146, #151 each require `mix proto.sync` after adding a proto message. The agent must run this as part of the phase — not as a separate step.

**Migration safety**: All migrations must be non-destructive. Back-fills must complete before NOT NULL constraints are added. The squawk linter (`scripts/security-squawk.sh`) must pass for each migration.

**Event bus**: All new events must be added to the event type allowlist if one exists. The orchestrator should check `Stacks.Events` for any registered event type validation before closing each phase.

**dbt staging models**: Any new table introduced by a migration (post_comments, shelves, partner_inventory, partners) needs a corresponding staging model. Run `mix proto.sync` — if the new table has a proto message, staging SQL is auto-generated. If not (post_comments, shelves), a hand-written `stg_*.sql` is required. The orchestrator should verify this after each migration phase.

---

## State File

Create `plans/chore-complete-implementations-state.json` when execution begins. Track `current_phase`, each phase's `status`, `revision_cycles`, and `reviewer_verdict` per the standard state schema.
