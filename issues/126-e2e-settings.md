# Issue #126: E2E Test Suite — Settings Hub

## Summary
Comprehensive E2E test coverage for the settings hub layout (US-17.1.1), profile editing (US-17.2.1), location setting (US-17.2.2), password change (US-17.2.3), and notification preferences (US-17.3.1).

## User Stories
US-17.1.1 (Settings Index Page), US-17.2.1 (View and Edit Profile), US-17.2.2 (Set Location), US-17.2.3 (Change Password), US-17.3.1 (Email Notification Preferences)

## Goal
Validate the settings hub sidebar navigation, profile form save with display name and email (password required for email changes), location update triggering geographic discovery event, password change with Argon2 verification and rate limiting, and notification toggle auto-save behaviour.

## Scope Check
- Does this issue touch more than 3 controllers? No (UserSettingsController only).
- Does this issue add more than 2 new endpoints? No (tests only).
- Does this issue exceed ~300 lines of production code? No (test-only).
- Does this issue combine unrelated concerns? No (all settings-related).

## Wiring
- [ ] This issue includes router wiring and is user-facing when complete.
- [x] This issue is implementation only. Wired by issue #___ (test-only issue).

## Technical Requirements

### 1. Playwright UI Tests
- **Settings hub layout**: Navigate to `/settings` (redirects to `/settings/profile`) -> sidebar with 6 links + main content area
- **Sidebar items**: Profile, Password, Notifications, Consent, Age Verification, Privacy
- **Active sidebar**: Current sub-page highlighted with `settings-hub__nav-item--active`
- **Mobile dropdown**: `<select>` element for navigation on mobile
- **Profile form**: Display Name, Email, Website URL fields with "Save Profile" button
- **Location form**: Country Code and City fields with "Save Location" button
- **Profile save feedback**: "Profile saved." on success, "Could not save profile. Please try again." on error
- **Location save feedback**: "Location saved." on success, error message on failure
- **Password form**: Current Password, New Password, Confirm New Password fields
- **Password validation**: Inline errors for short password, mismatch, empty current password
- **Password success**: Fields cleared on success, "Password changed successfully." message
- **Password error**: "Current password is incorrect." on 422
- **Notification toggles**: 4 toggle rows (Price Drops, New Reviews, Author Updates, Event Alerts)
- **Toggle auto-save**: Clicking toggle immediately fires API call, shows "Preferences saved."
- **Toggle visual state**: `toggle--on` / `toggle--off` CSS classes

### 2. Playwright Navigation & Visual Tests
- **Auth guard**: All settings routes require auth
- **Settings entry**: User menu "Settings" -> `/settings/profile`
- **Sidebar navigation**: Click each sidebar link -> correct sub-page loads
- **Mobile navigation**: Select option changes -> navigates to sub-page

### 3. API Endpoint Tests
- `PUT /api/settings/profile` — 200 with `{ display_name, website_url, email }`
- `PUT /api/settings/profile` — 422 `invalid_current_password` when changing email without password
- `PUT /api/settings/profile` — 422 on changeset validation errors
- `PUT /api/settings/location` — 200 with `{ country_code, city }`
- `PUT /api/settings/location` — 422 on changeset errors
- `PUT /api/settings/password` — 200 `{ ok: true }`
- `PUT /api/settings/password` — 422 `invalid_current_password`
- `PUT /api/settings/password` — 422 on changeset validation (password too short)
- `PUT /api/settings/password` — 422 `current_password and new_password are required`
- `PUT /api/settings/password` — rate limited (`:password_change` bucket, 3/min)
- `PUT /api/settings/notifications` — 200 with notification preferences
- `PUT /api/settings/notifications` — 422 on changeset errors
- All settings endpoints — 401 without auth

### 4. Database Assertion Tests
- `op.users.display_name` and `op.users.website_url` updated via `User.profile_changeset`
- Email change: `Ecto.Multi` with `:profile` and `:email` steps; `Argon2.verify_pass` validates current password
- `op.users.country_code` and `op.users.city` updated via `User.location_changeset`
- `op.users.password_hash` updated with new Argon2 hash via `User.password_change_changeset`
- Two Argon2 operations on password change: `verify_pass` (current) + `hash_pwd_salt` (new)
- `op.users.notify_wishlist_availability`, `notify_marketplace`, `notify_group_invitations`, `notify_event_matches` updated via `User.notifications_changeset`
- Notification defaults: `notify_marketplace: true`, `notify_group_invitations: true`, others false

### 5. Event Flow Tests
- `user.profile_updated` emitted with `{ display_name }` on profile save
- `user.location_updated` emitted with `{ country_code, city }` on location save
- `user.password_changed` emitted with empty payload on password change
- `user.notifications_updated` emitted with all 4 notification fields
- No handlers currently registered for these events

### 6. Background Job Tests
- N/A — all settings changes are synchronous
- (Future: `user.location_updated` should trigger geographic discovery sweep)

### 7. External Service Tests
- N/A

### 8. Storage Tests
- N/A

### 9. Cache Tests
- N/A

### 10. dbt Model Tests
- `stg_users` reads from `op.users` — updated on profile/location changes

### 11. Elm State Machine Tests
- **Settings hub**: `Settings.view` renders layout with sidebar + content
- `viewSidebarItem` compares `currentRoute == item.route` for active state
- `SettingsMobileNavChanged path` -> `Nav.pushUrl model.key path`
- **Profile**: `Profile.init user` populates from auth data
- `SetDisplayName`/`SetEmail`/`SetWebsiteUrl` update fields, reset `savingProfile`
- `SaveProfile` -> `Api.updateProfile` -> `SaveProfileCompleted`
- `SetCountryCode`/`SetCity` update fields, reset `savingLocation`
- `SaveLocation` -> `Api.updateLocation` -> `SaveLocationCompleted`
- **Password**: `Password.init` -> all fields empty, `saving = NotAsked`
- `SetCurrentPassword`/`SetNewPassword`/`SetConfirmPassword` update fields
- `SavePassword` -> `validate model`:
  - New password < 8 chars: validation error
  - Passwords don't match: validation error
  - Current password empty: validation error
  - Valid: calls `Api.updatePassword`
- `SaveCompleted (Ok _)` -> resets model to init with `saving = Success ()`
- **Notifications**: `Notifications.init` -> all toggles false, `saving = NotAsked`
- `TogglePriceDrops`/`ToggleNewReviews`/etc. -> flip boolean, immediately call `savePreferences`
- `SaveCompleted (Ok _)` -> `saving = Success ()`
- Note: Preferences not loaded from server on init (starts at defaults)

### 12. Metrics & Telemetry Tests
- Profile update success/failure rates
- Email change attempt rate and rejection rate
- Location update success/failure rates
- `user.location_updated` event emission count
- Password change success rate, wrong-password rejection rate
- Rate limiter trigger count on `:password_change` bucket
- Argon2 computation times (two operations per password change)
- Notification preference update rate and success rate
- Toggle flip distribution per notification type

## Reviewer Context
- The frontend does not currently send `current_password` for email changes — this will fail server-side.
- Notification toggle labels don't match backend field names (e.g., `priceDrops` -> `notify_wishlist_availability`).
- Password change rate limit is stricter than auth: 3/min vs 5/min.
- Notification preferences are NOT loaded from server on page init — they start at default values. This is a known UX gap.

## Definition of Done
- [ ] All 11 test categories implemented with specific test cases listed above
- [ ] Tests pass with `TEST_TARGET=local`
- [ ] No flaky tests
- [ ] `just verify` passes

## Dependencies
Requires Accounts context, UserSettingsController, Settings hub Elm layout.

## Agent Assignment
testing-agent

## Progress Notes
[Updated by agents during execution.]
