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

## Test Audit

_Baseline test-coverage map for this issue (13 layers × user story, happy/sad columns), generated 2026-07-08. This is the pre-implementation baseline — `❌`/`⚠️` cells are the work queue. Regenerate as tests land; the issue is Done when this audit is green (see Definition of Done)._

Last regenerated: 2026-07-08 (baseline, pre-implementation — Issue #126)

Legend: ✅ = exists | ⚠️ = exists but shallow | ❌ = missing | n/a = not applicable

`n/a` is used where (a) the layer/US combination genuinely doesn't apply,
or (b) the assertion is intentionally covered at a higher level (SLO gate,
cost dashboard, framework-wide mechanism test) and per-US repetition adds
no guarantee. Each `n/a` carries a one-line rationale.

**Scope note:** Issue #126 covers five user stories — the settings hub
layout (US-17.1.1), profile editing (US-17.2.1), location setting
(US-17.2.2), password change (US-17.2.3), and notification preferences
(US-17.3.1). The matrix is therefore 13 layers × 5 US, with happy/sad
columns per cell. Per-layer assertion inventories are taken from each
story's `docs/user_stories/US-17.*.md` §3–§13 and Issue #126's Technical
Requirements §1–§12.

**Feature status:** the settings feature IS implemented server-side —
this is not a greenfield audit. Existing surface:
`StacksWeb.UserSettingsController` (`update_profile/2`, `update_location/2`,
`update_password/2`, `update_notifications/2`, plus age_verification and
profile_visibility), context functions in `Stacks.Accounts`
(`update_profile/2` with `Ecto.Multi` + `ArgonPool`-gated
`verify_password`, `update_location/2`, `change_password/3`,
`update_notifications/2`), the five `User` changesets, router pipelines
including `:rate_limit_password_change` (bucket `:password_change`, 3/min),
Elm pages `Page.Settings.{Profile,Password,Notifications,Consent,AgeVerification,Privacy}`
+ the `Page.Settings` hub layout, dbt `stg_users` (proto-generated), and a
Playwright suite `e2e/tests/settings.spec.ts`.

**Notable finding — US-17.2.2 background wiring exists.** Contrary to the
story doc (US-17.2.2 §6–§7 mark the geographic discovery sweep as "not yet
implemented"), `user.location_updated` IS registered in
`Stacks.Events.Registry` → `Stacks.Discovery.Handlers.LocationUpdatedHandler`
→ enqueues `Stacks.Workers.GeographicDiscoveryJob`, and both are tested.
The audit baselines the real (implemented + tested) chain.

---

### Framework-layer summary

| Layer       | US-17.1.1 | US-17.2.1 | US-17.2.2 | US-17.2.3 | US-17.3.1 |
|-------------|-----------|-----------|-----------|-----------|-----------|
| Elixir      | n/a (layout shell) | ✅ (controller + context: display/email/website, 422 paths) | ✅ (controller + context + handler + job) | ✅ (controller + context; 401/422/short) | ⚠️ (happy covered; no 422 / no default-value test) |
| Elm unit    | ❌ (no `Page.Settings` hub test) | ❌ (no `Profile` test; module exposes `Msg` not `Msg(..)`) | ❌ (no location/`Profile` test) | ❌ (no `Password` test) | ❌ (no `Notifications` test) |
| Elm program | ❌ | ❌ | ❌ | ❌ | ❌ |
| Python      | n/a | n/a | n/a | n/a | n/a |
| E2E         | ⚠️ (hub renders via `settings-hub` testid on Consent/AgeVerif pages only; no sidebar/active/mobile test) | ⚠️ (API smoke only; no Profile form UI test) | ⚠️ (API smoke only) | ⚠️ (API smoke, 502-skip; no rate-limit, no UI) | ⚠️ (API smoke only; no toggle UI test) |
| dbt         | n/a | ⚠️ (`stg_users` generic id/timestamp tests only) | ⚠️ (`stg_users`; no accepted_values on country_code) | n/a (password not in dbt) | n/a (story §11 N/A) |

**Existing test inventory (verified by grep/read):**
- `apps/core/test/stacks_web/user_settings_controller_test.exs` — 21 tests across profile / location / password / notifications / profile_visibility / age_verification
- `apps/core/test/stacks/accounts_test.exs` — `update_profile/2` (6), `update_location/2` (4), `change_password/3` (5), `update_notifications/2` (3) + registration/auth/onboarding
- `apps/core/test/stacks/discovery/handlers/location_updated_handler_test.exs` — 7 tests
- `apps/core/test/stacks/workers/geographic_discovery_job_test.exs` — 7 tests
- `apps/core/test/stacks_web/plugs/rate_limiter_test.exs` — global/auth/upload buckets (NO `:password_change` bucket test)
- `frontend/tests/SettingsTest.elm` — Consent (5) + AgeVerification (7) ONLY; zero Profile/Password/Notifications/hub tests
- `e2e/tests/settings.spec.ts` — Consent UI (3), Profile/Account API smoke (10), AgeVerification UI (4)
- `dbt/models/staging/schema.yml` (`stg_users`) — generic column presence; `not_null`+`unique` on id, `not_null` on created_at/updated_at only

---

### Coverage tally

| Status | Count |
|--------|-------|
| ✅ STRONG | **25** |
| ⚠️ shallow | **9** |
| ❌ missing | **14** |
| n/a (covered higher up / not applicable / by-design) | **82** |

130 cells total (13 layers × 5 US × happy/sad). This is the
pre-implementation baseline; Issue #126's DoD requires regenerating this
audit to 0 ❌ / 0 ⚠️ after the punch list lands. No tests were written or
modified during this audit.

---

### Confirmed code gaps (verified against `apps/core/lib` + `frontend/src`)

| # | Gap | Evidence | Impact |
|--:|-----|----------|--------|
| CG-1 | Frontend never sends `current_password` for email changes | `frontend/src/Api.elm:733` — `updateProfile` hardcodes `currentPassword = ""` in the request body; `Page.Settings.Profile` has no current-password field | Any email change initiated from the UI returns `422 invalid_current_password` server-side. Confirmed real (matches Issue #126 Reviewer Context). |
| CG-2 | Notification prefs not loaded from server on init | `Page.Settings.Notifications.init` = all-false, no `Api.get*` fetch (US-17.3.1 §12) | Toggles render at defaults regardless of stored prefs — user can see wrong initial state. Confirmed real. Known UX gap. |
| CG-3 | `Page.Settings.{Profile,Password,Notifications}` expose only `Msg`, not `Msg(..)` | exposing block lines 1–7 of each module | Blocks Elm unit tests of message constructors (project convention: tested pages expose `Msg(..)`). Must widen exposing before L10 punch items can be written. |

---

### Full audit tables

#### Layer 1: API Calls

| US      | Happy Path | Verdict | Sad Path | Verdict |
|---------|------------|---------|----------|---------|
| 17.1.1  | n/a — the settings hub is a layout shell; it makes no API calls of its own (US-17.1.1 §3). | n/a | n/a — same. | n/a |
| 17.2.1  | ✅ user_settings_controller_test.exs — "updates display_name and website_url", "updates email when current_password is correct"; e2e/settings.spec.ts — "PUT /api/settings/profile updates display_name" | ✅ | ✅ user_settings_controller_test.exs — "returns 422 when changing email with wrong current_password", "returns 422 when changing email without current_password", "returns 422 when website_url exceeds 500 characters"; e2e — "PUT /api/settings/profile with email update requires current_password". NOTE: the 503 `service_busy` (`:argon2_busy`) branch of `update_profile/2` is untested at controller level (see punch #22). | ✅ |
| 17.2.2  | ✅ user_settings_controller_test.exs — "updates country_code and city"; e2e — "PUT /api/settings/location updates country_code and city" | ✅ | ✅ user_settings_controller_test.exs — "returns 422 for invalid country_code length"; e2e — "PUT /api/settings/location rejects invalid country_code" | ✅ |
| 17.2.3  | ✅ user_settings_controller_test.exs — "changes password with valid current_password"; e2e — "PUT /api/settings/password changes password with correct current password" (502-skip) | ✅ | ✅ user_settings_controller_test.exs — "returns 422 on wrong current_password", "returns 422 when new_password is shorter than 8 characters", "returns 422 when parameters are missing"; e2e — "rejects wrong current password", "rejects new password shorter than 8 characters". NOTE: 503 `service_busy` branch untested (punch #22). | ✅ |
| 17.3.1  | ✅ user_settings_controller_test.exs — "toggles notification preferences", "toggles all four notification fields simultaneously"; e2e — "PUT /api/settings/notifications updates notification preferences" | ✅ | ❌ Issue #126 §3 requires "PUT /api/settings/notifications — 422 on changeset errors" — no test drives `update_notifications/2` to a changeset error at HTTP level (the only negative context test, "unknown keys are silently ignored", returns `{:ok, _}`). | ❌ |

#### Layer 2: Auth & Middleware Guards

| US      | Happy Path | Verdict | Sad Path | Verdict |
|---------|------------|---------|----------|---------|
| 17.1.1  | ⚠️ Server-side: all `/api/settings/*` routes sit behind `:api, :authenticated` (router.ex:196-203) and 401 is proven at the endpoint layer (US-17.2.x tests). BUT the client-side guard `requiresAuth Settings` (redirect of unauthenticated users away from `/settings*`) has no Elm or Playwright test. | ⚠️ | ⚠️ No test asserts an unauthenticated browser hitting `/settings` (or any settings sub-route) is redirected to login — the hub's own auth guard is unverified end to end. | ⚠️ |
| 17.2.1  | ✅ user_settings_controller_test.exs — "updates display_name and website_url" (authenticated via `auth_conn/2`, reads `Guardian.Plug.current_resource`) | ✅ | ✅ user_settings_controller_test.exs — "returns 401 when not authenticated"; e2e — "settings endpoints return 401 when not authenticated" (loops profile/location/notifications/password/profile_visibility) | ✅ |
| 17.2.2  | ✅ user_settings_controller_test.exs — "updates country_code and city" (authenticated) | ✅ | ✅ user_settings_controller_test.exs — "returns 401 when not authenticated"; e2e 401 loop (location) | ✅ |
| 17.2.3  | ✅ user_settings_controller_test.exs — "changes password with valid current_password" (authenticated) | ✅ | ⚠️ 401 is covered (user_settings_controller_test.exs — "returns 401 when not authenticated" + e2e 401 loop). BUT the distinctive guard for this story — the stricter `:password_change` bucket (3/min, router.ex:247, pipeline `:rate_limit_password_change`) — has ZERO tests: `rate_limiter_test.exs` covers `:global`, `:auth`, and `:upload` buckets only, and no integration test hits `PUT /api/settings/password` a 4th time to assert 429 (punch #3). | ⚠️ |
| 17.3.1  | ✅ user_settings_controller_test.exs — "toggles notification preferences" (authenticated) | ✅ | ✅ user_settings_controller_test.exs — "returns 401 when not authenticated"; e2e 401 loop (notifications) | ✅ |

#### Layer 3: Database Interactions

| US      | Happy Path | Sad Path |
|---------|------------|----------|
| 17.1.1  | n/a — settings hub is a layout component; no DB access (US-17.1.1 §5). | n/a — same. |
| 17.2.1  | ✅ accounts_test.exs — "updates display_name and website_url" (`profile_changeset` → `op.users` UPDATE), "updates email when current_password is correct" (`Ecto.Multi` `:profile`+`:email`, `verify_password` gate) | ✅ accounts_test.exs — "returns error when website_url exceeds 500 characters", "returns :invalid_password when current_password is wrong for email change", "returns :invalid_password when current_password is missing for email change", "returns error on duplicate email" |
| 17.2.2  | ✅ accounts_test.exs — "updates country_code and city" (`location_changeset` → `op.users` UPDATE) | ✅ accounts_test.exs — "returns error when country_code is not exactly 2 characters", "returns error when city exceeds 200 characters" |
| 17.2.3  | ✅ accounts_test.exs — "changes password when current_password is correct" (`password_hash` UPDATE), "old password no longer authenticates after change" (proves new Argon2 hash persisted + both verify_pass and hash_pwd_salt ran) | ✅ accounts_test.exs — "returns :invalid_password when current_password is wrong", "returns changeset error when new_password is too short" |
| 17.3.1  | ✅ accounts_test.exs — "toggles all four notification fields" (`notifications_changeset` → `op.users` UPDATE, asserts all 4 columns) | ⚠️ Issue #126 §4 requires asserting the schema defaults (`notify_marketplace: true`, `notify_group_invitations: true`, others false) — no test asserts default notification values on a fresh user (punch #4). The only negative context test ("unknown keys are silently ignored") does not exercise a changeset error. |

#### Layer 4: Event Flow & Lifecycle

| US      | Happy Path | Sad Path |
|---------|------------|----------|
| 17.1.1  | n/a — hub emits no events (US-17.1.1 §6). | n/a — same. |
| 17.2.1  | ⚠️ accounts_test.exs — "emits user.profile_updated event on success" — but asserts `event_count(...) == before + 1` ONLY; the Issue §5 payload requirement `%{display_name: ...}` is never asserted (punch #5). | ❌ No test that `user.profile_updated` is NOT emitted when the update fails (invalid changeset, or the `:email` step of the `Ecto.Multi` rolls back) (punch #6). |
| 17.2.2  | ⚠️ accounts_test.exs — "emits user.location_updated event with correct payload" — despite its name, asserts `event_count(...) == before + 1` ONLY; payload `%{country_code, city}` is not asserted (punch #7). | ❌ No negative-emission test: `user.location_updated` absent after a changeset failure (bad country_code) (punch #8). |
| 17.2.3  | ✅ accounts_test.exs — "emits user.password_changed event on success" (payload is `%{}` by design, so count is sufficient) | ✅ accounts_test.exs — "does not emit event when current_password is wrong" (genuine negative-emission test) |
| 17.3.1  | ⚠️ accounts_test.exs — "emits user.notifications_updated event with current preference values" — asserts count only; Issue §5 payload (all 4 notify_* fields) not asserted (punch #9). | ❌ No negative-emission test on changeset failure (punch #10). |

#### Layer 5: Background Jobs (Oban)

| US      | Happy Path | Sad Path |
|---------|------------|----------|
| 17.1.1  | n/a — layout shell, no jobs (US-17.1.1 §7). | n/a — same. |
| 17.2.1  | n/a — profile save is synchronous; no Oban job (US-17.2.1 §7). | n/a — same. |
| 17.2.2  | ✅ location_updated_handler_test.exs — "enqueues GeographicDiscoveryJob for atom-keyed payload", "enqueues GeographicDiscoveryJob for string-keyed payload"; geographic_discovery_job_test.exs — "enqueues SourceDiscoveryJob for each search query", "enqueues exactly 5 queries per city", "includes location in enqueued job args" (full `user.location_updated` → handler → job → per-query enqueue chain). | ✅ location_updated_handler_test.exs — "ignores unrelated events", "ignores location_updated event with missing city", "…missing country_code", "…non-string city", "…empty payload" |
| 17.2.3  | n/a — password change is synchronous; no Oban job (US-17.2.3 §7). | n/a — same. |
| 17.3.1  | n/a — notification toggle is synchronous; no Oban job (US-17.3.1 §7). | n/a — same. |

#### Layer 6: External Service Calls

| US      | Happy Path | Sad Path |
|---------|------------|----------|
| 17.1.1  | n/a — no external calls (US §8). | n/a |
| 17.2.1  | n/a — profile/email save is local. The only quasi-external is `ArgonPool` CPU-gating on email changes; the 503 `service_busy` mapping is tracked under punch #22 (L1), not a network dependency. | n/a |
| 17.2.2  | n/a — the location UPDATE itself makes no external call. The downstream Brave Search lookup is issued by `SourceDiscoveryJob` (enqueued via `GeographicDiscoveryJob`), covered by the discovery suite, not the settings path (US-17.2.2 §8 "Future"). | n/a |
| 17.2.3  | n/a — password change is local (Argon2 CPU only). 503 mapping under punch #22. | n/a |
| 17.3.1  | n/a — no external calls (US-17.3.1 §8). | n/a |

#### Layer 7: Storage (R2 / Local)

| US      | Happy Path | Sad Path |
|---------|------------|----------|
| all     | n/a — no settings story touches object storage (US-17.*.§9 all N/A). | n/a — same. |

#### Layer 8: Cache Interactions

| US      | Happy Path | Sad Path |
|---------|------------|----------|
| all     | n/a — no cache sits in any settings read/write path (US-17.*.§10 all N/A). | n/a — same. |

#### Layer 9: dbt Model Dependencies

| US      | Happy Path | Sad Path |
|---------|------------|----------|
| 17.1.1  | n/a — hub does not read/write any dbt model (US-17.1.1 §11). | n/a |
| 17.2.1  | ⚠️ `stg_users` exists (proto-generated) and exposes `display_name`, `website_url`, `email` columns; but `schema.yml` (dbt/models/staging/schema.yml:115) has tests only on `id` (`not_null`+`unique`) and `created_at`/`updated_at` (`not_null`) — no test on the profile columns this story writes (punch #11). | n/a — no distinct sad-path dbt assertion for profile writes. |
| 17.2.2  | ⚠️ `stg_users` exposes `country_code` and `city` columns, but there is no `accepted_values`/format test on `country_code` (2-letter) and no test asserting location columns propagate (punch #12). | n/a |
| 17.2.3  | n/a — password changes do not affect any dbt model (US-17.2.3 §11). | n/a |
| 17.3.1  | n/a — US-17.3.1 §11 marks dbt N/A (the notify_* columns exist in `stg_users` but the story does not claim dbt coverage). | n/a |

#### Layer 10: Elm Frontend State Machine

| US      | Happy Path | Sad Path |
|---------|------------|----------|
| 17.1.1  | ❌ No test for the `Page.Settings` hub: `Settings.view` sidebar rendering, `viewSidebarItem` active-state (`settings-hub__nav-item--active`), or `SettingsMobileNavChanged path` → `Nav.pushUrl`. `SettingsTest.elm` covers Consent + AgeVerification only (punch #13). | ❌ Same — no hub state-machine or view test at all. |
| 17.2.1  | ❌ No `Page.Settings.Profile` test: `Profile.init user`, `SetDisplayName`/`SetEmail`/`SetWebsiteUrl` (reset `savingProfile`), `SaveProfile` → `Api.updateProfile` → `SaveProfileCompleted (Ok _)` → `Success ()`. Blocked by CG-3 (module exposes `Msg`, not `Msg(..)`) (punch #14). | ❌ No test for `SaveProfileCompleted (Err _)` → `Failure err` / "Could not save profile." (punch #15). |
| 17.2.2  | ❌ No `Page.Settings.Profile` location test: `SetCountryCode`/`SetCity` (reset `savingLocation`), `SaveLocation` → `Api.updateLocation` → `SaveLocationCompleted (Ok _)` (punch #16). | ❌ No test for `SaveLocationCompleted (Err _)` → `Failure err` / "Could not save location." (punch #17). |
| 17.2.3  | ❌ No `Page.Settings.Password` test: `Password.init` (empty fields, `saving = NotAsked`), `SavePassword` valid → `Api.updatePassword`, `SaveCompleted (Ok _)` → model reset with `saving = Success ()` (fields cleared). Blocked by CG-3 (punch #18). | ❌ No test for `validate model` branches (new password <8, mismatch, empty current) or `SaveCompleted (Err _)` → "Current password is incorrect." (punch #19). |
| 17.3.1  | ❌ No `Page.Settings.Notifications` test: `Notifications.init` (all false), `TogglePriceDrops`/`ToggleNewReviews`/`ToggleAuthorUpdates`/`ToggleEventAlerts` flip + immediate `savePreferences`, `SaveCompleted (Ok _)` → `Success ()`. Blocked by CG-3 (punch #20). | ❌ No test for `SaveCompleted (Err _)` → `Failure err` / "Could not save notification preferences." (punch #21). |

#### Layer 11: Operational Metrics

| US      | Happy Path | Sad Path |
|---------|------------|----------|
| all     | n/a — per-route latency and Oban job counts are covered by the SLO gate (`scripts/check-slo-gate.sh` scrapes `/internal/metrics` post-deploy) plus automatic Phoenix endpoint / Oban telemetry. Per project convention, per-US repetition of firing tests adds no guarantee. | n/a — Issue #126 §12 enumerates settings-specific metrics (profile/location/password success-failure rates, email-change rejection rate, `:password_change` rate-limiter trigger count, Argon2 timings, toggle-flip distribution). NONE are instrumented in `UserSettingsController`/`Accounts` and no settings mention appears in any telemetry test. Per convention this is left n/a; formal §12 instrumentation + firing tests would be a separate observability issue, not #126 scope. |

#### Layer 12: Performance & Usability Metrics

| US      | Happy Path | Sad Path |
|---------|------------|----------|
| all     | n/a — covered by the SLO gate, not unit tests; in-test SLA bounds (US-17.*.§14 targets like <200ms save, <50ms hub load, two-Argon2 password latency) are an anti-pattern under variable CI timing. Usability funnels (form abandonment, sub-page discovery, toggle responsiveness) are dashboard concerns. | n/a — same. |

#### Layer 13: Cost Tracking

| US      | Happy Path | Sad Path |
|---------|------------|----------|
| all     | n/a — settings writes are local `op.users` UPDATEs + one `event_log` INSERT each (negligible Neon cost); no per-call external spend is recorded in `BudgetTracker`. Argon2 CPU (password/email changes) and the future Brave discovery spend (US-17.2.2 §15, downstream `SourceDiscoveryJob`) are dashboard/compute-level concerns, not per-settings-call costs. | n/a — same. |

---

### Punch list (baseline — 0 items resolved)

Every ❌/⚠️ cell converted to a numbered item. No tests were written or
modified during this audit (pre-implementation baseline). Layer-10 items
are blocked on code-gap CG-3 (widen module exposing to `Msg(..)`).

| # | Cell | What's needed | Where it belongs |
|--:|------|---------------|------------------|
| 1 | L1 17.3.1 sad ❌ | `PUT /api/settings/notifications` returns 422 on a changeset error (drive `notifications_changeset` to an invalid value) | `apps/core/test/stacks_web/user_settings_controller_test.exs` |
| 2 | L2 17.1.1 happy+sad ⚠️ | Auth-guard test: unauthenticated user at `/settings` (and a sub-route) is redirected to login — Elm `requiresAuth`/`initPageAuthenticated` unit test and/or Playwright redirect | `frontend/tests/` (new hub test) and/or `e2e/tests/settings.spec.ts` |
| 3 | L2 17.2.3 sad ⚠️ | `:password_change` bucket (3/min): 4th `PUT /api/settings/password` within the window returns 429 — plug-level test in `rate_limiter_test.exs` (bucket: `:password_change`) plus an integration test through the router pipeline | `apps/core/test/stacks_web/plugs/rate_limiter_test.exs` + `user_settings_controller_test.exs` |
| 4 | L3 17.3.1 sad ⚠️ | Assert notification schema defaults on a fresh user (`notify_marketplace: true`, `notify_group_invitations: true`, `notify_wishlist_availability: false`, `notify_event_matches: false`) | `apps/core/test/stacks/accounts_test.exs` (or a `User` changeset/schema test) |
| 5 | L4 17.2.1 happy ⚠️ | Extend "emits user.profile_updated event on success" to assert payload `%{display_name: ...}`, not just count | `apps/core/test/stacks/accounts_test.exs` |
| 6 | L4 17.2.1 sad ❌ | Negative emission: no `user.profile_updated` row after an invalid profile changeset / rolled-back email `Ecto.Multi` | `apps/core/test/stacks/accounts_test.exs` |
| 7 | L4 17.2.2 happy ⚠️ | Extend "emits user.location_updated event with correct payload" to actually assert `%{country_code, city}` payload | `apps/core/test/stacks/accounts_test.exs` |
| 8 | L4 17.2.2 sad ❌ | Negative emission: no `user.location_updated` after a changeset failure (bad country_code) | `apps/core/test/stacks/accounts_test.exs` |
| 9 | L4 17.3.1 happy ⚠️ | Extend "emits user.notifications_updated event…" to assert the 4-field payload | `apps/core/test/stacks/accounts_test.exs` |
| 10 | L4 17.3.1 sad ❌ | Negative emission: no `user.notifications_updated` on changeset failure | `apps/core/test/stacks/accounts_test.exs` |
| 11 | L9 17.2.1 happy ⚠️ | dbt tests on `stg_users` profile columns (e.g. `not_null` where appropriate) — must go via the proto manifest / `mix proto.sync` generator or a singular test (schema.yml is proto-generated) | proto-sync generator or `dbt/tests/singular/` |
| 12 | L9 17.2.2 happy ⚠️ | dbt `accepted_values`/length test on `stg_users.country_code` (2-letter) — same proto-sync caveat as #11 | proto-sync generator or `dbt/tests/singular/` |
| 13 | L10 17.1.1 happy+sad ❌ | Elm hub tests: `Settings.view` renders `settings-hub__sidebar` with 6 nav items, `viewSidebarItem` applies `--active` for the current route, `SettingsMobileNavChanged path` → `Nav.pushUrl` | new `frontend/tests/Page/SettingsHubTest.elm`; plus Playwright sidebar/active/mobile-select in `e2e/tests/settings.spec.ts` |
| 14 | L10 17.2.1 happy ❌ | `Page.Settings.Profile` happy: `init`, field setters, `SaveProfile` → `SaveProfileCompleted (Ok _)`. Requires CG-3 first. | new `frontend/tests/Page/SettingsProfileTest.elm`; Playwright profile-form UI |
| 15 | L10 17.2.1 sad ❌ | `Page.Settings.Profile` sad: `SaveProfileCompleted (Err _)` → `Failure`/"Could not save profile." | same file as #14 |
| 16 | L10 17.2.2 happy ❌ | `Page.Settings.Profile` location happy: `SetCountryCode`/`SetCity`, `SaveLocation` → `SaveLocationCompleted (Ok _)` | same Profile test file; Playwright location-form UI |
| 17 | L10 17.2.2 sad ❌ | `SaveLocationCompleted (Err _)` → `Failure`/"Could not save location." | same file as #16 |
| 18 | L10 17.2.3 happy ❌ | `Page.Settings.Password` happy: `init`, valid `SavePassword` → `Api.updatePassword`, `SaveCompleted (Ok _)` resets fields with `saving = Success ()`. Requires CG-3. | new `frontend/tests/Page/SettingsPasswordTest.elm`; Playwright password-form UI |
| 19 | L10 17.2.3 sad ❌ | `Page.Settings.Password` sad: `validate` branches (short/mismatch/empty current), `SaveCompleted (Err _)` → "Current password is incorrect." | same file as #18 |
| 20 | L10 17.3.1 happy ❌ | `Page.Settings.Notifications` happy: `init` all-false, toggle msgs flip + auto-save, `SaveCompleted (Ok _)` → `Success ()`. Requires CG-3. | new `frontend/tests/Page/SettingsNotificationsTest.elm`; Playwright toggle UI |
| 21 | L10 17.3.1 sad ❌ | `Page.Settings.Notifications` sad: `SaveCompleted (Err _)` → `Failure`/"Could not save notification preferences." | same file as #20 |
| 22 | L1 17.2.1 & 17.2.3 sad (503) | Controller-level test that `update_profile`/`update_password` map `{:error, :argon2_busy}` → HTTP 503 with `retry-after: 5` (mock `ArgonPool` saturation) | `apps/core/test/stacks_web/user_settings_controller_test.exs` |

#### Code-gap punch items (feature fixes, may spawn new issues per scope-lock)

| # | Gap | Action |
|--:|-----|--------|
| CG-1 | `Api.updateProfile` hardcodes `currentPassword = ""` (`frontend/src/Api.elm:733`); Profile page has no current-password input | Add a current-password field to `Page.Settings.Profile` and thread it into `Api.updateProfile` so UI email changes can succeed. Likely a new issue (frontend feature, not test-only). |
| CG-2 | `Page.Settings.Notifications.init` starts all-false and never fetches saved prefs | Load current preferences on init (needs a `GET` endpoint or auth-flag hydration). Known UX gap; likely a new issue. |
| CG-3 | `Page.Settings.{Profile,Password,Notifications}` expose only `Msg` | Widen exposing to `Msg(..)` (project convention for tested pages) — prerequisite for punch #14–#21. In-scope for #126 (enables the tests). |

---

### Verdict

**Baseline established — audit NOT yet resolved.** State across the
13-layer × 5-US matrix (130 cells):

- **25 ✅ STRONG** — the Elixir surface is genuinely well covered:
  controller + context tests for all four mutating endpoints (profile,
  location, password, notifications), the full `user.location_updated` →
  handler → `GeographicDiscoveryJob` background chain, and the
  password-change negative-emission test.
- **9 ⚠️ shallow** — hub auth-guard (client-side untested), password
  `:password_change` rate-limit bucket untested, notification defaults
  unasserted, three event cells asserting count-not-payload, and two
  `stg_users` dbt cells with generic-only column tests.
- **14 ❌ missing** — the notifications 422 path, three event
  non-emission-on-failure cells, and all ten Layer-10 Elm cells (no
  `Page.Settings.{hub,Profile,Password,Notifications}` tests exist).
- **82 n/a** — storage, cache, external services, cost, performance, and
  operational metrics across all five stories (SLO gate / genuinely N/A),
  plus the layout-shell layers of US-17.1.1.

**Headline findings:**
1. **Elm is the big hole.** `SettingsTest.elm` covers only Consent and
   AgeVerification — none of #126's five stories has a single frontend
   state-machine test, and the three target modules don't even expose
   `Msg(..)` (CG-3) so the tests can't be written until exposing is
   widened. E2E is API-smoke only; no Profile/Password/Notification/hub
   UI flow is exercised.
2. **US-17.2.2 is better than its story doc claims.** The geographic
   discovery sweep the doc marks "not yet implemented" is in fact wired
   (`LocationUpdatedHandler` → `GeographicDiscoveryJob`) and well tested —
   Layer 5 is the strongest cell in the matrix.
3. **Two named security/UX mechanisms are untested:** the `:password_change`
   3/min rate-limit bucket (only `:auth` is tested) and the `503
   service_busy` Argon-pool-exhaustion mapping. Plus two confirmed code
   gaps — the frontend never sends `current_password` for email changes
   (CG-1) and notification prefs aren't loaded on init (CG-2).

**Test runner totals at baseline (settings-relevant):** Elixir — 21
controller tests + 18 `Accounts` settings-context tests + 7 handler + 7
job = ~53 tests; Elm — 12 `SettingsTest.elm` tests (Consent/AgeVerif only,
0 for the 5 target stories); Playwright — 17 in `settings.spec.ts`; dbt —
generic `stg_users` column tests only. Punch list: **22 test items + 3
code-gap items**, of which punch #14–#21 are blocked on CG-3.
## Definition of Done
- [ ] All 11 test categories implemented with specific test cases listed above
- [ ] Tests pass with `TEST_TARGET=local`
- [ ] No flaky tests
- [ ] `just verify` passes
- [ ] **Test audit (embedded above) is GREEN** — every 13-layer × user-story cell is `✅` or `n/a`-with-rationale; 0 `❌`, 0 `⚠️` (all punch-list items resolved). Regenerate the embedded audit tables + tally as the final step so the section reflects the shipped state.

## Dependencies
Requires Accounts context, UserSettingsController, Settings hub Elm layout.

## Agent Assignment
testing-agent

## Progress Notes
[Updated by agents during execution.]
