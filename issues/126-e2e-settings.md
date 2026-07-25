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

## Feature-Completeness Pre-Check
<!--
Run the `feature-completeness` skill BEFORE writing any test suites for this issue. It proves each
named user story's happy path is actually BUILT end-to-end (and driven live), not merely that tests
are missing — the gate #124 lacked (US-14.3.2 was named, the audit went GREEN, yet the feature was
deferred to #173 → the #178/#179/#180/#182 cascade).

A 🟡 PARTIAL / ❌ MISSING verdict on a named story's happy path is a BLOCKING finding, NOT a
Test-Audit cell to reclassify `n/a (see #NNN)`. Resolve it exactly one of two ways: (a) build it
in-scope (add implementation phases; a design pass FIRST for non-trivial features), or (b) de-scope
it — delete the story from Summary + User Stories above and spin out a feature issue. Baseline =
"to verify"; fill verdicts + file:line evidence when this issue is picked up.
-->

_Static trace re-verified 2026-07-25 (researcher-126). Live-drive column filled by Plan Phase 1; the two 🟡 stories (CG-1, CG-2) were built in-scope (Phases 2a/2b) and re-driven live GREEN by the orchestrator post-fix (2026-07-25/26), then covered by the Phase 5 E2E specs. All five stories now ✅._

| User Story | Happy-path hops (file:line) | Live-drive result | Verdict | Resolution |
|-----------|------------------------------|-------------------|---------|------------|
| US-17.1.1 — Settings Index Page | `Route` → `Settings.view` (`Page/Settings.elm:17`) — **7-item** sidebar + mobile `<select>` | ✅ 7 sidebar links: Profile, Password, Notifications, Consent, Privacy, Audit Log (`/settings/*`) + Your Data Insights (→`/me/insights`); `settings-hub__nav-item--active` on the current sub-route (verified "Password"@`/settings/password`); mobile `<select>` renders all 7 options. **Deviation:** `/settings` does NOT redirect to `/settings/profile` — it settles at `/settings` rendering the hub with profile as default content (2026-07-25) | ✅ | Redirect-behaviour note for Phase 5 E2E: assert hub-renders-at-`/settings`, not a `/settings/profile` redirect |
| US-17.2.1 — View and Edit Profile | `Profile.elm SaveProfile` → `Api.updateProfile` (`Api.elm:1707`) → `PUT /api/settings/profile` (`router.ex:236`) → `Accounts.update_profile/2` → `op.users` → `user.profile_updated` (empty payload, #121) | ✅ **CG-1 RESOLVED (built + re-driven live).** Backend (2a): `Accounts.update_profile/2` now branches on `email_change?/2` (normalised case-insensitive/trimmed) instead of `Map.has_key?`, so a same-email payload routes to the plain profile path (no password demanded); a genuinely different email still requires `current_password`. Frontend (2b): `Api.encodeProfileBody` omits `email`/`handle` when unchanged; a Current Password input appears only when the email differs. Orchestrator live-drive post-fix: display-name-only save → "Profile saved."; email change with correct `e2e-password` → "Profile saved."; wrong password → "Current password is incorrect." (2026-07-25/26). E2E `settings.spec.ts:638` | ✅ | Built in-scope, broadened beyond the email-only scope so display-name/website-only saves succeed without a password |
| US-17.2.2 — Set Location | `SaveLocation` → `Api.updateLocation` → `PUT /api/settings/location` (`router.ex:237`) → `location_changeset` → `user.location_updated` → `LocationUpdatedHandler` → `GeographicDiscoveryJob` (chain tested) | ✅ Country Code "GB" + City "London" → `PUT /api/settings/location` 200 → "Location saved." (2026-07-25) | ✅ | bg wiring exists contrary to story doc — audit notes it |
| US-17.2.3 — Change Password | `Password.elm validate` → `Api.updatePassword` → `PUT /api/settings/password` (`router.ex:292`, `:password_change` 3/min) → `change_password/3` (Argon2 verify+hash, revokes sessions #178/#179) → `user.password_changed` | ✅ minted user (`e2e-password`), correct current pw → `PUT /api/settings/password` 200, all 3 fields cleared, "Password changed successfully."; revokes sessions (#178/#179) confirmed via interceptor drive (2026-07-25) | ✅ | — |
| US-17.3.1 — Email Notification Preferences | Toggles → `Api.updateNotifications` → `PUT /api/settings/notifications` (`router.ex:238`) → `notifications_changeset` → `user.notifications_updated` | ✅ **CG-2 RESOLVED (built + re-driven live).** New auth-gated `GET /api/settings/notifications` (2a) + `Page.Settings.Notifications` rewritten to hold prefs as `RemoteData` — `init` fetches, `Success` renders toggles at the SAVED values, `Failure` shows `p.error` (no silently-wrong defaults) (2b). Orchestrator live-drive post-fix: minted-user toggles HYDRATE from stored state (the two `true`-default fields render "On" — proof of the server round-trip), a flip auto-saves ("Preferences saved." + `toggle--on`), and SURVIVES reload. E2E `settings.spec.ts:810` | ✅ | Built in-scope (Phases 2a/2b). Label↔field mapping (Price Drops→`notify_wishlist_availability`) confirmed rendering |

Verdict: ✅ implemented (built end-to-end + observed live) · 🟡 partial (enumerate missing hops) · ❌ missing (build in-scope or de-scope).

## Technical Requirements

### 1. Playwright UI Tests
- **Settings hub layout**: Navigate to `/settings` -> hub renders at `/settings` with profile as default content (NO redirect to `/settings/profile` — corrected per Phase 1 live-drive) + sidebar with 7 links + main content area _(corrected 2026-07-25)_
- **Sidebar items**: Profile, Password, Notifications, Consent, Privacy, Audit Log, Your Data Insights _(corrected 2026-07-25 — Age Verification removed by ADR-020 §2; Audit Log + Insights added since baseline; `Page/Settings.elm:56-65`)_
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
- `PUT /api/settings/notifications` — 422 on changeset errors (if the implementation silently ignores invalid values, record `n/a` with rationale)
- `GET /api/settings/notifications` — 200 with the four `notify_*` fields reflecting stored values; 401 without auth _(added 2026-07-25 — CG-2 build-in-scope, kickoff decision)_
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
_(corrected 2026-07-25 — #121 made all user-event payloads PII-free; the original payload requirements below were inverted)_
- `user.profile_updated` emitted with **empty payload** on profile save (PII-free per #121; asserted `accounts_test.exs:446-457`)
- `user.location_updated` emitted with **empty payload** on location save (asserted `accounts_test.exs:493-506`)
- `user.password_changed` emitted with empty payload on password change
- `user.notifications_updated` emitted with **empty payload** (assert `%{}` — currently count-only)
- Negative emissions: no event row on failed changeset / rolled-back Multi (profile, location, notifications)
- `user.location_updated` → `LocationUpdatedHandler` → `GeographicDiscoveryJob` (registered + tested, contrary to the original "no handlers" note)

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
- **Notifications**: `Notifications.init` -> fetches stored prefs via `Api.getNotifications` (RemoteData: Loading state; toggles render from Success; Failure shows `p.error`, never silently-wrong defaults) _(changed 2026-07-25 — CG-2 build-in-scope replaces the old all-false init)_
- `TogglePriceDrops`/`ToggleNewReviews`/etc. -> flip boolean, immediately call `savePreferences`
- `SaveCompleted (Ok _)` -> `saving = Success ()`
- ~~Note: Preferences not loaded from server on init (starts at defaults)~~ _(obsoleted by CG-2 build-in-scope, 2026-07-25)_

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
- ~~The frontend does not currently send `current_password` for email changes — this will fail server-side.~~ **Fixed in-scope by this issue (CG-1, Plan Phases 2a+2b). Phase 1 live-drive found CG-1 BROADER than scoped: `Accounts.update_profile/2` (`accounts.ex:784`) branches on `Map.has_key?(attrs, "email")` and the frontend sends `email` on every save, so ALL UI profile saves 422 — not just email changes. Fix is two-sided: backend treats a same-email payload as no email change (2a); frontend omits `email` when unchanged AND adds a current-password input for real email changes (2b).**
- **Phase 5 E2E gotcha (Phase 1 finding):** freshly minted `.test` users get a modal onboarding overlay (`[data-testid="onboarding-overlay"]`) that intercepts all form clicks — every settings spec must dismiss it ("Skip") before interacting.
- **Interceptor nuance (Phase 1 finding):** the #173/#178 session-expiry interceptor covers page-load 401s; a settings-save 401 renders an inline error and stays put. Not a named-story gap — candidate follow-up issue at epic finalization; E2E must not assert interceptor behaviour on save failures.
- Notification toggle labels don't match backend field names (e.g., `priceDrops` -> `notify_wishlist_availability`) — mapping, not a bug; Phase 1 live-drive confirms rendering.
- Password change rate limit is stricter than auth: 3/min vs 5/min (`:password_change` bucket; plug-tested since #176; router-integration 429 test still owed).
- ~~Notification preferences are NOT loaded from server on page init.~~ **Fixed in-scope by this issue (CG-2, Plan Phases 2a/2b): new auth-gated `GET /api/settings/notifications` + RemoteData hydration.**
- **2026-07-25:** password change revokes all sessions (#178/#179) — E2E must re-authenticate after a password change (`settings.spec.ts:425-451` already isolates for this). Event payloads are PII-free (#121) — payload assertions are `%{}`. Profile has a `handle` field since #211/#212 (tested in `ProfileTest.elm`); fold into the audit, not new scope.

## Test Audit

_Test-coverage map for this issue (13 layers × user story, happy/sad columns). Baseline generated 2026-07-08; **regenerated to GREEN 2026-07-26** as the Phase 2–6 tests landed — every `❌`/`⚠️` baseline cell is now `✅` or `n/a`-with-rationale (see Definition of Done)._

Last regenerated: 2026-07-26 (Phase 7 — all 22 punch items + CG-1/CG-2/CG-3 resolved; audit GREEN: 0 ❌ / 0 ⚠️)

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
| Elixir      | n/a (layout shell) | ✅ (controller + context: display/email/website, 422 + 503 paths) | ✅ (controller + context + handler + job) | ✅ (controller + context; 401/422/short + 503 + rate-limit 429) | ✅ (controller + context; 200/401/422 + defaults) |
| Elm unit    | ✅ (`SettingsHubTest.elm` — 8) | ✅ (`ProfileTest.elm` — profile half) | ✅ (`ProfileTest.elm` — location half) | ✅ (`PasswordTest.elm` — 17) | ✅ (`NotificationsTest.elm` — hydration + toggles) |
| Elm program | n/a (program-level behaviour validated via Playwright E2E per project convention — no elm-program-test layer for settings) | n/a | n/a | n/a | n/a |
| Python      | n/a | n/a | n/a | n/a | n/a |
| E2E         | ✅ (hub in-place, 7-link sidebar, active class, mobile `<select>`, auth guard) | ✅ (display-name save, CG-1 email-change gate) | ✅ (location save UI) | ✅ (client validation, wrong-pw 422, correct change) | ✅ (CG-2 hydrate + flip + reload persistence) |
| dbt         | n/a | ✅ (`stg_users` profile-columns propagate singular test) | ✅ (`stg_users.country_code` shape singular test) | n/a (password not in dbt) | n/a (story §11 N/A) |

**Test inventory (verified by fresh run + grep/read, 2026-07-26):**
- `apps/core/test/stacks_web/user_settings_controller_test.exs` — profile / location / password / notifications (incl. GET-notifications 200/values/401 at `:358` and the 422 non-boolean cast at `:352`) / profile_visibility
- `apps/core/test/stacks_web/user_settings_controller_argon_busy_test.exs` — `{:error, :argon2_busy}` → 503 `service_busy` + `retry-after: 5` for update_password (`:74`) and the update_profile email-change path (`:96`)
- `apps/core/test/stacks/accounts_test.exs` — `update_profile/2` / `update_location/2` / `change_password/3` / `update_notifications/2`, plus negative-emission tests (`:506` profile invalid, `:518` wrong-pw, `:533` rolled-back Multi, `:637` bad country_code, `:905` notifications), notification defaults (`:917`), and payload-`%{}` assertions (`:465` profile, `:634` location, `:952` notifications)
- `apps/core/test/stacks/discovery/handlers/location_updated_handler_test.exs` — 7 tests
- `apps/core/test/stacks/workers/geographic_discovery_job_test.exs` — 7 tests
- `apps/core/test/stacks_web/plugs/rate_limiter_test.exs` — global/auth/upload/`:password_change` buckets + router-pipeline integration: 4th `PUT /api/settings/password` in the window → 429 (`:448-471`)
- `apps/core/test/stacks/events/payload_contract_test.exs` — `user.notifications_updated` payload now conforms to the empty-keys (`~w()`) contract, mirroring its #121 siblings
- `frontend/tests/Page/SettingsHubTest.elm` — 8 (sidebar/active/mobile-select); `frontend/tests/Page/Settings/PasswordTest.elm` — 17; `frontend/tests/Page/Settings/ProfileTest.elm` — profile + location halves + CG-1 email/handle omit; `frontend/tests/Page/Settings/NotificationsTest.elm` — CG-2 hydration (Loading/Success/Failure) + toggles
- `e2e/tests/settings.spec.ts` — 21 pre-existing (Consent UI + API smoke + auth) + 6 new UI flows: hub-in-place (`:538`), sidebar walk/active (`:560`), mobile select (`:584`), auth guard (`:611`), profile+CG-1 (`:638`), location (`:683`), password validation/change (`:708`/`:761`), notifications hydrate+persist (`:810`)
- dbt singular: `dbt/tests/singular/test_stg_users_country_code_shape.sql`, `test_stg_users_profile_columns_propagate.sql`

---

### Coverage tally

| Status | Count |
|--------|-------|
| ✅ STRONG | **48** |
| ⚠️ shallow | **0** |
| ❌ missing | **0** |
| n/a (covered higher up / not applicable / by-design) | **82** |

130 cells total (13 layers × 5 US × happy/sad). **Audit GREEN (2026-07-26):**
the 9 ⚠️ and 14 ❌ baseline cells all resolved to ✅ as the Phase 2–6 punch
items landed — verified against fresh suites (elm-test 1173/0, targeted mix
178/0, dbt 2/2 PASS) plus the orchestrator's serial Playwright run (27/27,
2026-07-25/26). The 82 n/a cells are unchanged (SLO-gated / genuinely N/A /
layout-shell), each with its standing rationale.

---

### Confirmed code gaps — all RESOLVED (built in-scope, Phases 2a/2b/4)

| # | Gap | Resolution | Status |
|--:|-----|------------|--------|
| CG-1 | Frontend never sent `current_password` for email changes; Phase 1 found it BROADER — every UI profile save 422'd | Backend (2a): `Accounts.update_profile/2` branches on `email_change?/2` (normalised) — same-email payload takes the profile-only path, real email change still requires the password. Frontend (2b): `Api.encodeProfileBody` omits `email`/`handle` when unchanged; Current Password input shown only when the email differs; 422 → "Current password is incorrect." **Re-driven live GREEN** (orchestrator, 2026-07-25/26); E2E `settings.spec.ts:638`; unit `ProfileTest.elm` | ✅ RESOLVED |
| CG-2 | Notification prefs not loaded from server on init | New auth-gated `GET /api/settings/notifications` (2a, controller test `:358`); `Page.Settings.Notifications` rewritten to `RemoteData` — `init` fetches, `Success` renders saved values, `Failure` shows `p.error` (no silently-wrong defaults). **Re-driven live GREEN** — toggles hydrate + persist across reload (orchestrator); E2E `settings.spec.ts:810`; unit `NotificationsTest.elm` | ✅ RESOLVED |
| CG-3 | `Page.Settings.{Profile,Password,Notifications}` exposed only `Msg` | Widened to `Msg(..)` in the same diffs as their consuming tests (elm-review trap avoided): Profile/Notifications in 2b, Password in Phase 4 | ✅ RESOLVED |

---

### Full audit tables

#### Layer 1: API Calls

| US      | Happy Path | Verdict | Sad Path | Verdict |
|---------|------------|---------|----------|---------|
| 17.1.1  | n/a — the settings hub is a layout shell; it makes no API calls of its own (US-17.1.1 §3). | n/a | n/a — same. | n/a |
| 17.2.1  | ✅ user_settings_controller_test.exs — "updates display_name and website_url", "updates email when current_password is correct"; e2e/settings.spec.ts — "PUT /api/settings/profile updates display_name" | ✅ | ✅ user_settings_controller_test.exs — "returns 422 when changing email with wrong current_password", "returns 422 when changing email without current_password", "returns 422 when website_url exceeds 500 characters"; e2e — "PUT /api/settings/profile with email update requires current_password". NOTE: the 503 `service_busy` (`:argon2_busy`) branch of `update_profile/2` is untested at controller level (see punch #22). | ✅ |
| 17.2.2  | ✅ user_settings_controller_test.exs — "updates country_code and city"; e2e — "PUT /api/settings/location updates country_code and city" | ✅ | ✅ user_settings_controller_test.exs — "returns 422 for invalid country_code length"; e2e — "PUT /api/settings/location rejects invalid country_code" | ✅ |
| 17.2.3  | ✅ user_settings_controller_test.exs — "changes password with valid current_password"; e2e — "PUT /api/settings/password changes password with correct current password" (502-skip) | ✅ | ✅ user_settings_controller_test.exs — "returns 422 on wrong current_password", "returns 422 when new_password is shorter than 8 characters", "returns 422 when parameters are missing"; e2e — "rejects wrong current password", "rejects new password shorter than 8 characters". NOTE: 503 `service_busy` branch untested (punch #22). | ✅ |
| 17.3.1  | ✅ user_settings_controller_test.exs — "toggles notification preferences", "toggles all four notification fields simultaneously", GET `:358` "returns the four notify_* fields" / "reflects stored DB values, not schema defaults"; e2e — "PUT /api/settings/notifications updates notification preferences" | ✅ | ✅ **RESOLVED** — user_settings_controller_test.exs:352 `PUT /api/settings/notifications` with `notify_marketplace: "banana"` → **422**. Item-4 verdict confirmed: a known key with an uncastable value IS a cast error (only UNKNOWN keys are silently ignored), so 422 is reachable — no `n/a` needed. | ✅ |

#### Layer 2: Auth & Middleware Guards

| US      | Happy Path | Verdict | Sad Path | Verdict |
|---------|------------|---------|----------|---------|
| 17.1.1  | ✅ Server-side: all `/api/settings/*` routes sit behind `:api, :authenticated` (router.ex:196-203) and 401 is proven at the endpoint layer. Client-side guard now covered: e2e settings.spec.ts:611 asserts an unauthenticated browser at `/settings` renders the login form (`requiresAuth _ -> PageLogin`, hub absent). | ✅ | ✅ e2e settings.spec.ts:611 — unauthenticated `/settings` AND a sub-route (`/settings/notifications`) render the login form in place, hub absent, URL unchanged (punch #2 closed). | ✅ |
| 17.2.1  | ✅ user_settings_controller_test.exs — "updates display_name and website_url" (authenticated via `auth_conn/2`, reads `Guardian.Plug.current_resource`) | ✅ | ✅ user_settings_controller_test.exs — "returns 401 when not authenticated"; e2e — "settings endpoints return 401 when not authenticated" (loops profile/location/notifications/password/profile_visibility) | ✅ |
| 17.2.2  | ✅ user_settings_controller_test.exs — "updates country_code and city" (authenticated) | ✅ | ✅ user_settings_controller_test.exs — "returns 401 when not authenticated"; e2e 401 loop (location) | ✅ |
| 17.2.3  | ✅ user_settings_controller_test.exs — "changes password with valid current_password" (authenticated) | ✅ | ✅ **RESOLVED** — 401 covered as before, and the `:password_change` bucket (3/min) is now tested both at plug level (`rate_limiter_test.exs`, incl. the XFF-spoof SECURITY test `:257`) AND through the real router pipeline: `rate_limiter_test.exs:448-471` "PUT /api/settings/password through the router pipeline" — the 4th request in the window → **429** (first 3 use a wrong password so they 422 without mutating). Punch #3 closed. | ✅ |
| 17.3.1  | ✅ user_settings_controller_test.exs — "toggles notification preferences" (authenticated) | ✅ | ✅ user_settings_controller_test.exs — "returns 401 when not authenticated"; e2e 401 loop (notifications) | ✅ |

#### Layer 3: Database Interactions

| US      | Happy Path | Sad Path |
|---------|------------|----------|
| 17.1.1  | n/a — settings hub is a layout component; no DB access (US-17.1.1 §5). | n/a — same. |
| 17.2.1  | ✅ accounts_test.exs — "updates display_name and website_url" (`profile_changeset` → `op.users` UPDATE), "updates email when current_password is correct" (`Ecto.Multi` `:profile`+`:email`, `verify_password` gate) | ✅ accounts_test.exs — "returns error when website_url exceeds 500 characters", "returns :invalid_password when current_password is wrong for email change", "returns :invalid_password when current_password is missing for email change", "returns error on duplicate email" |
| 17.2.2  | ✅ accounts_test.exs — "updates country_code and city" (`location_changeset` → `op.users` UPDATE) | ✅ accounts_test.exs — "returns error when country_code is not exactly 2 characters", "returns error when city exceeds 200 characters" |
| 17.2.3  | ✅ accounts_test.exs — "changes password when current_password is correct" (`password_hash` UPDATE), "old password no longer authenticates after change" (proves new Argon2 hash persisted + both verify_pass and hash_pwd_salt ran) | ✅ accounts_test.exs — "returns :invalid_password when current_password is wrong", "returns changeset error when new_password is too short" |
| 17.3.1  | ✅ accounts_test.exs — "toggles all four notification fields" (`notifications_changeset` → `op.users` UPDATE, asserts all 4 columns) | ✅ **RESOLVED** — accounts_test.exs:917 "a freshly inserted user has the expected notification defaults" asserts the schema defaults (`notify_marketplace: true`, `notify_group_invitations: true`, `notify_wishlist_availability: false`, `notify_event_matches: false`); the changeset-error path (non-boolean value) is exercised at HTTP level (L1 sad, controller test `:352`) and context level (`:905`). Punch #4 closed. |

#### Layer 4: Event Flow & Lifecycle

| US      | Happy Path | Sad Path |
|---------|------------|----------|
| 17.1.1  | n/a — hub emits no events (US-17.1.1 §6). | n/a — same. |
| 17.2.1  | ✅ **RESOLVED (payload inverted by #121)** — accounts_test.exs:465 asserts `latest_payload("user.profile_updated", user.id) == %{}` (PII-free per #121; the baseline's `%{display_name: ...}` requirement was WRONG). Punch #5 resolved-inverted. | ✅ **RESOLVED** — accounts_test.exs:506 "does not emit … when the changeset is invalid", `:518` "… when an email change is rejected (wrong current_password)", `:533` "… when the email Multi rolls back (duplicate email)". Punch #6 closed. |
| 17.2.2  | ✅ **RESOLVED (payload inverted by #121)** — accounts_test.exs:634 asserts the `user.location_updated` payload `== %{}` (PII-free per #121; baseline `%{country_code, city}` requirement was WRONG). Punch #7 resolved-inverted. | ✅ **RESOLVED** — accounts_test.exs:637 "does not emit user.location_updated when the country_code is invalid" (bad 3-char code). Punch #8 closed. |
| 17.2.3  | ✅ accounts_test.exs — "emits user.password_changed event on success" (payload is `%{}` by design, so count is sufficient) | ✅ accounts_test.exs — "does not emit event when current_password is wrong" (genuine negative-emission test) |
| 17.3.1  | ✅ **RESOLVED (in-scope payload strip)** — accounts_test.exs:952 asserts the `user.notifications_updated` payload `== %{}`. This event previously wrote all four `notify_*` booleans into `op.event_log` (the lone #121 outlier); Phase 3 stripped it to `%{}` (mirroring profile/location/password), updated `payload_contract.ex` to `keys: ~w()` (version kept at 1 — UUID-only, no consumer depends on shape), and payload_contract_test.exs now conforms. Punch #9 resolved (payload asserted `%{}`, not the 4 fields). | ✅ **RESOLVED** — accounts_test.exs:905 "does not emit user.notifications_updated when the changeset is invalid" (non-boolean value). Punch #10 closed. |

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
| 17.2.1  | ✅ **RESOLVED** — `dbt/tests/singular/test_stg_users_profile_columns_propagate.sql` (anti-join + null-safe `is distinct from` on `display_name`/`website_url`/`country_code`/`city`) proves every source row survives staging AND the profile columns carry through unchanged. Schema.yml is proto-generated (its `render_test/1` can't express this shape), so a singular test is the correct vehicle. Non-vacuity verified (inverted predicate → FAIL 54). Punch #11 closed. | n/a — no distinct sad-path dbt assertion for profile writes. |
| 17.2.2  | ✅ **RESOLVED** — `dbt/tests/singular/test_stg_users_country_code_shape.sql` fails on any non-null `country_code` whose length ≠ 2 (the "null or exactly 2 chars" shape a generator `not_null`/`accepted_values` can't express for a nullable column). Non-vacuity verified (inverted → FAIL 54). Fresh run 2026-07-26: both singular tests PASS. Punch #12 closed. | n/a |
| 17.2.3  | n/a — password changes do not affect any dbt model (US-17.2.3 §11). | n/a |
| 17.3.1  | n/a — US-17.3.1 §11 marks dbt N/A (the notify_* columns exist in `stg_users` but the story does not claim dbt coverage). | n/a |

#### Layer 10: Elm Frontend State Machine

| US      | Happy Path | Sad Path |
|---------|------------|----------|
| 17.1.1  | ✅ **RESOLVED** — `frontend/tests/Page/SettingsHubTest.elm` (8): 7 sidebar links with correct labels + canonical `href`s; exactly-one `settings-hub__nav-item--active` following the current route; mobile `<select>` renders all 7 options and its `onInput` produces the `onMobileNavChange` intent. Perturbation captured red (active-class removed → 2 reds), reverted. Punch #13 closed. | ✅ **RESOLVED** — same file: active-state is route-driven (no active item when the route doesn't match), and the mobile-nav intent covers the navigation edge. |
| 17.2.1  | ✅ **RESOLVED** — `ProfileTest.elm`: `init` baseline, `SetDisplayName`/`SetEmail`/`SetWebsiteUrl` setters (reset `savingProfile`), `SaveProfile` dispatch, `SaveProfileCompleted (Ok _)` → `Success` + "Profile saved.", plus CG-1 `encodeProfileBody` omit-when-unchanged (email/handle) cases. CG-3 resolved (module now exposes `Msg(..)`). Punch #14 closed. | ✅ **RESOLVED** — `ProfileTest.elm`: `SaveProfileCompleted (Err 422)` → "Current password is incorrect."; non-422 → "Could not save profile." Punch #15 closed. |
| 17.2.2  | ✅ **RESOLVED** — `ProfileTest.elm` location half: `SetCountryCode`/`SetCity` (reset `savingLocation`), `SaveLocation` dispatch (token)/no-op (none), `SaveLocationCompleted (Ok _)` → `Success` + "Location saved.". Punch #16 closed. | ✅ **RESOLVED** — `ProfileTest.elm`: `SaveLocationCompleted (Err _)` → "Could not save location. Please try again." Punch #17 closed. |
| 17.2.3  | ✅ **RESOLVED** — `frontend/tests/Page/Settings/PasswordTest.elm` (17): `init` empty + `NotAsked`, setters clear a prior save result, valid input + token → `Loading`, `SaveCompleted (Ok _)` clears every field to `init` with `Success ()`. CG-3 resolved (`Msg(..)` widened in this diff). Punch #18 closed. | ✅ **RESOLVED** — `PasswordTest.elm`: all three `validate` branches (short / mismatch / empty current) block the save (stay `NotAsked`) + render their inline error; `BadStatus 422` → "Current password is incorrect."; non-422 → generic copy. Perturbation captured red (`< 8`→`< 0`), reverted. Punch #19 closed. |
| 17.3.1  | ✅ **RESOLVED** — `frontend/tests/Page/Settings/NotificationsTest.elm`: `init` fetches (RemoteData), `Success` renders toggles at SAVED values (CG-2), `TogglePriceDrops`/`ToggleNewReviews`/`ToggleAuthorUpdates`/`ToggleEventAlerts` each flip only their field + auto-save, `SaveCompleted (Ok _)` → `Success`. CG-3 resolved. Punch #20 closed. | ✅ **RESOLVED** — `NotificationsTest.elm`: `Loading` placeholder; `Failure` renders `p.error` with NO toggles (never silently-wrong defaults); `SaveCompleted (Err _)` → failure copy. Punch #21 closed. |

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

### Punch list — ALL 22 items RESOLVED (2026-07-26)

Every ❌/⚠️ cell was converted to a numbered item and closed by the Phase 2–6
work. Items 5, 7, 9 were **resolved-inverted** by #121 (the baseline's
non-empty payload requirements were wrong; the correct assertion is `%{}`) —
item 9's event additionally had its live payload stripped to `%{}` in-scope
(Phase 3). Layer-10 items (13–21) were unblocked by resolving CG-3 (`Msg(..)`
widening) in the same diffs as their consuming tests.

| # | Cell | Resolution — closing file:line |
|--:|------|-------------------------------|
| 1 | L1 17.3.1 sad | `user_settings_controller_test.exs:352` — `notify_marketplace: "banana"` → 422 (cast error is reachable). |
| 2 | L2 17.1.1 happy+sad | `e2e/tests/settings.spec.ts:611` — unauthenticated `/settings` + sub-route render login form, hub absent; hub-render coverage in `SettingsHubTest.elm`. |
| 3 | L2 17.2.3 sad | `rate_limiter_test.exs:448-471` — router-pipeline integration, 4th `PUT /api/settings/password` → 429; plug-level + XFF-spoof at `:257`. |
| 4 | L3 17.3.1 sad | `accounts_test.exs:917` — fresh-user notification defaults asserted. |
| 5 | L4 17.2.1 happy | **Resolved-inverted (#121):** `accounts_test.exs:465` asserts payload `== %{}` (PII-free), not `%{display_name}`. |
| 6 | L4 17.2.1 sad | `accounts_test.exs:506`, `:518`, `:533` — three negative-emission tests (invalid changeset / wrong-pw / rolled-back Multi). |
| 7 | L4 17.2.2 happy | **Resolved-inverted (#121):** `accounts_test.exs:634` asserts payload `== %{}`. |
| 8 | L4 17.2.2 sad | `accounts_test.exs:637` — no `user.location_updated` on bad country_code. |
| 9 | L4 17.3.1 happy | **Resolved-inverted + in-scope strip:** event's live payload reduced to `%{}` (Phase 3, `payload_contract.ex` `keys: ~w()`); `accounts_test.exs:952` asserts `%{}`; `payload_contract_test.exs` conforms. |
| 10 | L4 17.3.1 sad | `accounts_test.exs:905` — no `user.notifications_updated` on non-boolean value. |
| 11 | L9 17.2.1 happy | `dbt/tests/singular/test_stg_users_profile_columns_propagate.sql` — PASS; non-vacuity FAIL 54 when inverted. |
| 12 | L9 17.2.2 happy | `dbt/tests/singular/test_stg_users_country_code_shape.sql` — PASS; non-vacuity FAIL 54 when inverted. |
| 13 | L10 17.1.1 happy+sad | `frontend/tests/Page/SettingsHubTest.elm` (8) + `e2e/tests/settings.spec.ts:538/560/584`. |
| 14 | L10 17.2.1 happy | `ProfileTest.elm` profile half (init/setters/SaveProfile/Ok). |
| 15 | L10 17.2.1 sad | `ProfileTest.elm` — 422 → "Current password is incorrect."; non-422 → "Could not save profile." |
| 16 | L10 17.2.2 happy | `ProfileTest.elm` location half (SetCountryCode/SetCity/SaveLocation/Ok). |
| 17 | L10 17.2.2 sad | `ProfileTest.elm` — `SaveLocationCompleted (Err _)` → "Could not save location." |
| 18 | L10 17.2.3 happy | `frontend/tests/Page/Settings/PasswordTest.elm` (17) — init/valid-save/Ok-reset. |
| 19 | L10 17.2.3 sad | `PasswordTest.elm` — validate branches + 422 copy. |
| 20 | L10 17.3.1 happy | `frontend/tests/Page/Settings/NotificationsTest.elm` — hydrate + toggle flips + Ok. |
| 21 | L10 17.3.1 sad | `NotificationsTest.elm` — Loading placeholder + Failure `p.error` (no default toggles). |
| 22 | L1 17.2.1 & 17.2.3 sad (503) | `user_settings_controller_argon_busy_test.exs:74` (password) + `:96` (profile email-change) — `{:error, :argon2_busy}` → 503 + `retry-after: 5`. |

#### Code-gap punch items (feature fixes, may spawn new issues per scope-lock)

| # | Gap | Resolution (built in-scope) |
|--:|-----|-----------------------------|
| CG-1 | `Api.updateProfile` hardcoded `currentPassword = ""`; Profile page had no current-password input; ALL UI saves 422'd (Phase 1 broadening) | ✅ RESOLVED (Phases 2a+2b). Backend `email_change?/2` same-email tolerance + frontend `encodeProfileBody` omit-when-unchanged + conditional Current Password input. Re-driven live GREEN; E2E `settings.spec.ts:638`. |
| CG-2 | `Page.Settings.Notifications.init` started all-false and never fetched saved prefs | ✅ RESOLVED (Phases 2a+2b). New auth-gated `GET /api/settings/notifications` + RemoteData hydration. Re-driven live GREEN (persists across reload); E2E `settings.spec.ts:810`. |
| CG-3 | `Page.Settings.{Profile,Password,Notifications}` exposed only `Msg` | ✅ RESOLVED. Widened to `Msg(..)` alongside consuming tests (Profile/Notifications in 2b, Password in Phase 4). |

---

### Verdict

**Audit GREEN — all 22 punch items + 3 code gaps RESOLVED (2026-07-26).**
State across the 13-layer × 5-US matrix (130 cells): **48 ✅ / 0 ⚠️ / 0 ❌ /
82 n/a**. Every named user story is built end-to-end and observed working
live; the five stories' Pre-Check rows are all ✅.

- **48 ✅ STRONG** — the 25 baseline ✅ plus the 23 resolved cells: the
  notifications 422 path, notification defaults, all six event cells (three
  resolved-inverted to `%{}` per #121, three new negative-emission tests),
  the `:password_change` rate-limit 429 (plug + router integration), the
  503 `service_busy` mapping for both Argon paths, the two `stg_users` dbt
  singular tests, and all ten Layer-10 Elm cells (hub + Profile + Password +
  Notifications).
- **0 ⚠️ / 0 ❌** — the punch list is empty.
- **82 n/a** — storage, cache, external services, cost, performance, and
  operational metrics across all five stories (SLO gate / genuinely N/A),
  plus the layout-shell layers of US-17.1.1 and the Elm-program layer
  (validated via Playwright, not elm-program-test). Each carries its
  standing rationale; L11/L12's SLO-gate n/a is unchanged.

**How the baseline gaps closed:**
1. **Elm was the big hole — now filled.** Four new/extended test modules
   (`SettingsHubTest`, `PasswordTest`, `ProfileTest`, `NotificationsTest`)
   cover every one of #126's five stories at the state-machine level; CG-3
   was resolved by widening the three modules to `Msg(..)` alongside their
   consuming tests. Six new Playwright UI flows drive every story through
   the rendered Elm against the live stack (no API-smoke-only gaps remain).
2. **CG-1 and CG-2 were built in-scope**, not tested around: the same-email
   tolerance + conditional current-password input (CG-1) and the
   `GET /api/settings/notifications` read endpoint + RemoteData hydration
   (CG-2). Both re-driven live GREEN by the orchestrator post-fix.
3. **US-17.2.2's background chain** (`LocationUpdatedHandler` →
   `GeographicDiscoveryJob`) remains the strongest area, still fully tested.
4. **The two named security/UX mechanisms** — the `:password_change` 3/min
   bucket and the 503 `service_busy` Argon-pool mapping — are now both
   tested.

**Fresh verification (2026-07-26):** elm-test **1173/0**; targeted mix
(`user_settings_controller_test` + `user_settings_controller_argon_busy_test`
+ `accounts_test` + `rate_limiter_test` + `payload_contract_test`) **178
tests, 0 failures**; dbt (`test_stg_users_country_code_shape` +
`test_stg_users_profile_columns_propagate`) **PASS=2 ERROR=0**; Playwright
`settings.spec.ts` serial run **27/27** (orchestrator-verified 2026-07-25/26,
not re-run in this phase). Punch list: **0 items open.**
## Definition of Done
- [x] All 11 test categories implemented with specific test cases listed above — evidence: regenerated audit tables (0 ❌/⚠️) with per-cell file:line; fresh elm-test 1173/0, targeted mix 178/0, dbt 2/2 PASS (2026-07-26)
- [x] Tests pass with `TEST_TARGET=local` — evidence: elm-test **1173/0**, targeted mix **178 tests, 0 failures**, dbt **PASS=2 ERROR=0** (2026-07-26); Playwright `settings.spec.ts` **27/27** serial (orchestrator-verified 2026-07-25/26)
- [x] No flaky tests — evidence: preview full chromium **281 passed / 0 failed** at DEFAULT workers + epic subset incl. all 27 settings tests **62/0/0**, zero 429s (2026-07-26, `stacks-core-pr-feat-125-126-e2e.fly.dev`); mint helper live on preview (201) so no silent skips; local serial runs clean throughout. The `:auth`-bucket 4-worker artifact does not manifest on the gate environment — tracked follow-up in the epic state.
- [x] `just verify` passes — evidence: the superset epic gate `just run just ci` green (2026-07-26): elixir/coveralls, elm, rust, dbt 239, squawk/checkov, licenses, gitleaks, trufflehog, Trivy, semgrep 0 findings; sole failure = dockle/no-local-Docker-daemon (documented local-only limitation). Far-end event proof: preview `op.event_log` queried directly — `user.notifications_updated`/`profile_updated`/`location_updated` rows from the E2E run all carry `payload: {}` (Neon branch br-soft-surf-an176jqk, 2026-07-26).
- [x] **Feature-Completeness Pre-Check (above) is ✅ for every named user story** — each happy path built end-to-end and observed working on a live stack; any 🟡/❌ story is built in-scope or de-scoped. No named story reaches GREEN via `n/a (see #NNN)`. — evidence: all 5 Pre-Check rows ✅ (US-17.2.1/17.3.1 re-driven live GREEN post-fix, orchestrator 2026-07-25/26); E2E `settings.spec.ts:638`/`:810`
- [x] **Test audit (embedded above) is GREEN** — every 13-layer × user-story cell is `✅` or `n/a`-with-rationale; 0 `❌`, 0 `⚠️` (all punch-list items resolved). — evidence: tally **48 ✅ / 0 ⚠️ / 0 ❌ / 82 n/a**; punch list 0 items open; regenerated 2026-07-26
- [x] **Audit re-baselined to current code before test-writing** (7-link sidebar, ADR-020 removals, PII-free payload inversion, #176 plug test, #211/#212 handle expansion) — evidence: regenerated tables dated 2026-07-26 (Pre-Check + framework summary + full tables all reflect current code)
- [x] **CG-1 built + proven live**: email change from the UI with current password succeeds end-to-end — evidence: E2E `settings.spec.ts:638` + orchestrator live-drive (display-name-only + email-change with `e2e-password` → "Profile saved.", wrong pw → "Current password is incorrect.") 2026-07-25/26
- [x] **CG-2 built + proven live**: `GET /api/settings/notifications` + hydrated toggles; toggle → reload → persisted state renders — evidence: controller test `user_settings_controller_test.exs:358` + E2E round-trip `settings.spec.ts:810` (toggles hydrate from stored `true` defaults, flip persists across reload)
- [x] **gdpr-review PASS recorded for the CG-1/CG-2 diffs** (new user-data read endpoint auth-gated; no new stored/exported data) — evidence: GDPR Review Record below (orchestrator, 2026-07-25/26)

### GDPR Review Record (orchestrator, gdpr-review skill, 2026-07-25/26)

**Verdict: PASS** across the three data-touching diffs of this issue:

| Change (file:line) | Data class | Erasure | Export | Leak (event/audit/dbt) | Gate | Verdict |
|---|---|---|---|---|---|---|
| `GET /settings/notifications` (router.ex:238, `show_notifications/2`) — commit 8791c98c | personal (4 behavioural booleans) | ✓ columns on `op.users`, deleted with user row | — no new stored data | ✓ read-only, no emit | ✓ `[:api, :authenticated]` (router.ex:193) | PASS |
| `update_profile/2` same-email tolerance + `drop_blank_handle_change` (accounts.ex) — 8791c98c/6b167b8f | no new data | unchanged | unchanged | ✓ emits existing PII-free `user.profile_updated %{}` (test-asserted) | ✓ password gate for real email changes preserved (test-locked both layers); `profile_changeset` does not cast `:email` so a same-email payload cannot rewrite storage | PASS |
| CG-1/CG-2 frontend (Api.elm, Profile/Notifications pages) — 6b167b8f | no storage | n/a | n/a | ✓ no events; one new authed read | ✓ current_password sent over the existing authed channel only | PASS |
| `user.notifications_updated` payload → `%{}` (accounts.ex + payload_contract.ex) — 8ce44a85 | — | — | — | ✓ **net removal** of personal data from new `event_log` rows (#121-consistent; version kept, no consumer) | — | PASS |

**Pre-existing residue (predates this epic, logged in epic state for follow-up):** `GDPR.Export.export_user_data/2` user block omits `notify_*` ×4, `website_url`, `country_code`, `city`, `handle` (export.ex:67-80) — personal data missing from export; to be filed via create-issue at epic finalization.

## Dependencies
Requires Accounts context, UserSettingsController, Settings hub Elm layout.

## Agent Assignment
testing-agent

## Progress Notes
[Updated by agents during execution.]

- **2026-07-25 (Phase 1 — testing-coordinator):** Live-drove all 5 settings stories against a fresh local stack (rebuilt esbuild `app.js`, `STACKS_E2E_TEST_HELPERS=1`, seeded dev DB, minted `.test` users via `POST /api/test/session`; dismissed the first-run onboarding overlay before interacting — it intercepts form clicks). **3 ✅ live (hub, location, password); 2 🟡 with reproduced failures (CG-1, CG-2).** Hub: 7 sidebar links + `settings-hub__nav-item--active` on the current sub-route + mobile `<select>`; **`/settings` does NOT redirect to `/settings/profile`** (renders hub at `/settings`). Location save → 200 "Location saved.". Password change (minted user, current pw `e2e-password`) → 200, fields cleared, "Password changed successfully.". **CG-1 reproduced and found BROADER than scoped:** display-name-only save also 422s (`invalid_current_password`) because `Accounts.update_profile/2` (`accounts.ex:784`) routes any payload containing an `email` key through the password-verifying path and the UI always sends `email` — so EVERY UI profile save fails, not just email changes. **CG-2 reproduced:** 4 toggles (Price Drops/New Reviews/Author Updates/Event Alerts) load all-`toggle--off` (ignoring the marketplace/group-invites `true` defaults); toggle→200 "Preferences saved."→`toggle--on`; **reload → all `toggle--off` again** (init never hydrates). Interceptor interaction: a settings-save 401 surfaces inline ("Could not save profile."), NOT the global interceptor (which fires on page-load 401s) — recorded on #125. **Pre-implementation flag:** Plan Phase 2b's CG-1 (email-only current-password field) must be widened so display-name/website-only saves succeed without a password.
- **2026-07-25 (Phase 2a — elixir-agent):** Backend half landed. **CG-2 read endpoint:** `GET /api/settings/notifications` (`router.ex:238`, `:api,:authenticated` scope) → `UserSettingsController.show_notifications/2` returning the four `notify_*` booleans from the current user row (same keys the PUT echoes); read-only, no event. **CG-1 tolerance:** `Accounts.update_profile/2` now branches on a new `email_change?/2` (normalised, case-insensitive, trimmed) instead of `Map.has_key?(attrs, "email")` — a same-email payload routes to the plain profile path (no password demanded); a genuinely different email still requires `current_password` (missing/wrong → 422 `invalid_current_password`, unchanged). Failing-first evidence captured (6 reds: GET returned text/html; same-email save 422'd). Green after: `user_settings_controller_test.exs` +5 tests, `accounts_test.exs` +3 tests, full backend suite **2941 tests, 0 failures**; `mix format --check-formatted` clean; `mix credo --strict` no issues. **Normalisation flag:** email storage is inconsistent — registration/`email_changeset` cast the raw value (no downcase on write) while `get_user_by_email/1` downcases on read, so auth is case-insensitive but stored case is preserved; `email_change?/2` compares downcased+trimmed to match auth's identity semantics.
- **2026-07-25 (Phase 6 — database-agent):** Closed dbt punch items 11 & 12 for `stg_users`. **Option B (singular tests)** — the proto-sync `SchemaYmlGenerator.render_test/1` only emits `not_null`/`unique`/`accepted_values`/`relationships`, none of which can express punch #12's "null or exactly 2 chars" length shape (and the profile columns are nullable, so a generator `not_null` would be wrong); extending the generator is out of scope. Added two hand-written singular tests mirroring `dbt/tests/singular/` house style: `test_stg_users_country_code_shape.sql` (fails on any non-null `country_code` whose length ≠ 2 → punch #12) and `test_stg_users_profile_columns_propagate.sql` (anti-join + null-safe `is distinct from` on `display_name`/`website_url`/`country_code`/`city` proving every source row survives staging AND the four profile columns carry through unchanged → punch #11). No `persisted.exs`/`schema.yml` change (git clean, no proto drift). Gates: `dbt test` **PASS=239 ERROR=0** (both new tests PASS), `lint-dbt.sh` all blocking checks passed, sqlfluff clean. Non-vacuity: inverting each predicate produced **FAIL 54 / FAIL 54** ("Got 54 results, configured to fail if != 0"), reverted → PASS. **Env note:** the shared `stacks_dev` was held by 2 concurrent-agent sessions so `scripts/test-dbt.sh`'s `ecto.drop` aborted; ran `dbt run`+`dbt test` directly against the already-seeded `stacks_dev` (54 users) — read-only + `wh`-schema views only, leaving the `op` tables other agents use untouched.
- **2026-07-25 (Phase 3 — elixir-agent):** Server-side sad-path punch items closed (tests only, no production changes). `accounts_test.exs` +6: negative event emissions — no `user.profile_updated` on an invalid changeset, on a wrong-password email change (short-circuit before the Multi), or on a rolled-back email Multi (duplicate email → `:emit_event` step never fires); no `user.location_updated` on a 3-char `country_code`; no `user.notifications_updated` on a non-boolean value. Plus notification schema defaults on a fresh user (`notify_marketplace`+`notify_group_invitations` ON, `notify_wishlist_availability`+`notify_event_matches` OFF). `user_settings_controller_test.exs` +1: `PUT /api/settings/notifications` with `notify_marketplace: "banana"` → **422** (item 4 verdict: **422 IS reachable** — a known key with an uncastable value is a cast error; only UNKNOWN keys are silently ignored). New `user_settings_controller_argon_busy_test.exs` (async:false, 2 tests): saturates the global `ArgonPool` + shrinks the checkout timeout so `update_password` and the `update_profile` email-change path map `{:error, :argon2_busy}` → **503 `service_busy` + `retry-after: 5`**. `rate_limiter_test.exs` +1: router-integration — 4th `PUT /api/settings/password` in the window → **429** through the real `:rate_limit_password_change` pipeline (wrong password so the first 3 422 without mutating the user). **Item 3 — RESOLVED in-scope (orchestrator lifted the tests-only constraint for this item; amended §5 requires an empty payload, and grep confirmed no consumer reads it).** `user.notifications_updated` previously wrote all four `notify_*` booleans into `op.event_log` — the lone sibling event that carried a non-empty payload (profile/location/password were all stripped to `%{}` by #121). Red-first probe captured: `left: %{"notify_event_matches" => false, "notify_group_invitations" => true, "notify_marketplace" => true, "notify_wishlist_availability" => false}` vs `right: %{}`. Fix mirrors the #121 sibling pattern exactly: `accounts.ex` now emits `payload: %{}` with a "NO-PII #121" comment; `payload_contract.ex` entry → `%{version: 1, keys: ~w()}` (version KEPT at 1, no bump, no `Upcaster` clause — same as profile/location/password, since payloads are UUID-only and no consumer depends on the shape; the blog-title strip was the only one that needed a v2 upcaster). Characterization test flipped to assert `%{}` (now a standard "carries no PII" test like its siblings). Gates: conformance + event suites green (payload_contract/upcaster/subscriber_worker + accounts + all touched files = 189 tests, 0 failures); `mix format --check-formatted` clean; `mix credo --strict` no issues; full backend suite re-run pending.
- **2026-07-25 (Phase 2b — elm-agent):** Frontend half of CG-1 + CG-2 landed (`frontend/src/**`, `frontend/tests/**` only). **CG-1:** `Api.updateProfile` now takes `currentPassword` + `emailChanged` and builds the body via a new exposed `Api.encodeProfileBody` that OMITS both `email` and `current_password` when the email is unchanged (routes the server to its profile-only path); `Page.Settings.Profile` gained an `initialEmail` baseline + a `Current Password` input (`placeholder "Confirm your current password"`) that only appears once the email field differs (compared trimmed+lowercased, matching `email_change?/2`), blocks the save with an inline message when the password is empty, and maps the 422 `invalid_current_password` response to "Current password is incorrect." (matching the Password page). **CG-2:** new `Api.getNotifications` (strict `map4` decoder over the four `notify_*` keys) + `Page.Settings.Notifications` rewritten to hold prefs as `RemoteData` — `init` fetches, Loading renders a placeholder, `Success` renders toggles at the SAVED values, `Failure` renders a `p.error` with NO toggles (never silently-wrong defaults); `Msg(..)` widened for the tests; `Main.elm` call site updated to thread the fetch `Cmd`. **Tests:** ProfileTest +7 (CG-1), new NotificationsTest (8 cases). All gates green: **elm-test 1131/0**, `elm-format --validate` clean, `elm make src/Main.elm` Success, `elm-review` 0 errors. 5 perturbations captured red then reverted (encoder omit, save-block, 422 copy, hydration ignore-loaded, toggle flip). **Live-drive DEFERRED to orchestrator — port conflict:** dev HTTP port is hardcoded `4000` (`apps/core/config/dev.exs:28`; the `PORT` override at `config/runtime.exs:289` is inside the `:prod` block), and another agent's Phoenix already holds `:4000`; rebuilding on 4100 isn't possible without editing out-of-scope backend config.
- **2026-07-25 (Phase 4 — elm-agent):** Layer-10 Elm unit-test punch items closed (tests + one exposing-only widening; no behaviour change). New `frontend/tests/Page/SettingsHubTest.elm` (8 tests — punch 13): 7 sidebar links with correct labels + canonical `href`s, exactly-one `settings-hub__nav-item--active` following the current route, mobile `<select>` renders all 7 options and its `onInput` produces the `onMobileNavChange` intent for the chosen path (`Event.simulate (Event.input …)`). New `frontend/tests/Page/Settings/PasswordTest.elm` (17 tests — punch 18/19; widened `Page.Settings.Password` to `Msg(..)` in this diff): `init` empty + `NotAsked`; three setters update fields and clear a prior save result; all three `validate` branches (short / mismatch / empty current) block the save (stay `NotAsked`) and render their inline error; valid input + token → `Loading`, no token → no-op; `SaveCompleted (Ok _)` clears every field to `init` with `Success ()`; `BadStatus 422` → "Current password is incorrect."; non-422 → generic copy. `ProfileTest.elm` +9 (punch 16/17 + setter residual): location half — `SetCountryCode`/`SetCity` update + reset `savingLocation`, `SaveLocation` dispatch (token)/no-op (none), `SaveLocationCompleted (Ok _)` → `Success` + "Location saved.", `(Err _)` → "Could not save location. Please try again."; plus `SetDisplayName`/`SetEmail`/`SetWebsiteUrl` setter residuals (2b covered only the handle/email-change setters). `NotificationsTest.elm` +4 (punch 20/21 gap): the three remaining toggles (`ToggleNewReviews`/`ToggleAuthorUpdates`/`ToggleEventAlerts`) each flip only their field, plus a flip clears a prior save banner (`SaveCompleted (Err _)` failure copy was already covered by 2b at `NotificationsTest.elm:124`). Gates green: **elm-test 1173/0**, `elm-format src/ tests/ --validate` clean, `elm make src/Main.elm` Success, `elm-review` 0 errors. Perturbation evidence per new file: active-class removed in `Settings.elm` → 2 hub reds (Loading vs …; count 1≠0), reverted; `validate` threshold `< 8`→`< 0` in `Password.elm` → 1 red ("renders the length error": `Loading` ≠ `NotAsked`), reverted.
- **2026-07-25 (Phase 2b revision 1 — elm-agent):** Frontend half of the orchestrator's live-drive finding (unchanged handle sent as `""` → NULL write on NOT NULL `op.users.handle` → 500; the elixir side hardens `profile_changeset` to drop a nil handle change, this side stops sending the empty value). Applied the same omit-when-unchanged pattern to `handle` as to `email`: `Api.encodeProfileBody` gained a `handleChanged` flag and now omits the `handle` key unless the field was actually edited; `updateProfile` threads it. `Page.Settings.Profile` gained an `initialHandle` baseline (`init` seeds it from `user.handle` — for an injected/minted session that is `""`, so an untouched empty field is omitted and the real stored handle is preserved), a `handleChanged` helper (`model.handle /= model.initialHandle`), and rebaselines `initialHandle` to the server-echoed settled handle on a successful save (so a following untouched save also omits it, and an injected session's field settles on the real handle after its first save). ProfileTest +7 (unchanged real handle omitted, unchanged empty/injected handle omitted, edited handle included, init baseline for real + handle-less users, edit-diverges, save-rebaselines); the pre-existing email-omit test's `handle` assertion was updated to `website_url` (unchangedBody is now fully-unchanged so its handle is correctly omitted). Gates green: **elm-test 1138/0**, `elm-format --validate` clean, `elm make` Success, `elm-review` 0 errors. 3 perturbations captured red then reverted (handle-omit real, handle-omit empty via always-send encoder; initialHandle rebaseline). CG-2 confirmed PASS live by the orchestrator (toggles persist across reload); CG-1 re-drive owned by the orchestrator after both halves land.
- **2026-07-26 (Phase 7 — testing-coordinator):** Regenerated the embedded audit to GREEN. Verified (not transcribed) against fresh runs: **elm-test 1173/0**; targeted mix (`user_settings_controller_test` + `user_settings_controller_argon_busy_test` + `accounts_test` + `rate_limiter_test` + `payload_contract_test`) **178 tests, 0 failures**; dbt (`test_stg_users_country_code_shape` + `test_stg_users_profile_columns_propagate`) **PASS=2 ERROR=0**. Playwright NOT re-run — cite the orchestrator's serial 27/27 (2026-07-25/26). Tally **25 ✅ → 48 ✅ / 0 ⚠️ / 0 ❌ / 82 n/a**; all 22 punch items closed with file:line (items 5/7/9 resolved-inverted by #121, item 9's live payload additionally stripped to `%{}` in Phase 3); CG-1/CG-2/CG-3 marked RESOLVED; Pre-Check US-17.2.1 + US-17.3.1 flipped 🟡→✅ (orchestrator post-fix live-drive + Phase 5 E2E specs). L11/L12 SLO-gate n/a stands. **Flagged NOT ticked:** "gdpr-review PASS recorded" DoD item — no gdpr-review verdict is recorded anywhere in the issue/plan/epic-state (only the plan's lens *intent*); needs the actual verdict before ticking. "No flaky tests" + "just verify passes" left for the orchestrator (need repeated/full-suite runs). Edited ONLY `issues/126-e2e-settings.md`.
- **2026-07-25 (Phase 5 — testing-coordinator):** Added the E2E UI-flow layer to `e2e/tests/settings.spec.ts` (test-only; one additive import). **6 new tests** driving every settings story through the rendered Elm UI against the live local stack (`:4000`, `STACKS_E2E_TEST_HELPERS=1`, real endpoints, no `page.route` on the code under test): **Hub** — `/settings` renders the hub in place (URL stays `/settings`, Profile default) with exactly 7 sidebar links; clicking each link loads its sub-page and marks `settings-hub__nav-item--active`; mobile `<select>` (7 options) navigates. **Auth guard (punch #2)** — unauthenticated `/settings` and `/settings/notifications` render the login form (`login-submit`), hub absent, URL unchanged (`requiresAuth _ -> True` → `PageLogin` in place, no redirect). **Profile (CG-1 payoff)** — display-name-only save → "Profile saved."; email change surfaces the Current Password field only when the email differs, wrong password → "Current password is incorrect." (inputs retained), correct `e2e-password` → "Profile saved.". **Location** — country + city → "Location saved.". **Password** — client validation (short / mismatch / empty current → inline errors, ZERO PUTs observed via a request listener); wrong current password → inline 422 copy, then a correct change (LAST, since success revokes the session) → fields cleared + "Password changed successfully.". **Notifications (CG-2 payoff)** — minted-user toggles HYDRATE from stored state (New Reviews + Author Updates render "On" from the `true` schema defaults — the proof the server round-trip happened, not an all-off default), a flip auto-saves ("Preferences saved." + `toggle--on`), and SURVIVES a reload. Mutating flows mint fresh isolated `.test` users and dismiss the onboarding overlay ("Skip") before any interaction; hub/nav reuse the seeded `settings` suite user. Serial run (`--workers=1`): **27 passed, 0 failed** (21 pre-existing + 6 new). Non-vacuity captured verbatim for 2 new tests: sidebar-active perturbed to `item.label + "__PERTURBED__"` → red (`unexpected value "Profile"`); notifications-reload perturbed to expect `"Off"` → red (`Expected "Off" / Received "On"`); both reverted with Edit. Server left running.
