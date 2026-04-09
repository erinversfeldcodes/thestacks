# US-8.3 — Consent Management

## 1. User Story

> **As a** user, **I want to** manage my consent preferences with clear timestamps **so that** I know exactly what I've agreed to and when.

The user navigates to Settings > Privacy & Consent. They see a list of consent items, each with a toggle and a timestamp of when it was last changed.

**What they see on the page:**
- A clean list of consent items: data collection, review aggregation, price scraping, image processing, analytics, AI writing assistant personalisation.
- Each item has: a clear description of what it covers, a toggle (on/off), and a timestamp ("Consented: 2026-01-15 14:32 UTC").
- The AI writing assistant personalisation item reads: *"Your shelf and writing history are used to personalise writing suggestions. Disabling this turns off the writing assistant and deletes your session history and embeddings."*
- Changes are logged in the audit trail immediately.

---

## 2. UI Interaction Flow

### Happy Path
1. User navigates to `/settings/consent`.
2. Page renders with the current analytics consent state (on/off toggle).
3. User clicks toggle to change consent.
4. User clicks "Save Preferences."
5. System sends `POST /api/gdpr/consent` with `{ consent: true/false }`.
6. System responds with the updated consent state and timestamp.
7. UI shows "Saved!" confirmation.

### Sad Paths
- **Invalid consent value**: If `consent` is not a boolean, the system returns HTTP 422 with `{ error: "consent must be true or false" }`.
- **Missing consent parameter**: Returns HTTP 422 with `{ error: "consent parameter is required" }`.
- **Save failure**: The Elm model transitions to `Failure` state, showing "Could not save preferences. Please try again."

### Elm State Machine
- **Page module**: `Page.Settings.Consent`
- **Model fields involved**: `analyticsConsent : Bool`, `writingAssistantConsent : Bool`, `saving : RemoteData Http.Error ()`
- **Msg flow**: `ToggleAnalytics -> SaveConsent -> SaveCompleted (Ok/Err)`, `ToggleWritingAssistant -> SaveConsent -> SaveCompleted (Ok/Err)`
- **RemoteData states**: NotAsked -> Loading -> Success / Failure

---

## 3. API Calls

### `POST /api/gdpr/consent`
- **Auth**: Required (JWT Bearer token)
- **Pipeline**: `:api`, `:authenticated`
- **Controller**: `StacksWeb.GDPRController.update_consent/2`
- **Request body**: `{ consent: boolean, type: "analytics" | "writing_assistant" }`
- **Response (success)**: `{ consent_analytics: boolean, consent_analytics_at: datetime, consent_writing_assistant: boolean, consent_writing_assistant_at: datetime }` -- HTTP 200
- **Response (error)**: `{ error: "consent must be true or false" }` -- HTTP 422, or `{ error: "consent parameter is required" }` -- HTTP 422
- **Side effect**: Revoking `writing_assistant` consent enqueues `WritingAssistantDataPurgeWorker` to delete the user's sessions, embeddings, and retrieval log.
- **FallbackController handling**: Changeset errors formatted via `format_errors/1`

---

## 4. Auth & Middleware Guards

- **Plugs fired** (in order): `SecurityHeaders` -> `AuthPipeline` (`:authenticated` scope) -> controller action
- **Visibility checks**: N/A
- **Age gate**: N/A
- **Ownership checks**: Implicit via `Guardian.Plug.current_resource(conn)`

---

## 5. Database Interactions

### Write: Grant consent
- **Table(s)**: `op.users`
- **Operation**: UPDATE
- **Fields**: `consent_analytics` / `consent_writing_assistant` set to `true`, corresponding `_at` timestamp set to `DateTime.utc_now()`
- **Changeset validations**: Via `User.consent_changeset/2`
- **Module**: `Stacks.GDPR.Consent.grant_consent/2`

### Write: Revoke consent
- **Table(s)**: `op.users`
- **Operation**: UPDATE
- **Fields**: `consent_analytics` / `consent_writing_assistant` set to `false`
- **Changeset validations**: Via `User.consent_changeset/2`
- **Module**: `Stacks.GDPR.Consent.revoke_consent/2`
- **Side effect (writing_assistant only)**: Enqueues `WritingAssistantDataPurgeWorker` to delete `op.blog_assistant_sessions`, `op.turn_feedback`, `op.retrieval_log`, and `op.embeddings` for this user

### Read: Check consent
- **Table(s)**: `op.users`
- **Query**: `Accounts.get_user(user_id)` then checks `user.consent_analytics == true` or `user.consent_writing_assistant == true`
- **Module**: `Stacks.GDPR.Consent.check_consent/2`
- **Gate**: Writing assistant endpoints must call `check_consent(user, :writing_assistant)` and return HTTP 403 with a clear message if consent has not been granted

---

## 6. Event Flow & Lifecycle

### Events Emitted
No events are explicitly emitted by the consent module. Consent changes are recorded via the timestamp on the user record (`consent_analytics_at`).

### Event Handlers Triggered
N/A

---

## 7. Background Jobs (Oban)

N/A -- Consent changes are synchronous.

---

## 8. External Service Calls

N/A

---

## 9. Storage (R2 / Local)

N/A

---

## 10. Cache Interactions

N/A

---

## 11. dbt Model Dependencies

N/A

---

## 12. Elm Frontend State Machine (Detail)

### Route
- **Route variant**: `Route.SettingsConsent`
- **URL**: `/settings/consent`
- **Public or authenticated**: Authenticated

### Init
- **`initPage` branch**: Initialises `Page.Settings.Consent.init` with `analyticsConsent = False`, `saving = NotAsked`.
- **API calls on init**: None (consent state is not yet loaded from the API on init -- future improvement).
- **Initial model state**: `{ analyticsConsent = False, saving = NotAsked }`

### Update cycle
- **Msg**: `ToggleAnalytics` -- flips `analyticsConsent` boolean.
- **Model change**: `analyticsConsent = not model.analyticsConsent`
- **Cmd**: None (toggle is local state only)

- **Msg**: `SaveConsent` -- triggers API call.
- **Model change**: `saving = Loading`
- **Cmd**: `Api.saveConsent model.analyticsConsent token SaveCompleted`

- **Msg**: `SaveCompleted (Ok _)` -- confirms save.
- **Model change**: `saving = Success ()`
- **Cmd**: None

- **Msg**: `SaveCompleted (Err err)` -- records failure.
- **Model change**: `saving = Failure err`
- **Cmd**: None

### View
- **Key elements**:
  - Title: "Privacy & Consent"
  - Section: "Analytics" with description text
  - Toggle button: `toggle--on` / `toggle--off` class based on `analyticsConsent`
  - Save button: "Save Preferences" (idle), "Saving..." (loading), "Saved!" (success)
  - Error text: "Could not save preferences. Please try again." (failure)
- **ARIA attributes**: N/A
- **CSS classes**: `page--settings`, `settings-section`, `toggle-row`, `toggle`, `btn--primary`

---

## 13. Operational Metrics

- **Consent grant/revoke count**: Total calls to `Stacks.GDPR.Consent.grant_consent/2` and `revoke_consent/2`, segmented by direction (grant vs. revoke). Tracks consent state change frequency.
- **Consent error rate**: HTTP 422 responses from the consent endpoint (invalid boolean, missing parameter). Indicates frontend validation gaps.
- **Current consent ratio**: Percentage of users with `consent_analytics == true` vs. `false` at any point in time. Useful for understanding analytics data coverage.

---

## 14. Performance & Usability Metrics

- **Consent save latency**: Round-trip time from `POST /api/gdpr/consent` to HTTP 200 response. This is a synchronous UPDATE on `op.users` -- expected to be sub-10ms at the database level.
- **Consent toggle-to-save time**: Client-side metric measuring time between toggle interaction and "Saved!" confirmation. Indicates perceived responsiveness.
- **Consent page load time**: Time to render the consent settings page. Currently no API call on init (consent state not loaded from API), so this is purely a static render.

---

## 15. Cost Tracking

- All consent operations are low-cost DB reads and writes only -- a single UPDATE on the `op.users` table per consent change.
- **Neon**: Minimal compute cost. Single-row UPDATE by primary key with no joins or cascades.
- No external service calls, no storage operations, no email notifications. This is one of the lowest-cost features in the platform.
