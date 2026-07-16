# US-1.1.4 — Age-Gated Content Flagging

## 1. User Story

> **As** the person adding a book, **I want** to mark it "adults only" **so that** age-appropriate access controls are applied — and **as** the platform owner, **I want** to moderate any book's gate — because a human decision is more predictable and defensible than an automated guess.

**What the user wants to accomplish:** Explicitly flag a book they are adding as adults-only, and rely on the platform owner to moderate/override when needed. There is **no** automatic subject/BISAC classification — that oracle was removed because it was unreliable (it only ever gated romance titles and let genuinely sensitive content — anatomy, nudity, sex-ed — through as `public`).

> **Shipped-dark note (ADR-020 — `docs/decisions/020-age-gating-shipped-dark.md`):** the content **mark** described here stays, but its downstream **enforcement** is behind the runtime flag `age_gating_enabled` (**default OFF in production, ON in `:test`**, read via `Stacks.FeatureFlags.age_gating_enabled?/0`). With the flag off, an `age_gated` mark is inert (age-gated books behave exactly like public ones) and the "Adults only" UI is hidden. **Age-verification is provider-sourced** (future KYC — Smile ID / Yoti / Sumsub) and written only by `Stacks.AgeVerification.record_verification/3` — the self-declared toggle and `PUT /api/settings/age_verification` endpoint have been removed (see US-4.2).

**How they accomplish it:**
1. Every uploaded/added book is created `public`. The moderation pipeline never classifies content for age-gating.
2. At the verify step, the person adding the book can mark it **"adults only"**, calling `PUT /api/books/:id/age-gate` → `Books.set_visibility_tier/3`.
3. A normal user may only **raise** the gate (`public → age_gated`); an attempt to lower it (`age_gated → public`) returns 403 — only the platform owner may un-gate.
4. The platform owner can moderate and override any book's gate in either direction, and change it later (an owner-only admin surface, coming in a follow-up).
5. Once `age_gated`, the book is still added to the shelf but requires age verification to view — enforcement is unchanged.

**What they see on the page:**
- At the verify step, an **"Adults only"** checkbox lets the adder raise the gate.
- Age-gated books are hidden from listing surfaces (catalogue/search/shelf) for unverified and anonymous viewers and return 403 on a direct URL (#229); age verification unlocks them.
- A notice in the upload/verify success state reads: "You marked this book as adults-only. Age verification is required to view its details."

---

## 2. UI Interaction Flow

### Happy Path
1. User uploads a book image (same as US-1.1.1 steps 1-3).
2. Vision pipeline identifies the book and resolves ISBN.
3. The book is created `public` (the pipeline does not classify content).
4. At the verify step, the adder ticks **"Adults only"**, which calls `PUT /api/books/:id/age-gate` → `Books.set_visibility_tier(id, "age_gated", source: :user, raise_only: true)`, setting `visibility_tier: "age_gated"` in `op.books`.
5. The upload flow proceeds normally through shelf placement (US-1.1.1 steps 7-9).
6. When the user later views the book detail via `GET /api/books/:id`, `AgeGate.enforce/2` checks whether the user has completed age verification.

### Sad Paths
- **No age verification on file** (flag ON): User clicks an age-gated book -> `GET /api/books/:id` -> `AgeGate.enforce/2` halts the conn -> user sees the `.age-gate` block-and-explain UI. Verification is provider-sourced (future KYC), not a self-declared settings toggle. With the flag OFF, the gate is a no-op and the book detail renders normally.
- **Under 18**: Age verification denied -- book detail remains inaccessible.
- **User tries to un-gate**: A normal user calling `PUT /api/books/:id/age-gate` with `adults_only: false` on an already-gated book gets 403 — only the platform owner may lower the gate.

### Elm State Machine
- **Page module**: `Page.Upload` / verify step (adds an "Adults only" checkbox that drives the `PUT /api/books/:id/age-gate` call)
- **Model fields involved**: an `adults_only` flag captured at verify time; otherwise same as US-1.1.1
- **Note**: Age-gating is human-set, not inferred. The book detail page (`Page.BookDetail`) handles the age gate *enforcement* on the frontend (the `.age-gate` block), and only when `age_gating_enabled` is on — the SPA reads `GET /api/config → {ageGatingEnabled}` and hides all age UI when off. There is no `Page.Settings.AgeVerification` any more (removed with self-declaration, ADR-020); verification is provider-sourced. The owner override lives on an owner-only admin surface (follow-up).

---

## 3. API Calls

The upload flow API calls are identical to US-1.1.1. Age-gating is set by an explicit call, and affects downstream book detail retrieval:

### `PUT /api/books/:id/age-gate` (the adder marks a book adults-only)
- **Auth**: Required
- **Controller**: `StacksWeb.BookController.set_age_gate/2`
- **Request body**: `{ "adults_only": true }` (also accepts `{ "age_gated": true }`; a missing flag defaults to raising the gate)
- **Backend**: `Books.set_visibility_tier(id, tier, source: :user, raise_only: true)`
- **Response (success)**: HTTP 200 with the updated book JSON (`visibility_tier: "age_gated"`)
- **Response (raise-only violation)**: HTTP 403 `{"error": "forbidden"}` — a user attempted to lower an existing gate
- **Response (missing book)**: HTTP 404 `{"error": "not_found"}`

### `GET /api/books/:id` (downstream, when viewing the book later)
- **Auth**: Optional (Bearer token)
- **Pipeline**: `:api` -> `:optional_auth`
- **Controller**: `StacksWeb.BookController.show/2`
- **Age gate enforcement**: `AgeGate.enforce(conn, book)` is called. If `book.visibility_tier == "age_gated"` and the user has not verified their age, the conn is halted.
- **Response (age-gated, not verified)**: conn halted by `AgeGate.enforce/2`
- **Response (age-gated, verified)**: normal book detail response with `visibility_tier: "age_gated"` in the book object

---

## 4. Auth & Middleware Guards

- **Plugs fired** (upload): Same as US-1.1.1
- **Plugs fired** (book detail): `SecurityHeaders` -> `OptionalAuthPipeline` -> then inline `AgeGate.enforce/2`
- **Age gate (enforcement)**: `AgeGate.enforce/2` first consults `Stacks.FeatureFlags.age_gating_enabled?/0` (no-op when off); when on, it checks `book.visibility_tier == "age_gated"` and verifies `user.age_verified == true` (a provider-sourced flag, not a self-declared setting)
- **Age gate (setting)**: `PUT /api/books/:id/age-gate` is authenticated; the raise-only guard lives in `Books.set_visibility_tier/3` (user path may only raise; owner path passes `raise_only: false`)
- **Visibility checks**: `Visibility.resolve_visibility/2` also participates -- age-gated books are hidden from unverified/anonymous viewers via `maybe_exclude_age_gated/2` in `Books.list_catalogue/1`

---

## 5. Database Interactions

### Write: Create book with age_gated visibility_tier
- **Table(s)**: `op.books`
- **Operation**: INSERT (same as US-1.1.1, but with `visibility_tier: "age_gated"`)
- **Changeset validations**: `visibility_tier` validated via `validate_inclusion(:visibility_tier, ["public", "age_gated"])`
- **Schema module**: `Stacks.Books.Book`
- **Column**: `visibility_tier` (string, default `"public"`)

### Read: Catalogue filtering
- **Table(s)**: `op.books`
- **Query**: `Books.list_catalogue/1` with `maybe_exclude_age_gated/2` -- `WHERE visibility_tier != 'age_gated'` for unauthenticated viewers
- **Impact**: Age-gated books are excluded from public catalogue listings

---

## 6. Event Flow & Lifecycle

### Events Emitted
Same as US-1.1.1 (`image.submitted`, `image.resolved`, `book.created`, `placement.created`). No special event is emitted for age-gating; the `book.created` payload includes the book data, and the `visibility_tier` is a column on the book record.

### Event Handlers Triggered
Same as US-1.1.1 -- `BookCreatedHandler`, `AuthorDiscoveryHandler`, `CacheInvalidationHandler` for `book.created`.

---

## 7. Background Jobs (Oban)

### `Stacks.Workers.IdentifyBookJob`
Same as US-1.1.1. The job does **not** decide age-gating — it stores work metadata (subjects, BISAC codes) and creates the book with `visibility_tier: "public"`. There is no `subjects_to_bisac/1` or `determine_visibility_tier/1` step; that automatic classifier was removed.

Age-gating happens **after** the job, as a separate human action: the adder's "Adults only" tick calls `PUT /api/books/:id/age-gate` → `Books.set_visibility_tier/3`, which emits the `[:stacks, :moderation, :tiering]` counter (`tier`, `source`) on a successful change and enforces the raise-only rule for the user path.

---

## 8. External Service Calls

Same as US-1.1.1. The age-gating decision is made locally based on subjects returned by Open Library / Google Books metadata -- no additional external calls are needed.

---

## 9. Storage (R2 / Local)

Same as US-1.1.1.

---

## 10. Cache Interactions

- **Cache**: `BookDetailCache`
- **Operation**: Same as US-1.1.1
- **Note**: Cached book detail includes `visibility_tier`, so cache invalidation on `book.created` ensures stale entries don't bypass the age gate

---

## 11. dbt Model Dependencies

- **Model**: `stg_books`
- **Column**: `visibility_tier` -- available for analytics on age-gated content proportion
- **Model**: `int_visibility_resolution` -- intermediate model that resolves visibility rules
- **Consumer**: Metrics dashboard, catalogue API filtering

---

## 12. Elm Frontend State Machine (Detail)

### Route
Same as US-1.1.1 for the upload flow.

### Init
Same as US-1.1.1.

### Update cycle
At the verify step, the adder can tick **"Adults only"**, which drives a `PUT /api/books/:id/age-gate` call. Otherwise the book stays `public`.

The age gate enforcement is handled by:
- `Page.BookDetail` -- which receives the `visibility_tier` field in the book API response and shows the `.age-gate` block-and-explain view when a direct-URL fetch 403s (only when `age_gating_enabled` is on; the SPA hides all age UI when `GET /api/config` reports it off).
- There is **no** `Page.Settings.AgeVerification` — self-declaration was removed (ADR-020). Verification is provider-sourced (future KYC) and written server-side by `Stacks.AgeVerification.record_verification/3`.

### View
- At the verify step: an "Adults only" checkbox lets the adder raise the gate.
- Age-gating manifests later as **hidden-from-listings** for unverified/anonymous viewers (the spine simply does not appear in catalogue/search/shelf results — #229), not as a spine overlay.
- On the book detail page: age verification gate appears before content is shown; a direct URL returns 403 for unverified viewers.

---

## 13. Operational Metrics

### HTTP Request Metrics

All upload-flow HTTP metrics are identical to US-1.1.1. The age-gating adds metrics for downstream book detail access:

- **Metric name**: `age_gate_enforcement_count`
- **Source**: Not yet instrumented. `AgeGate.enforce/2` in `BookController.show/2` — would need a Telemetry event for gate checks.
- **Type**: counter
- **Labels/dimensions**: result (passed, halted), book_id, visibility_tier (`age_gated`)

- **Metric name**: `age_gate_halted_count`
- **Source**: Not yet instrumented. Count of conns halted by `AgeGate.enforce/2`.
- **Type**: counter
- **Labels/dimensions**: none

- **Metric name**: `[:stacks, :age_verification]` (verification write outcome)
- **Source**: `Stacks.AgeVerification.record_verification/3` / `revoke/1` — repointed here from the deleted self-declared endpoint (ADR-020).
- **Type**: counter
- **Labels/dimensions**: `outcome` (`:success` / `:error`) — no PII. Expected 0 writes in production (no provider).

### Oban Job Metrics

Same as US-1.1.1. The age-gating decision is made inline within `IdentifyBookJob` during `Moderation.store_book/3` — no additional Oban job is enqueued.

### Event Emission Metrics

- **Metric name**: `event_emitted_count`
- **Source**: `Stacks.Events.emit_safe/1` — not yet instrumented with Telemetry.
- **Type**: counter
- **Labels/dimensions**: event_type (`book.created` — the payload includes `visibility_tier: "public"`, the default at creation)

- **Metric name**: `[:stacks, :moderation, :tiering]` (age-gate set counter)
- **Source**: `Books.set_visibility_tier/3` — emitted on a successful gate CHANGE (a no-op is silent). Wired into PromEx (`Core.PromEx.Plugins.Stacks`).
- **Type**: counter (`%{count: 1}`)
- **Labels/dimensions**: `tier` (`:public` / `:age_gated`), `source` (`:user` / `:owner`) — low-cardinality atoms only, no ids/PII. This is the signal for how many books were marked adults-only, and by whom.

### Database Metrics

Same as US-1.1.1 plus:

- **Metric name**: `catalogue_age_gate_filter_count`
- **Source**: Not yet instrumented. `Books.list_catalogue/1` with `maybe_exclude_age_gated/2` — count of queries that filter out age-gated content.
- **Type**: counter
- **Labels/dimensions**: filter_applied (true/false)

---

## 14. Performance & Usability Metrics

### Pipeline Timing

Same as US-1.1.1. Age-gating is no longer a pipeline step — it is a separate, human-triggered `PUT /api/books/:id/age-gate` request, so it adds zero time to the upload pipeline.

- **Metric name**: Age-gate set latency
- **How measured**: Phoenix Telemetry `[:phoenix, :endpoint, :stop]` for `PUT /api/books/:id/age-gate` (a single-row update via `Books.set_visibility_tier/3`).
- **Target/SLA**: p95 < 100ms (simple DB update)
- **Dashboard**: API latency section

### Downstream Access Metrics

- **Metric name**: Age verification completion rate
- **How measured**: `count(successful age verifications) / count(age gate halts)`. Not yet instrumented — would require correlating `AgeGate.enforce/2` halts with subsequent `record_verification/3` writes (provider-sourced; expected 0 in production until a provider lands).
- **Target/SLA**: Informational — no target set
- **Dashboard**: User settings section

- **Metric name**: Age verification latency
- **How measured**: `[:stacks, :age_verification]` telemetry from `record_verification/3` (single-row UPDATE)
- **Target/SLA**: p95 < 100ms (simple DB update)
- **Dashboard**: API latency section

- **Metric name**: Age-gated content proportion
- **How measured**: `count(books where visibility_tier = 'age_gated') / count(books)` from `stg_books` dbt model
- **Target/SLA**: Informational — expected < 5% of catalogue
- **Dashboard**: Content moderation section

### User Experience Metrics

- **Metric name**: Upload-to-shelf time for age-gated books
- **How measured**: Same as US-1.1.1 — the upload flow is identical. Age-gating is transparent to the upload UI.
- **Target/SLA**: Same as US-1.1.1 (p50 < 30s, p95 < 60s)
- **Dashboard**: Upload pipeline section

---

## 15. Cost Tracking

### Upload Flow Costs
Identical to US-1.1.1. The age-gating decision adds no external API calls or compute costs.

### Vision Classification + Extraction (Modal GPU)
- **Service**: Modal (A10G GPU)
- **Trigger**: Same as US-1.1.1 — `IdentifyBookJob` runs the full vision pipeline
- **Unit cost**: ~R0.50-R2.50 per identification
- **Volume estimate**: Same as US-1.1.1
- **Tracked by**: `Stacks.AI.BudgetTracker`, `op.platform_costs`, `mart_cost_tracking`

### Open Library / Google Books API
- **Service**: Open Library, Google Books
- **Trigger**: ISBN resolution — same as US-1.1.1. The subjects/BISAC codes used for age-gating are returned as part of the ISBN metadata response (no additional API call).
- **Unit cost**: Free
- **Volume estimate**: Same as US-1.1.1
- **Tracked by**: No cost tracking needed

### Age Verification (Downstream)
- **Service**: None today — age verification is a local database write via `Stacks.AgeVerification.record_verification/3` (provider-sourced; a future KYC provider callback is the caller)
- **Trigger**: User attempts to view an age-gated book detail
- **Unit cost**: Negligible (single DB update)
- **Volume estimate**: Once per user who encounters an age-gated book (not per-book)
- **Tracked by**: Not tracked as a cost item

### Per-Upload Cost Estimate (Age-Gated Books)
- Same as US-1.1.1: **~R0.50-R2.50 (~$0.03-$0.14 USD) per upload**
- No additional cost for the age-gating decision itself

---

## 16. Cross-References

- **US-4.2 — Age Verification** (`docs/user_stories/US-4.2-age-verification.md`): the provider-sourced verification model that lets a verified user pass `AgeGate.enforce/2`. `Stacks.AgeVerification.record_verification/3` sets `users.age_verified = true`, which this story's (flag-gated) age gate consults.
- **ADR 020 — Age-Gating Shipped Dark** (`docs/decisions/020-age-gating-shipped-dark.md`): flag-gated enforcement + provider-sourced verification; the authoritative decision behind the shipped-dark note above.
- **US-1.1.1 — Book Upload** (`docs/user_stories/`): parent flow whose `IdentifyBookJob` creates the book `public`. Age-gating is a separate human action after creation, not decided in the pipeline.
- **US-4.1 — Content Moderation Pipeline** (`docs/user_stories/US-4.1-moderation-pipeline.md`): the pipeline that now stops at metadata lookup and creates `public` books.
- **ADR 006 — Row-Level Security Plus Application-Layer Visibility** (`docs/decisions/006-rls-plus-application-visibility.md`): the defence-in-depth visibility model that `Stacks.Visibility` and `AgeGate` together implement. Book-level `visibility_tier` sits alongside the bookshelf/placement visibility ceilings described there.
- **Implementation modules**:
  - `apps/core/lib/stacks/books.ex` — `set_visibility_tier/3` (human-set gate; raise-only guard; `[:stacks, :moderation, :tiering]` telemetry)
  - `apps/core/lib/stacks_web/controllers/book_controller.ex` — `set_age_gate/2` (`PUT /api/books/:id/age-gate`)
  - `apps/core/lib/stacks_web/plugs/age_gate.ex` — `AgeGate.enforce/2`
  - `apps/core/lib/stacks/books.ex` — `list_catalogue/1`, `maybe_exclude_age_gated/2`, `book_changeset` (validates `visibility_tier` ∈ `["public", "age_gated"]`)
  - `apps/core/lib/stacks/visibility.ex` — `check_age_gate/2` (per-resource visibility resolver)
