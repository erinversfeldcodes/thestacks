# Plan: E2E Test Suite — Settings Hub
**Issue**: #126
**Created**: 2026-07-25
**Status**: Approved
**Epic**: #125 + #126 on integration branch `feat/125-126-e2e` (epic state: `plans/125-126-e2e-epic-state.json`)

## Context
Issue #126 validates the settings hub (5 user stories: hub layout, profile, location, password, notifications). Server-side coverage is strong; the Elm/E2E-UI hole is mostly open. Two named-story feature gaps (CG-1 email-change, CG-2 notification hydration) are **built in-scope** per the kickoff decision — the deliverable is every story working and fully tested.

## Research Summary
Re-verification (2026-07-25, researcher-126):
- **Closed since baseline**: `:password_change` plug test (#176, `rate_limiter_test.exs:256-273`); Profile `Msg(..)` + `ProfileTest.elm` (11 tests, #212, incl. 503 copy + validation copy); event payload punch items #5/#7 **resolved-inverted** — #121 made payloads PII-free, `accounts_test.exs` asserts `payload == %{}`; the issue's §5 `{display_name}`/`{country_code, city}` requirements are WRONG.
- **Audit corrections**: sidebar is **7 links** (Profile, Password, Notifications, Consent, Privacy, Audit Log, Your Data Insights — `Page/Settings.elm:56-65`); Age Verification removed (ADR-020); AgeVerification tests deleted; controller test grew 21→27 (handle feature #211/#212); password change now revokes all sessions (#178/#179); 503 `argon2_busy` mapping exists (`user_settings_controller.ex:34-38,73-77`) but is controller-untested.
- **Still open**: ~17 punch items — Elm hub/Password/Notifications/location tests, negative event emissions ×3, notification defaults, notifications 422, rate-limit router integration, 503 controller test, dbt column tests, all E2E UI flows, auth-guard redirect.
- **Code gaps**: CG-1 OPEN (`Api.elm:1718` hardcodes `currentPassword=""`; no Profile field); CG-2 OPEN (`Notifications.init` all-false, no fetch; `notify_*` not in auth/me); CG-3 half-open (Password/Notifications still bare `Msg`).
- **401-interceptor interaction**: low risk — settings sad paths surface 422 inline; 401 only on expired session (interceptor redirects). Confirm during implementation.
- `settings.spec.ts` has no vacuous guards; keep it that way (#275).

## Approach Options
- **Option A (chosen): build CG-1 + CG-2(b) in-scope, then test everything.** CG-2 via a new auth-gated `GET /api/settings/notifications`. — Approved at kickoff (human chose endpoint shape (b) over auth/me hydration (a)).
- **Option B: CG-2 via auth/me hydration.** Fewer endpoints. — Not chosen: human prefers a dedicated read endpoint.
- **Option C: de-scope CG-1/CG-2.** — Rejected by standing rule: test-only issues implement unbuilt story behaviour rather than test around it.

## Human Decisions (kickoff, 2026-07-25)
- CG-1 build in-scope; CG-2 build in-scope via **`GET /api/settings/notifications`**; standing rule as in #125 plan.
- Scope re-check with CG-2(b): 1 new endpoint, 1 controller, ~150–200 production LOC total — within limits.

## Phases

### Phase 1: Re-baseline docs + live-drive feature-completeness
**Objective**: Correct the issue's stale claims; drive all 5 stories live; fill the Pre-Check table.
**Agent(s)**: testing-coordinator (combined with #125 Phase 1 — one local stack boot)
**Steps**:
1. Live-drive: hub sidebar (7 links, active class, mobile select), profile save, location save, password change (mint-session user), notification toggle round-trip. Record CG-1/CG-2 failures as the 🟡 evidence (email change 422s; toggles render wrong initial state).
2. Verify toggle labels vs backend field mapping renders correctly (Reviewer Context claim).
3. Confirm 401-interceptor interaction: an expired-session settings save redirects (interceptor), a wrong-password save renders inline 422.
4. Fill Issue #126's Pre-Check table (hops + live evidence + verdicts).
**Test Command**: n/a
**Proving gate**: 3 stories ✅ live; CG-1/CG-2 failures reproduced live (the 🟡 evidence that Phase 2 turns ✅).
**DoD Items**:
- [ ] Pre-Check table filled with live evidence; CG failures reproduced

### Phase 2a: CG-2 backend — `GET /api/settings/notifications` + CG-1 same-email tolerance
**Objective**: Auth-gated read endpoint returning the four `notify_*` fields; plus the backend half of the broadened CG-1 (Phase 1 finding: ALL UI profile saves 422 because `update_profile/2` branches on `Map.has_key?(attrs, "email")` while the frontend always sends `email`).
**Agent(s)**: elixir-agent
**Steps**:
1. Tests first: controller tests — GET 200 with the 4 fields for the current user; 401 without auth; values reflect DB state (not defaults). Plus CG-1 tolerance tests: `update_profile/2` with `email` equal to the user's current email and empty/absent `current_password` → succeeds as a profile-only update; email actually different + missing/wrong password → still 422 `invalid_current_password` (no weakening).
2. Implement: route in `:api,:authenticated` scope (`router.ex` settings block), `UserSettingsController.show_notifications/2` (or equivalent), JSON `{notify_wishlist_availability, notify_marketplace, notify_group_invitations, notify_event_matches}` — same keys the PUT echoes. In `Accounts.update_profile/2` (`accounts.ex:784` area): treat a same-email payload as no email change (route to the plain profile path).
3. **gdpr-review lens** on the diff: auth-gated user-data read; fields already erasure/export-reachable via user row; no event emission, nothing new stored; password gate for real email changes preserved.
**Test Command**: `just run mix test apps/core/test/stacks_web/user_settings_controller_test.exs` (never bare mix)
**Proving gate**: `curl` the deployed/local endpoint as an authed user → real stored values returned; 401 anonymous.
**DoD Items**:
- [ ] Endpoint + tests (200/401/values) — failing-first evidence
- [ ] gdpr-review PASS recorded

### Phase 2b: CG-1 + CG-2 frontend
**Objective**: Email changes work from the UI; notification toggles hydrate from the server.
**Agent(s)**: elm-agent
**Steps**:
1. Tests first where the harness allows (ProfileTest extensions; new NotificationsTest hydration cases — requires the `Msg(..)` widening landing in the same diff).
2. CG-1 (broadened per Phase 1): `Api.updateProfile` omits `email` from the payload when unchanged from the initial value; current-password input in `Page.Settings.Profile` shown/required when email differs, threaded through `Api.updateProfile` (encoder already carries `currentPassword`).
3. CG-2: `Api.getNotifications` → `Notifications.init` fetches via RemoteData; toggles render from Success; Loading state; on Failure show `p.error` (never silently-wrong defaults).
4. Widen `Password.elm`/`Notifications.elm` to `Msg(..)` **in the same diff as consuming tests** (elm-review trap).
5. Contract check: decoder matches Phase 2a JSON keys exactly (contract-reviewer at 2C).
**Test Command**: `cd frontend && npx elm-test`; `scripts/gen-elm-proto.sh` if any proto touched (none expected)
**Proving gate**: Live drive — change email via UI with current password → succeeds; set toggles, reload page → toggles render saved state.
**DoD Items**:
- [ ] CG-1 + CG-2 built, unit-tested, driven live
- [ ] gdpr-review PASS on the combined 2a+2b diff

### Phase 3: Elixir sad-path tests
**Objective**: Close the server-side test punch items.
**Agent(s)**: elixir-agent
**Steps** (`accounts_test.exs`, `user_settings_controller_test.exs`, `rate_limiter_test.exs`):
1. Negative event emissions: no `user.profile_updated` on failed changeset / rolled-back email Multi; no `user.location_updated` on bad country_code; no `user.notifications_updated` on failure.
2. Notification defaults on fresh user (`notify_marketplace: true`, `notify_group_invitations: true`, others false).
3. `user.notifications_updated` payload asserted `%{}` (PII-free, #121 convention).
4. Notifications 422: drive `notifications_changeset` to a cast error (e.g. non-boolean value) at HTTP level; if the implementation silently ignores invalid values, record `n/a` with rationale in the audit instead.
5. Rate-limit router integration: 4th `PUT /api/settings/password` in window → 429 (bucket `:password_change`, pinned to 3 in test setup).
6. 503 `service_busy`: controller test mapping `{:error, :argon2_busy}` → 503 + `retry-after: 5` for update_profile and update_password.
**Test Command**: `just run mix test` (targeted files)
**Proving gate**: Each new test red-first (assertion failure) where it targets untested behaviour of existing code paths.
**DoD Items**:
- [ ] Punch items 1, 4, 6, 8, 9, 10, 3-integration, 22 closed — evidence per item

### Phase 4: Elm unit tests
**Objective**: Close the Layer-10 punch items not covered in Phase 2b.
**Agent(s)**: elm-agent
**Steps**:
1. `frontend/tests/Page/SettingsHubTest.elm`: sidebar renders 7 items, `settings-hub__nav-item--active` for current route, `SettingsMobileNavChanged` → pushUrl intent.
2. `Page/Settings/PasswordTest.elm`: init empty/NotAsked; `validate` branches (short / mismatch / empty current); valid → save dispatch; `SaveCompleted (Ok _)` resets fields with Success; `(Err 422)` → "Current password is incorrect.".
3. `Page/Settings/NotificationsTest.elm` (beyond hydration): each toggle flips + auto-saves; `SaveCompleted (Ok _)` → Success; `(Err _)` → failure copy.
4. `ProfileTest.elm` extensions: location setters + `SaveLocation` happy/sad; display/email/website setters.
**Test Command**: `cd frontend && npx elm-test`
**Proving gate**: Perturbation spot-check per new file (tests fail when target behaviour is mutated).
**DoD Items**:
- [ ] Punch items 13, 16, 17, 18, 19, 20, 21 + Profile-setter residual closed

### Phase 5: E2E UI flows
**Objective**: Drive every settings story through the real UI against a live stack.
**Agent(s)**: testing-coordinator
**Steps** (`e2e/tests/settings.spec.ts`, mint-session helpers for destructive/password/rate-limit specs):
1. Hub: sidebar walk (each link → sub-page), active class, mobile `<select>` navigation, unauthenticated `/settings` → login (auth-guard, punch #2).
2. Profile: edit display name → "Profile saved."; email change with current password → success (CG-1 payoff); location save → "Location saved.".
3. Password: change via UI (minted user), fields cleared + success message; wrong current password → inline error.
4. Notifications: toggle → "Preferences saved."; **reload → toggles render persisted state** (CG-2 payoff, the story's real deliverable).
5. No vacuous guards; wait-for-presence before any wait-for-absence.
**Test Command**: `cd e2e && npx playwright test --project=chromium`
**Proving gate**: Chromium project green against the live local stack; the CG-1/CG-2 flows observed succeeding where Phase 1 observed them failing.
**DoD Items**:
- [ ] All five stories driven green in E2E; punch #2 closed

### Phase 6: dbt column tests
**Objective**: Punch items 11/12 — `stg_users` profile columns + `country_code`.
**Agent(s)**: database-agent
**Steps**:
1. `schema.yml` is proto-generated — add tests via the `mix proto.sync` generator if it supports column tests; else `dbt/tests/singular/` (e.g. `country_code` length-2-or-null; profile column presence/propagation).
2. `scripts/test-dbt.sh` + `scripts/lint-dbt.sh` green. (If roles are NOLOGIN after fresh-DB, re-apply ALTER ROLE … WITH LOGIN per CLAUDE.md.)
**Test Command**: `scripts/test-dbt.sh`
**Proving gate**: New dbt tests fail against a seeded violation (spot-check), pass against real data.
**DoD Items**:
- [ ] Punch items 11, 12 closed via generator or singular tests

### Phase 7: Regenerate audit → GREEN
**Objective**: Regenerate Issue #126's embedded audit; 0 ❌ / 0 ⚠️; Pre-Check ✅×5 with post-fix live evidence.
**Agent(s)**: testing-coordinator
**Test Command**: full fresh suites (mix test, elm-test, chromium E2E, dbt)
**Proving gate**: Audit spot-verified against fresh runs; every DoD checkbox carries an evidence token.
**DoD Items**:
- [ ] Audit GREEN, tally regenerated, punch list empty

### Parallel Execution
**Independent phases**: 2a ∥ 2b (contract fixed in plan); after 2 merge: 3 ∥ 4 ∥ 6; 5 after 2 (needs CG flows working); 7 last.
**Merge order**: 2a → 2b → 3 → 4 → 6 → 5 → 7 (foundational/backend first; E2E after features land).

## Open Questions
None — kickoff decisions recorded above. (Notifications-422 `n/a` fallback is delegated to Phase 3 with rationale required.)

## Integration Handoffs
- 2a ⇄ 2b: JSON contract `{notify_wishlist_availability, notify_marketplace, notify_group_invitations, notify_event_matches}` — exact keys, booleans; contract-reviewer verifies both sides at 2C.
- 2b → 5: selectors/testids for the new current-password input and hydrated toggles.
- Epic: merges into `feat/125-126-e2e`; `just run just ci` re-run green post-merge; gdpr-review lens evidence attached to the 2a/2b review.
