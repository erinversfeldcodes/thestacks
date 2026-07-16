# US-4.2 — Age Verification for Gated Content

> **Model change (ADR-020 — Age-Gating Shipped Dark):** age-gating enforcement + all
> age UI are behind a runtime flag `age_gating_enabled` (**default OFF in production,
> ON in `:test`**). Age-verification is **provider-sourced** (future KYC — Smile ID /
> Yoti / Sumsub), **never self-declared** — the self-declared toggle, its
> `/settings/age-verification` page, and the `PUT /api/settings/age_verification`
> endpoint have all been **removed**. See `docs/decisions/020-age-gating-shipped-dark.md`.

## 1. User Story

> **As a** user, **I want** the platform to know I am 18+ (through a trusted verification provider) **so that** I can view age-gated books in my collection while the platform maintains responsible, legally-defensible access controls.

**Assurance model.** A viewer becomes age-verified **only** when a real identity/KYC
provider says so — the interim self-declaration toggle ("I confirm I am 18+") was
removed as an unacceptable assurance mechanism (trivially bypassed, legally weak).
Production ships with **no provider and no verified users**; the whole feature is
shipped **dark** behind `age_gating_enabled` (default `false`) until a provider is
integrated. The schema (`users.age_verified`, `age_verified_at`,
`age_verification_provider`) is retained, written **only** by
`Stacks.AgeVerification.record_verification/3` — a stub today, wired to a provider
callback in a future issue.

**Display model (owner decision, supersedes the original frosted-overlay spec — #229, gated by the flag):** when `age_gating_enabled` is **on**, age-gated books are **hidden from all listing surfaces** (catalogue, search, bookshelf/profile shelf) for any viewer who is not age-verified — anonymous **or** authenticated-but-unverified — and a **direct URL** to an age-gated book's detail returns a 403 (`age_verification_required`) rendered as a **block-and-explain** UI (the `.age-gate` block). After verification, age-gated books appear in listings again and their detail pages render normally. When the flag is **off** (production default), all three enforcement points are no-ops: age-gated books behave exactly like public ones and all age UI is hidden.

---

## 2. UI Interaction Flow

### Happy Path (flag ON; future provider integrated)
1. An unverified user browses listings — age-gated books are **absent** from the catalogue, search results, and bookshelf/profile shelves (they are never rendered, so there is no visible gap to "unlock").
2. The user reaches an age-gated book via a **direct URL** (e.g. a shared link) — the book detail returns a 403 with `"age_verification_required"`, shown as the `.age-gate` block-and-explain UI.
3. The user completes a **verification-provider** flow (future KYC — Smile ID / Yoti / Sumsub). There is **no** self-declared toggle in Settings.
4. The provider's callback resolves the local user and calls `Stacks.AgeVerification.record_verification(user, provider, verified_at)`, setting `age_verified: true`.
5. Age-gated books now **appear** in the catalogue/search/shelf listings, and the direct-URL detail renders its content normally.

### Flag OFF (production default, today)
- `age_gating_enabled?/0` is `false`: enforcement is a no-op and every age-related UI element is hidden. Age-gated books behave like public ones. `record_verification/3` is never invoked (no provider, no verified users).

### Sad Paths (flag ON)
- **Not authenticated**: the `AgeGate` plug checks `Guardian.Plug.current_resource(conn)` — `nil` user → 403.
- **Not yet verified**: user has `age_verified: false` or `nil` → 403.
- **Non-age-gated book**: `AgeGate.enforce/2` passes through unchanged for any `visibility_tier` other than `"age_gated"`.

### Acceptance Criteria — enforcement (flag ON, #229)
The hide-from-listings + block-on-detail model must hold on **all four surfaces** whenever `age_gating_enabled` is on:
- **Catalogue** (`GET /api/catalogue`): omits age-gated books for an unverified viewer (anonymous or authenticated-but-unverified), with `total`/pagination counted off the filtered set at the SQL layer; shows them to a verified viewer. (`Books.list_catalogue/1` → `maybe_exclude_age_gated/2`.)
- **Search** (`GET /api/search`): age-gated books absent from results for an unverified viewer, present for a verified one (via `Stacks.Visibility`).
- **Bookshelf / profile shelf** (`GET /api/u/:handle/bookshelves/:name`): age-gated placements never reach the payload for an unverified viewer (no gap), present for a verified one (via `Stacks.Visibility`).
- **Direct detail URL** (`GET /api/books/:id`): still 403s (`age_verification_required`) with the `.age-gate` block-and-explain UI for an unverified viewer; renders content for a verified one.
- **Verified reveal**: after `record_verification/3` flips `age_verified: true`, the same books appear across all three listing surfaces and the detail renders normally.
- **Flag OFF invariant**: with `age_gating_enabled` off, ALL of the above are no-ops — age-gated books show everywhere and the detail never 403s.

### Test / E2E path (no provider needed)
Tests and E2E set the flag on (`AGE_GATING_ENABLED=true`; `:test` env sets it by default) and create a verified user via the `STACKS_E2E_TEST_HELPERS`-gated helper `PUT /api/test/age-verification {email, verified}` → `record_verification/3` (provider `"e2e_test_helper"`). This keeps the full gate behaviour covered even though production has no provider.

### Elm State Machine
- **No dedicated age-verification page.** `Page.Settings.AgeVerification` and the `Route.SettingsAgeVerification` route were removed with the self-declared toggle.
- The frontend reads `GET /api/config → {ageGatingEnabled: bool}` and **hides all age UI** when it is `false`.
- Enforcement still surfaces in `Page.BookDetail`: a 403 (`age_verification_required`) drives the `.age-gate` block-and-explain view (only reachable when the flag is on).

---

## 3. API Calls

> The self-declared `PUT /api/settings/age_verification` endpoint has been **removed**.

### `GET /api/config` (feature-flag channel)
- **Auth**: Optional
- **Controller**: `StacksWeb.ConfigController.show/2`
- **Response**: `{ "ageGatingEnabled": <bool> }` — the frontend hides all age UI when `false`.

### `PUT /api/test/age-verification` (E2E test helper — gated)
- **Auth**: None (gated by `StacksWeb.Plugs.E2ETestHelper`; 404 unless `STACKS_E2E_TEST_HELPERS=1`)
- **Controller**: `StacksWeb.TestHelperController.set_age_verification/2`
- **Scope**: `@thestacks.test` emails ONLY — can never flip a real account.
- **Request body**: `{ "email": "<...@thestacks.test>", "verified": true | false }`
- **Backend**: `verified: true` → `Stacks.AgeVerification.record_verification(user, "e2e_test_helper", nil)`; `verified: false` → `Stacks.AgeVerification.revoke(user)`
- **Response (success)**: HTTP 200 `{ "ok": true }`
- **Response (out-of-scope email / unknown user)**: HTTP 404 (deliberately indistinguishable — not an enumeration oracle)

### Future: provider callback (not yet built)
- A KYC provider (Smile ID / Yoti / Sumsub) webhook resolves the local user and calls `Stacks.AgeVerification.record_verification/3`. This is the **sole writer** of the age-verification columns once a provider lands.

### `GET /api/books/:id` (age gate enforcement — flag-gated)
- **Auth**: Optional
- **Pipeline**: `:api` → `:optional_auth`
- **Controller**: `StacksWeb.BookController.show/2`
- **Age gate check**: after fetching the book, `AgeGate.enforce(conn, book)` is called inline. It is a **no-op when `age_gating_enabled?/0` is false**.
- **Response (blocked, flag ON, unverified)**: `{ "error": "age_verification_required" }` — HTTP 403

---

## 4. Auth & Middleware Guards

- **Plugs fired (book detail)**: `SecurityHeaders` → `OptionalAuthPipeline` → inline `AgeGate.enforce/2`
- **Plugs fired (test helper)**: `StacksWeb.Plugs.E2ETestHelper` (404 unless the server flag is on) → `TestHelperController`
- **Flag gate**: every enforcement point first consults `Stacks.FeatureFlags.age_gating_enabled?/0`; when `false` it passes through unconditionally.
- **AgeGate logic (flag ON)**:
  1. Checks if `book.visibility_tier == "age_gated"`
  2. If yes: gets current user via `Guardian.Plug.current_resource(conn)`
  3. Checks `user.age_verified == true`
  4. If not verified: halts conn with 403 + `{ error: "age_verification_required" }`
  5. If verified, book not age-gated, or the flag is off: passes through
- **Ownership checks**: N/A for the age gate. There is no user-facing verification write to guard — verification is provider-sourced (or the gated test helper).

---

## 5. Database Interactions

### Read: User record (age_verified check)
- **Table(s)**: `op.users`
- **Query**: loaded via Guardian authentication — `user.age_verified`
- **Schema module**: `Stacks.Accounts.User`
- **Key fields**: `age_verified` (boolean, default false), `age_verified_at`, `age_verification_provider`

### Write: Record verification (provider-sourced)
- **Table(s)**: `op.users`
- **Operation**: UPDATE via `Stacks.AgeVerification.record_verification/3` (sole writer)
- **Changeset**: `Accounts.verification_changeset/2` sets `age_verified: true`, `age_verified_at`, `age_verification_provider`
- **Callers today**: tests + the `STACKS_E2E_TEST_HELPERS` helper. Future: a KYC-provider callback.
- **Transaction**: No — single update

### Read: Book visibility tier
- **Table(s)**: `op.books`
- **Query**: book loaded in controller action; `visibility_tier` checked by `AgeGate` (only when the flag is on)
- **Schema module**: `Stacks.Books.Book`
- **Key field**: `visibility_tier` (string: "public" or "age_gated")

---

## 6. Event Flow & Lifecycle

### Events Emitted
N/A — no domain event is emitted to `event_log`. Verification is a single database write via `record_verification/3`, which emits **telemetry only** (see §13).

### Event Handlers Triggered
N/A

---

## 7. Background Jobs (Oban)

N/A — age verification is a synchronous write (provider callback / test helper).

---

## 8. External Service Calls

N/A today — production has **no provider**. Verification is written only by the gated E2E test helper. A future issue integrates a real KYC provider (Smile Identity, Yoti, or Sumsub) whose callback calls `record_verification/3`.

---

## 9. Storage (R2 / Local)

N/A — only the boolean flag + timestamp + provider name are stored on the user record. No identity documents are retained (a design constraint carried into any future provider integration).

---

## 10. Cache Interactions

N/A

---

## 11. dbt Model Dependencies

N/A — age verification does not trigger dbt model refreshes. `age_verified` is not warehoused (it is treated as sensitive user state).

---

## 12. Elm Frontend State Machine (Detail)

### Route
- **No age-verification route.** `Route.SettingsAgeVerification` (`/settings/age-verification`) was removed with the self-declared toggle.

### Feature-flag channel
- On boot the SPA reads `GET /api/config → {ageGatingEnabled: bool}` and **hides all age UI** (the "adults only" upload checkbox, the upload age-gate notice, the book-detail age-gate block, the owner Book-Moderation route, the onboarding age step) when it is `false`.

### Enforcement surface (`Page.BookDetail`)
- Receives the `visibility_tier` field in the book API response; when the flag is on and the book detail 403s with `age_verification_required`, it renders the `.age-gate` block-and-explain view. There is no self-declared "verify" form to submit — verification is provider-sourced.

### View
- **Flag ON, unverified viewer on a direct URL**: the `.age-gate` block explains the book is adults-only and requires verification.
- **Flag OFF (production)**: no age UI is rendered anywhere.

---

## 13. Operational Metrics

- **Age verification writes**: `[:stacks, :age_verification]` telemetry family — emitted by `record_verification/3` / `revoke/1` with a whitelisted `:outcome` atom (`:success` / `:error`) and no PII. Repointed here from the deleted self-declared endpoint so the #230 Grafana panel + the 6-family `dashboard_drift_test` stay green.
- **Age gate enforcement counts**: `[:stacks, :age_gate, :enforce]` counter — fires **only when the flag is on** (enforcement runs); measures how often viewers hit age-gated content unverified.
- **Age-gated book count**: total books with `visibility_tier: "age_gated"` in `op.books` — set by the human moderation flow (US-1.1.4 / US-4.1).
- **Verified user ratio**: percentage of users with `age_verified: true` — expected **0 in production** until a provider is integrated.

---

## 14. Performance & Usability Metrics

- **Verification write latency**: `record_verification/3` is a single-row UPDATE — negligible (<1ms DB write); telemetry via `[:stacks, :age_verification]`.
- **Age gate response latency**: inline `AgeGate.enforce/2` adds negligible overhead to `GET /api/books/:id` — a flag check plus (when on) a boolean read on the preloaded user; <1ms.
- **Flag-off overhead**: with `age_gating_enabled` off, enforcement short-circuits on the flag read — effectively zero cost, and zero verified users to track.
- **Post-verification access pattern** (future, provider integrated): frequency of age-gated book views after verification — confirms the gate is not deterring legitimate access.

---

## 15. Cost Tracking

- **Fly.io compute**: negligible — verification is a single DB write; `AgeGate.enforce/2` is an in-memory flag + boolean check.
- **Neon compute**: one UPDATE per verification write; one READ of `user.age_verified` per age-gated book detail request (loaded via Guardian auth, not a separate query). Effectively zero marginal cost — and **zero writes in production today** (no provider).
- **No external API costs today**: production has no provider integration.
- **Future KYC costs** (when a provider is integrated): Smile Identity (~$0.50/verification), Yoti (~$1.50/verification), or Sumsub (~$2.00/verification). One-time per user. Budget depends on user growth.

---

## 16. Cross-References

- **ADR 020 — Age-Gating Shipped Dark** (`docs/decisions/020-age-gating-shipped-dark.md`): the authoritative decision — flag-gated enforcement, provider-sourced verification, no self-declaration, telemetry repointed to `record_verification/3`.
- **US-1.1.4 — Age-Gated Content Flagging** (`docs/user_stories/US-1.1.4-age-gated-flagging.md`): the human "adults only" content mark that produces `visibility_tier: "age_gated"`, which this story's gate consults (also flag-gated).
- **Implementation modules**:
  - `apps/core/lib/stacks/feature_flags.ex` — `age_gating_enabled?/0` (single read-side for the flag)
  - `apps/core/lib/stacks/age_verification.ex` — `record_verification/3` (sole writer) + `revoke/1` + `[:stacks, :age_verification]` telemetry
  - `apps/core/lib/stacks_web/controllers/test_helper_controller.ex` — `set_age_verification/2` (`PUT /api/test/age-verification`, `STACKS_E2E_TEST_HELPERS`-gated)
  - `apps/core/lib/stacks_web/plugs/age_gate.ex` — `AgeGate.enforce/2` (no-op when the flag is off)
  - `config/runtime.exs` / `apps/core/config/test.exs` — `config :core, :age_gating_enabled` (env `AGE_GATING_ENABLED`; default off in prod, on in `:test`)
</content>
</invoke>
