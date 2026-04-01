# US-4.2 — Age Verification for Gated Content

## 1. User Story

> **As a** user, **I want to** verify my age to access age-gated books **so that** I can view all content in my collection while the platform maintains responsible access controls.

**Single-user phase (self-hosted):** The user sets their age in preferences. The system trusts this self-declaration. **Multi-user phase:** Integration with a KYC provider for proper age verification. The process verifies the user is 18+ without storing identity documents -- only an `age_verified` boolean is retained.

On first access to age-gated content, a verification prompt appears. Single-user: a simple "I confirm I am 18+" checkbox in settings. After verification, age-gated books display normally -- the frosted overlay and lock icon are removed.

---

## 2. UI Interaction Flow

### Happy Path
1. User encounters an age-gated book (frosted overlay, lock icon on the spine).
2. User attempts to view the book detail -- receives a 403 with `"age_verification_required"`.
3. User navigates to Settings > Age Verification (`/settings/age-verification`).
4. User checks the "I confirm I am 18+" checkbox and submits.
5. `PUT /api/settings/age_verification` sets `age_verified: true` on the user record.
6. User returns to the book -- age-gated content now displays normally.

### Sad Paths
- **Not authenticated**: The `AgeGate` plug checks `Guardian.Plug.current_resource(conn)` -- returns `false` for nil user, resulting in a 403.
- **Not yet verified**: User has `age_verified: false` or nil -- 403 response.
- **Non-age-gated book**: `AgeGate.enforce/2` passes through unchanged for any `visibility_tier` other than `"age_gated"`.

### Elm State Machine
- **Page module**: `Page.Settings.AgeVerification`
- **Model fields involved**: Age verification checkbox state, submit status
- **Msg flow**: `ToggleAgeVerification` -> `SubmitAgeVerification` -> `PUT /api/settings/age_verification` -> `AgeVerificationUpdated`
- **RemoteData states**: NotAsked / Loading / Success / Failure

---

## 3. API Calls

### `PUT /api/settings/age_verification`
- **Auth**: Required
- **Pipeline**: `:api` -> `:authenticated`
- **Controller**: `StacksWeb.UserSettingsController.update_age_verification/2`
- **Request body**: `{ "age_verified": true }`
- **Response (success)**: Updated user settings — HTTP 200
- **Response (error)**: HTTP 422 on validation failure

### `GET /api/books/:id` (age gate enforcement)
- **Auth**: Optional
- **Pipeline**: `:api` -> `:optional_auth`
- **Controller**: `StacksWeb.BookController.show/2`
- **Age gate check**: After fetching the book, `AgeGate.enforce(conn, book)` is called inline
- **Response (blocked)**: `{ "error": "age_verification_required" }` — HTTP 403

---

## 4. Auth & Middleware Guards

- **Plugs fired (settings)**: `SecurityHeaders` -> `AuthPipeline`
- **Plugs fired (book detail)**: `SecurityHeaders` -> `OptionalAuthPipeline` -> inline `AgeGate.enforce/2`
- **AgeGate logic**:
  1. Checks if `book.visibility_tier == "age_gated"`
  2. If yes: gets current user via `Guardian.Plug.current_resource(conn)`
  3. Checks `user.age_verified == true`
  4. If not verified: halts conn with 403 + `{ error: "age_verification_required" }`
  5. If verified or book not age-gated: passes through
- **Ownership checks**: N/A for age gate; settings update requires authenticated user

---

## 5. Database Interactions

### Read: User record (age_verified check)
- **Table(s)**: `op.users`
- **Query**: Loaded via Guardian authentication — `user.age_verified`
- **Schema module**: `Stacks.Accounts.User`
- **Key field**: `age_verified` (boolean, default false)

### Write: Update age_verified
- **Table(s)**: `op.users`
- **Operation**: UPDATE
- **Changeset validations**: Standard user settings changeset; sets `age_verified: true`
- **Transaction**: No — single update
- **Denormalization**: None

### Read: Book visibility tier
- **Table(s)**: `op.books`
- **Query**: Book loaded in controller action; `visibility_tier` checked by `AgeGate`
- **Schema module**: `Stacks.Books.Book`
- **Key field**: `visibility_tier` (string: "public" or "age_gated")

---

## 6. Event Flow & Lifecycle

### Events Emitted
N/A — the current implementation does not emit a domain event for age verification updates. The settings update is a simple database write.

### Event Handlers Triggered
N/A

---

## 7. Background Jobs (Oban)

N/A — age verification is a synchronous settings update.

---

## 8. External Service Calls

N/A — in the single-user (self-hosted) phase, age verification is self-declaration only. Multi-user KYC integration (Smile Identity, Yoti, or Sumsub) is planned for a future phase.

---

## 9. Storage (R2 / Local)

N/A — only a boolean flag is stored on the user record. No identity documents are retained.

---

## 10. Cache Interactions

N/A

---

## 11. dbt Model Dependencies

N/A — age verification does not trigger dbt model refreshes.

---

## 12. Elm Frontend State Machine (Detail)

### Route
- **Route variant**: `Route.SettingsAgeVerification`
- **URL**: `/settings/age-verification`
- **Public or authenticated**: Authenticated

### Init
- **`initPage` branch**: Loads current user settings including `age_verified` status
- **API calls on init**: Likely fetches current user state via `GET /api/auth/me`
- **Initial model state**: Checkbox reflects current `age_verified` value

### Update cycle
- **Msg**: `ToggleAgeVerification` -> toggles checkbox state
- **Msg**: `SubmitAgeVerification` -> `PUT /api/settings/age_verification` with `{ age_verified: true }`
- **Msg**: `AgeVerificationUpdated (Result Http.Error ...)` -> Success or Failure
- **Cmd**: API call on submit
- **OutMsg**: N/A

### View
- **Key elements**:
  - Checkbox: "I confirm I am 18+"
  - Submit button: "Verify Age" (disabled if already verified)
  - Success state: "Age verified. You now have full access."
  - Already verified: Confirmation message, no form
  - Failure: Error message
- **ARIA attributes**: Standard form accessibility
- **CSS classes**: Settings page classes

---

## 13. Operational Metrics

- **Age verification request counts**: `PUT /api/settings/age_verification` calls — success (200) vs failure (422) breakdown
- **Age gate enforcement counts**: number of `AgeGate.enforce/2` invocations that result in 403 (blocked) vs pass-through — indicates how often users encounter age-gated content without verification
- **Age-gated book count**: total books with `visibility_tier: "age_gated"` in `op.books` — set by the moderation pipeline (US-4.1)
- **Verified user ratio**: percentage of users with `age_verified: true` — measures adoption of the age verification flow

---

## 14. Performance & Usability Metrics

- **Age verification completion rate**: percentage of users who navigate to `/settings/age-verification` and successfully submit vs abandon
- **Time to verify**: elapsed time from first 403 encounter to successful `PUT /api/settings/age_verification` — measures friction in the verification flow
- **Age gate response latency**: inline `AgeGate.enforce/2` adds negligible overhead to `GET /api/books/:id` — should be <1ms (boolean check on preloaded user)
- **Post-verification access pattern**: frequency of age-gated book views after verification — confirms the gate is not deterring legitimate access

---

## 15. Cost Tracking

- **Fly.io compute**: negligible — age verification is a synchronous settings update (single DB write). `AgeGate.enforce/2` is an in-memory boolean check, no additional queries.
- **Neon compute**: one UPDATE query per verification (`op.users` set `age_verified: true`). One READ of `user.age_verified` per age-gated book detail request (typically loaded via Guardian auth, not a separate query). Effectively zero marginal cost.
- **No external API costs**: single-user phase uses self-declaration only. No KYC provider integration yet.
- **Future KYC costs** (multi-user phase): Smile Identity (~$0.50/verification), Yoti (~$1.50/verification), or Sumsub (~$2.00/verification). One-time per user. Budget depends on user growth.
