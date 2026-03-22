# Issue #057c: Elm — User Menu Dropdown + Settings Hub Layout

## Summary
Add user menu dropdown (Settings + Sign Out) and the settings hub with sidebar navigation and route structure.

## User Stories
US-14.3.3 (user menu dropdown), US-17.1.1 (settings hub)

## Goal
Authenticated users see their display name in the header. Clicking opens a dropdown with "Settings" and "Sign Out". Settings page has sidebar navigation with sub-routes.

## Technical Requirements
**User menu:**
- `Components.UserMenu` — click display name → dropdown
- `userMenuOpen : Bool` in model
- Items: "Settings" (navigates to /settings) and "Sign Out" (calls logout API)
- Click outside or Escape closes dropdown
- `aria-label="User menu"` on dropdown

**Settings hub:**
- Route: `/settings` with sidebar navigation
- Sub-routes: `/settings/profile`, `/settings/password`, `/settings/consent`, `/settings/age-verification`, `/settings/notifications`
- `Page.Settings` as layout wrapper with sidebar
- Sidebar highlights active sub-page
- Mobile: sidebar collapses to dropdown selector
- Existing `Page.Settings.Consent` and `Page.Settings.AgeVerification` move into the hub

## Scope Check
- Create `Components.UserMenu`
- Create `Page.Settings` (layout)
- Modify `Navigation.Route` (add settings sub-routes)
- Modify `Main.elm` (wire menu + settings routing)
- ~250 LOC

## Definition of Done
- [ ] User menu dropdown renders and works
- [ ] Settings hub has sidebar with all sub-routes
- [ ] Active sub-page highlighted in sidebar
- [ ] Mobile sidebar collapses
- [ ] Existing consent + age-verification pages work in new hub
- [ ] `elm-format --validate src/` passes

## Agent Assignment
elm-agent
