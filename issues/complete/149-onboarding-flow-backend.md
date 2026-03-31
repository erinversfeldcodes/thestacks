# Issue #149: Onboarding Flow — Backend Workflow & Step Tracking

## Summary
The Elm onboarding overlay component exists (Issue #057e — complete). What's missing is the backend that drives it: multi-step completion tracking, the API that reports which steps are done, a completion gate enforced server-side, and the ability to re-enter onboarding from Settings. Currently `users.onboarding_completed` is a boolean with no step granularity.

## User Stories
US-14.1.1 First-Time User Experience

## Goal
The server tracks which onboarding steps a new user has completed (profile info, age verification choice, privacy settings). The API reports current step. The Elm overlay resumes from where the user left off. After all steps are done, `onboarding_completed` is set and the overlay no longer shows on login.

## Scope Check
- Does this issue touch more than 3 controllers? → No — `OnboardingController` only.
- Does this issue add more than 2 new endpoints? → No — `GET /api/onboarding/status`, `PUT /api/onboarding/step/:step`.
- Does this issue exceed ~300 lines of production code? → Migration ~30 LOC, context ~80 LOC, controller ~60 LOC, Elm update ~100 LOC.
- Does this issue combine unrelated concerns? → No.

## Wiring
- [x] This issue includes router wiring and is user-facing when complete.

## Technical Requirements

**Migration:** Replace `onboarding_completed boolean` with a JSONB steps column:
```sql
ALTER TABLE op.users
  ADD COLUMN onboarding_steps jsonb NOT NULL DEFAULT '{}';
  -- e.g. {"profile": true, "age_verification": true, "privacy": false}
```
Keep `onboarding_completed` as a generated/computed boolean for backwards compat:
```sql
ADD COLUMN onboarding_completed boolean GENERATED ALWAYS AS (
  (onboarding_steps->>'profile')::boolean IS TRUE
  AND (onboarding_steps->>'age_verification')::boolean IS TRUE
  AND (onboarding_steps->>'privacy')::boolean IS TRUE
) STORED;
```

**Steps defined:**
1. `profile` — display name + avatar (optional)
2. `age_verification` — choice: verify age or proceed as under-18
3. `privacy` — default visibility for bookshelves (public / platform / owner)

**`Stacks.Accounts` additions:**
```elixir
onboarding_status(user_id)
  # → %{steps: %{profile: bool, age_verification: bool, privacy: bool}, completed: bool}

complete_onboarding_step(user_id, step)
  # step: :profile | :age_verification | :privacy
  # → {:ok, User} | {:error, :invalid_step}

reset_onboarding(user_id)
  # allows re-entry from Settings
  # → {:ok, User}
```

**API endpoints:**
```
GET /api/onboarding/status          → { steps: {...}, completed: bool, next_step: "profile" | null }
PUT /api/onboarding/step/:step      → 200 | 422
POST /api/onboarding/reset          → 200 (Settings → "Revisit onboarding")
```

**Elm updates (`Components.OnboardingOverlay`):**
- On mount, `GET /api/onboarding/status` to find `next_step`
- Resume from `next_step` rather than always starting at step 1
- Completing each step calls `PUT /api/onboarding/step/:step`
- After all steps done → `onboarding_completed = true` → overlay hidden

**`GET /api/auth/me` update:** Include `onboarding_completed` and `next_onboarding_step` in the me response so the app shell knows whether to show the overlay on login without an extra round-trip.

## Reviewer Context
- The generated `onboarding_completed` column avoids any risk of the boolean getting out of sync with the step data.
- `complete_onboarding_step/2` should be idempotent — completing an already-completed step is a no-op, not an error.
- The existing `Components.OnboardingOverlay` uses `onboarding_completed` flag already — check which API field it currently reads from before changing the response shape.

## Definition of Done
- [ ] Migration: `onboarding_steps` JSONB column added; generated `onboarding_completed` replaces boolean
- [ ] `complete_onboarding_step/2` is idempotent
- [ ] `GET /api/onboarding/status` returns correct `next_step` after each completion
- [ ] After all 3 steps complete, `GET /api/auth/me` shows `onboarding_completed: true`
- [ ] `POST /api/onboarding/reset` resets all steps to `false`
- [ ] Overlay resumes from correct step on re-login
- [ ] Tests cover: fresh user flow, partial completion, full completion, reset
- [ ] `just verify` passes

## Dependencies
Issue #057e (onboarding overlay component — complete)

## Agent Assignment
elixir-agent, elm-agent

## Progress Notes
