# Issue #060c: Elm — Privacy Settings + Visibility Components

## Summary
Build privacy settings page and reusable visibility components (badges, View As bar).

## User Stories
US-10.1.1 (profile visibility), US-10.2.1 (shelf visibility), US-10.3.1 (View As)

## Goal
Users can control their profile and shelf visibility. View As mode lets users preview how their profile appears to others.

## Technical Requirements
**`Page.Settings.Privacy`:**
- Profile visibility toggle (Only me / Discoverable)
- Per-shelf visibility overrides (owner/group/platform per shelf)
- Ceiling rule explanation text
- Save via `PUT /api/settings/profile_visibility` and `PUT /api/bookshelves/:id/visibility`

**`Components.VisibilityBadge`:**
- Icon per level: padlock (owner), group (group), globe (platform)
- Tooltip explaining the level
- Used on shelves, posts, listings

**`Components.ViewAsBar`:**
- Sticky amber banner when ?view_as= is active
- Shows current perspective: "Viewing as: Platform visitor"
- "Exit preview" button removes the query param

## Scope Check
- Create 1 page + 2 components
- ~200 LOC

## Dependencies
#057c (settings hub)

## Definition of Done
- [ ] Privacy page saves profile + shelf visibility
- [ ] Visibility badges render correctly
- [ ] View As bar appears with query param
- [ ] Exit preview removes query param
- [ ] `elm-format --validate src/` passes

## Agent Assignment
elm-agent
