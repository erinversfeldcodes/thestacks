# Issue #048: Controller Retrofit + Settings Endpoints + RLS Enablement

## Summary
Wire `resolve_visibility/2` into every existing controller. Add the settings endpoints (profile, location, password, notifications). Enable the RLS policies designed in Issue #044.

## User Stories
US-17.2.1 (profile), US-17.2.2 (location), US-17.2.3 (password), US-17.3.1 (notifications), US-10.2.1 (shelf visibility), US-10.2.2 (placement visibility)

## Goal
Every controller that returns user-generated content passes through visibility checks. Settings endpoints allow users to manage their profile, location, password, and notification preferences. RLS provides database-level safety net.

## Technical Requirements

**Controller retrofit:**
- `BookController.show/2` — call `resolve_visibility/2` before returning book detail
- `BookshelfController.show/2` — filter placements through `resolve_visibility/2`
- `SearchController` — platform-wide search results filtered by visibility
- `BookshelfPlacementController` — visibility check on read, ceiling rule on write
- `CatalogueController` — filter by visibility
- `GDPRController` — already user-scoped, verify
- Pattern: extract viewer context from `conn.assigns[:current_user]`; call `Visibility.resolve_visibility/2`; return 404 for `:hidden`

**Settings endpoints (`StacksWeb.UserSettingsController`):**
- `PUT /api/settings/profile` — update display_name, email (requires current_password), website_url. Emits `user.profile_updated` event.
- `PUT /api/settings/location` — update country_code, city. Emits `user.location_updated` event (triggers GeographicDiscoveryJob when enrichment exists).
- `PUT /api/settings/password` — current_password + new_password + confirm. Argon2. Rate limit: 3/min.
- `PUT /api/settings/notifications` — toggle `notify_*` booleans. Auto-save (no submit button on frontend).

**Shelf visibility controls:**
- `PUT /api/bookshelves/:id/visibility` — set shelf visibility level. Enforce ceiling rule.
- `PUT /api/placements/:id/visibility` — set placement visibility. Enforce: placement ≤ shelf.

**RLS enablement:**
- Apply the SQL policies from `docs/rls-design.md` (Issue #044) as a new migration
- `ALTER TABLE ... ENABLE ROW LEVEL SECURITY` on all user-data tables
- Test that application queries still work (app role has bypass or appropriate policies)
- Test that a direct DB connection without the app role is properly restricted

## Definition of Done
- [ ] Every content controller calls `resolve_visibility/2` or equivalent
- [ ] `PUT /api/settings/profile` works (email change requires password)
- [ ] `PUT /api/settings/location` works and emits event
- [ ] `PUT /api/settings/password` works with Argon2 verification
- [ ] `PUT /api/settings/notifications` toggles preferences
- [ ] Shelf and placement visibility endpoints enforce ceiling rule
- [ ] RLS policies applied and tested
- [ ] `mix test` passes — all existing tests still green
- [ ] `mix sobelow` passes (no new security findings)

## Dependencies
Issue #047 (visibility core must exist to retrofit into controllers)

## Agent Assignment
elixir-agent

## Progress Notes
