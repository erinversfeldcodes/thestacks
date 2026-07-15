# Issue #212: Set / change handle in Settings

## Summary
Let a user change their handle from **Settings → Profile**, reusing the existing
`PUT /api/settings/profile` mutation. Backend accepts/returns `handle` and `/me` exposes it;
the Elm settings-profile page gains the editable field with 422 handling (taken / reserved /
bad format). **Backend is DONE; the Elm handle input is not yet built.**

## User Stories
- **US-10.5.1** — Claim a Public Handle (`docs/user_stories/US-10.5.1-public-handle.md`) — the editable-field half.

## Goal
A user edits their handle in Settings → Profile, saves, sees "Saved!" with the normalised
(lowercase) value, and gets a specific field error on taken/reserved/bad-format — with no new endpoint.

## Scope Check
- >3 controllers? No (extends `UserSettingsController` only, 0 new).
- >2 new endpoints? No (0 — reuses `PUT /api/settings/profile`).
- >~300 LOC? No.
- Combines unrelated concerns? No.

## Wiring
- [x] User-facing when complete (settings-profile page, existing route).
- [ ] Implementation only.

## Feature-Completeness Pre-Check

| User Story | Happy-path hops (file:line) | Live-drive result | Verdict | Resolution |
|-----------|------------------------------|-------------------|---------|------------|
| US-10.5.1 — Claim a Public Handle (settings-edit half) | Backend: `profile_changeset/2` accepts `handle` (`apps/core/lib/stacks/accounts.ex:71`) → `update_profile/2` (:628) → 200 returns handle; `ProtoJSON.@user_auth_fields` exposes handle on `/me` (`apps/core/lib/stacks_web/proto_json.ex:39`). **Frontend: `Page.Settings.Profile` has NO handle field yet** (`frontend/src/Page/Settings/Profile.elm` — no `handle`/`SetHandle`). | 🟡 backend green; **not live-drivable in the UI** — no field to edit | 🟡 | build the Elm `SetHandle` field + 422-error rendering in this issue |

Verdict: 🟡 partial — backend built end-to-end; the missing hop is the Elm input. Build it in-scope (below), do not defer.

## Technical Requirements
- **Backend (DONE):** `profile_changeset/2` already whitelists `handle` and delegates to `validate_handle/1` (#211); `update_profile/2` runs it in the profile Multi; `@user_auth_fields` includes `:handle` so `/me` and login carry it.
- **Frontend (PENDING):** `Page.Settings.Profile` gains `handle : String` in the model (seeded from the current user), a `SetHandle String` Msg, the input in the view, and `SaveProfileCompleted (Err 422)` rendering the `handle` changeset error under the field. Map the three server errors to the US copy: taken → "That handle is already taken.", reserved → "That handle is reserved.", bad format → "Handle must be 3–30 characters: lowercase letters, numbers, underscores."
- No new endpoint, no new route.

## Reviewer Context
- The mutation is the **existing** `PUT /api/settings/profile`; do not add a handle-specific endpoint.
- `Guardian.Plug.put_current_resource(conn, user)` sets the resource in test conns (not `assign`).
- The controller returns the whole profile shape — the front end must read `handle` back from the 200 response to reflect the normalised lowercase value.

## Test Audit
COMPACT — small settings edit reusing an existing endpoint; the state-machine layer is the outstanding work.

| Layer | Applies? | Verdict |
|-------|----------|---------|
| DB / context validation | yes | ✅ `accounts_test.exs:136` `update_profile/2 sets a valid new handle (normalised to lowercase)`; `:142` `…rejects a reserved handle`; `:148` `…rejects a handle already taken (case-insensitive)`. |
| API calls (happy) | yes | ⚠️ context-level only — `PUT /api/settings/profile` returning `handle` in the 200 body is **not** asserted at the controller layer. `user_settings_controller_test.exs` describe `"PUT /api/settings/profile"` has no handle case. → **punch #1** |
| API calls (sad / 422) | yes | ⚠️ 422 `{errors: {handle: [...]}}` for taken/reserved/format is proven at the context (`accounts_test`) but not through the HTTP endpoint. → **punch #1** |
| `/me` exposure | yes | ⚠️ `@user_auth_fields` includes `:handle` but no test asserts `GET /api/auth/me` returns it. → **punch #2** |
| Auth guards | yes | ✅ own-account-only via `:authenticated` — covered by existing `user_settings_controller_test.exs` `"returns 401 when not authenticated"` on the profile route. |
| Elm state machine | yes | ❌ **no** `handle`/`SetHandle` in `Page.Settings.Profile`, and no test. Need: `SetHandle` updates the field; `SaveProfileCompleted (Err 422)` renders the field error; happy path reflects the lowercased value. → **punch #3** (feature + test) |
| Events | no | n/a — US §6: reuses `user.profile_updated` (UUID-only); no handle in `event_log`. |
| Oban / external / storage / cache | no | n/a — US §7–10. |
| dbt | no | n/a — handle warehouse-safety is asserted in #211. |
| op metrics / perf / cost | no | n/a — US §13–15: settings-endpoint SLO gate; a Neon write. |

**Visibility variations owned here:** the three 422 rejections (taken / reserved / bad-format)
and lowercase-normalisation round-trip — asserted at the context now, to be lifted to
controller + Elm by the punch items.

### Punch list
1. **API (happy+sad)** — controller test: `PUT /api/settings/profile {handle}` → 200 body includes the normalised handle; a taken/reserved/malformed handle → 422 `{errors: {handle: […]}}`. Suite: `apps/core/test/stacks_web/user_settings_controller_test.exs`.
2. **`/me` exposure** — `GET /api/auth/me` (or login) response includes `handle`. Suite: `apps/core/test/stacks_web/auth_controller_test.exs`.
3. **Elm feature + test** — build the `Page.Settings.Profile` handle input + 422 rendering; new `frontend/tests/Page/Settings/ProfileTest.elm` (or extend the existing profile test): `SetHandle` updates; `SaveProfileCompleted (Err 422)` surfaces the taken/reserved/format message under the field.

Verdict: **AMBER** — backend context proven; **3 ❌/⚠️ punch items** (the Elm input is the real feature gap; the two controller/`/me` assertions are missing-test-feature-exists).

## Definition of Done
- [x] Backend: `profile_changeset` accepts `handle`; `PUT /api/settings/profile` returns it; `/me` exposes it.
- [x] Elm: `Page.Settings.Profile` handle field + 422 error rendering (taken/reserved/format) — `handle` model field seeded from the user, `SetHandle` Msg, `Api.ProfileError`-aware `updateProfile` (mirrors `expectRegister`), `viewHandleError` mapping raw changeset messages → US-10.5.1 copy, and success reflecting the server-normalised (lowercased) handle from the 200 body.
- [ ] **Feature-Completeness Pre-Check ✅** — the settings-edit happy path driven live in the browser (epic-level E2E).
- [x] Punch items 1–3 closed — controller happy+sad (`user_settings_controller_test.exs`: normalised 200, reserved/taken/malformed → 422 `{errors:{handle}}`), `/me` handle exposure (`auth_controller_test.exs`), Elm feature + `frontend/tests/Page/Settings/ProfileTest.elm` (8 tests).
- [x] Tests passing — `accounts_test` + new controller/`/me` (92 Elixir, 0 failures) + Elm (798, 0 failures); `proto.sync --check` clean.
- [x] **Test audit (above) is GREEN** — 0 ❌, 0 ⚠️ (the remaining item is the epic browser E2E).
- [ ] **Meets the Completion Bar** (`docs/agents/standards/completion-bar.md`) — pending the epic live-drive.

## Dependencies
#211 (handle schema + `validate_handle/1`).

## Agent Assignment
elixir-agent (controller/`/me` assertions) + elm-agent (settings input).

## Progress Notes
Backend landed on `feat/210-public-profiles` (profile_changeset accepts handle; `/me` carries it; `accounts_test` update_profile handle cases). Elm handle input outstanding.
