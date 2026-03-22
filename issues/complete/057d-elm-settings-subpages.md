# Issue #057d: Elm — Settings Sub-Pages

## Summary
Build the profile, password, and notifications settings sub-pages within the settings hub.

## User Stories
US-17.2.1 (profile), US-17.2.2 (location), US-17.2.3 (password), US-17.3.1 (notifications)

## Goal
Users can edit their profile (display name, email, location), change password, and manage notification preferences — all within the settings hub sidebar layout.

## Technical Requirements
**Profile (`Page.Settings.Profile`):**
- Display name, email, website URL
- Location: country dropdown (ISO codes), city text input
- Save via `PUT /api/settings/profile` and `PUT /api/settings/location`
- Email change requires current password confirmation

**Password (`Page.Settings.Password`):**
- Current password + new password + confirm new password
- Strength indicator (length, mixed case, numbers)
- Save via `PUT /api/settings/password`
- Clear form on success, show error on failure

**Notifications (`Page.Settings.Notifications`):**
- Toggles per category (new book added, price drop, review update, etc.)
- Auto-save on toggle change (debounced)
- Save via `PUT /api/settings/notifications`

## Scope Check
- Create 3 new page modules
- ~300 LOC total

## Dependencies
#057c (settings hub layout must exist)

## Definition of Done
- [ ] Profile page saves display name, email, location
- [ ] Password page validates and saves
- [ ] Notifications page toggles and auto-saves
- [ ] All pages show success/error feedback
- [ ] `elm-format --validate src/` passes

## Agent Assignment
elm-agent
