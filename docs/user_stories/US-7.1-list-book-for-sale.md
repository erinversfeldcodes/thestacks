# US-7.1 — List a Book for Sale

## 1. User Story

> **As a** user, **I want to** list a book I no longer want for second-hand sale **so that** it can find a new home with another reader.

From any shelf, the user moves a book to the "Looking for a Home" shelf via the Move to Shelf dropdown. A listing flow begins: the user uploads 1-3 photos, selects a condition grade (New, Good, Fair, Poor), and chooses a pricing model (fixed price in ZAR or open to offers). The listing is published. Open and fixed-price listings are visible to all platform users by default.

**Listing state machine:**
```
draft --> active --> removed
            |
            +---> expired
            |
            +---> sold
```
Valid transitions: `draft -> active`, `active -> removed`, `active -> expired`, `active -> sold`.

---

## 2. UI Interaction Flow

### Happy Path
1. User navigates to `/marketplace/create`.
2. Page loads user's placements via `GET /api/placements/mine`.
3. User selects a book from the dropdown.
4. User selects condition: New, Like New, Good, Fair, or Poor (radio buttons).
5. User selects pricing mode: Fixed (enters ZAR price) or Open to Offers.
6. User enters contact info (email, phone, or WhatsApp).
7. User optionally enters a description.
8. User clicks "Create Listing" -> `POST /api/listings`.
9. Listing created in `draft` status. Success view shows listing details.
10. User clicks "Activate" -> `PUT /api/listings/:id/activate`.
11. Listing transitions to `active` with `listed_at` and `expires_at` (30 days) set.
12. User is navigated to `/marketplace/mine`.

### Sad Paths
- **No placements**: "You have no books to list. Add books to your collection first."
- **No book selected / no contact info**: Submit button disabled.
- **No placement for book**: `create_listing` returns `{:error, :no_placement}`.
- **Create failure**: "Failed to create listing. Please try again."
- **Activate failure**: Error displayed; listing remains in draft.
- **Invalid transition**: `{:error, :invalid_transition}` if listing is not in the expected state.
- **Unauthorized**: `{:error, :unauthorized}` if user is not the seller.

### Elm State Machine
- **Page module**: `Page.Marketplace.CreateListing`
- **Model fields involved**: `placements`, `selectedPlacementId`, `condition`, `pricingMode`, `priceInput`, `contactInfo`, `description`, `submitState`, `createdListing`
- **Msg flow**: Form inputs -> `SubmitListing` -> `ListingCreated` -> show success -> `ActivateListing` -> `ListingActivated` -> `NavigateTo MarketplaceMyListings`
- **RemoteData states**: `placements` (Loading/Success/Failure), `submitState` (NotAsked/Loading/Success/Failure)
- **OutMsg pattern**: `NoOut` | `NavigateTo Route.Route` — on successful activation, navigates to My Listings

---

## 3. API Calls

### `GET /api/placements/mine`
- **Auth**: Required
- **Pipeline**: `:api` -> `:authenticated`
- **Controller**: `StacksWeb.BookshelfPlacementController.mine/2`
- **Response (success)**: `{ placements: [Placement] }` — HTTP 200

### `POST /api/listings`
- **Auth**: Required
- **Pipeline**: `:api` -> `:authenticated`
- **Controller**: `StacksWeb.ListingController.create/2`
- **Request body**: `{ book_id, pricing_mode: "fixed"|"offer", price_cents: int, condition: "new"|"like_new"|"good"|"fair"|"poor", contact_info: string, description: string }`
- **Response (success)**: `{ listing: Listing }` — HTTP 201
- **Response (error)**: `{ error: "no_placement" }` or changeset errors — HTTP 422

### `PUT /api/listings/:id/activate`
- **Auth**: Required
- **Pipeline**: `:api` -> `:authenticated`
- **Controller**: `StacksWeb.ListingController.activate/2`
- **Response (success)**: `{ listing: Listing }` — HTTP 200
- **Response (error)**: `{ error: "not_found" }` — 404; `{ error: "unauthorized" }` — 403; `{ error: "invalid_transition" }` — 422

### `PUT /api/listings/:id/deactivate`
- **Auth**: Required
- **Pipeline**: `:api` -> `:authenticated`
- **Controller**: `StacksWeb.ListingController.deactivate/2`
- **Response (success)**: `{ listing: Listing }` — HTTP 200

### `PUT /api/listings/:id/sold`
- **Auth**: Required
- **Pipeline**: `:api` -> `:authenticated`
- **Controller**: `StacksWeb.ListingController.sold/2`
- **Response (success)**: `{ listing: Listing }` — HTTP 200

### `GET /api/listings`
- **Auth**: Optional
- **Pipeline**: `:api` -> `:optional_auth`
- **Controller**: `StacksWeb.ListingController.index/2`
- **Response (success)**: `{ listings: [Listing] }` — active listings, newest first, limit 50

### `GET /api/listings/:id`
- **Auth**: Optional
- **Pipeline**: `:api` -> `:optional_auth`
- **Controller**: `StacksWeb.ListingController.show/2`
- **Response (success)**: `{ listing: Listing }` — HTTP 200

### `GET /api/listings/mine`
- **Auth**: Required
- **Pipeline**: `:api` -> `:authenticated`
- **Controller**: `StacksWeb.ListingController.mine/2`
- **Response (success)**: `{ listings: [Listing] }` — user's listings, newest first

---

## 4. Auth & Middleware Guards

- **Plugs fired (create/activate/deactivate/sold)**: `SecurityHeaders` -> `AuthPipeline`
- **Plugs fired (index/show)**: `SecurityHeaders` -> `OptionalAuthPipeline`
- **Plugs fired (mine)**: `SecurityHeaders` -> `AuthPipeline` (separate scope before optional_auth to avoid `:id` catch-all)
- **Visibility checks**: N/A — listings are visible to all users
- **Age gate**: N/A
- **Ownership checks**: `Marketplace.verify_ownership/2` — compares `listing.seller_id` to `user_id`; returns `{:error, :unauthorized}` on mismatch

---

## 5. Database Interactions

### Write: Create listing (draft)
- **Table(s)**: `op.listings`
- **Operation**: INSERT via `Ecto.Multi`
- **Multi steps**:
  1. `:placement` — Verifies seller has an active (non-removed) placement for the book. Joins `op.bookshelf_placements` with `op.bookshelves` on `user_id`. Returns `{:error, :no_placement}` if none found.
  2. `:listing` — Inserts listing with `status: "draft"`
  3. `:emit_event` — Emits `listing.created` event
- **Changeset validations**: Required: `book_id`, `seller_id`, `pricing_mode` ("fixed"/"offer"), `price_cents` (> 0), `condition` ("new"/"like_new"/"good"/"fair"/"poor"). Optional: `status`, `currency` (default "ZAR"), `description`, `contact_info` (max 500), `photo_urls`, `listed_at`, `expires_at`, `sold_at`.
- **Unique constraint**: `listings_active_book_seller_idx` — one active/draft listing per book per seller
- **Preloads**: `[:book, :seller]`

### Write: Activate listing (draft -> active)
- **Table(s)**: `op.listings`, `op.bookshelf_placements`
- **Operation**: UPDATE via `Ecto.Multi`
- **Multi steps**:
  1. `:locked_listing` — `SELECT FOR UPDATE` on the listing; validates `draft -> active` transition
  2. `:listing` — Updates to `status: "active"`, sets `listed_at` and `expires_at` (30 days)
  3. `:denormalize` — Sets `listing_status = "active"` on the seller's placement
  4. `:emit_event` — Emits `listing.activated` event

### Write: Deactivate listing (active -> removed)
- **Table(s)**: `op.listings`, `op.bookshelf_placements`
- **Operation**: UPDATE via `Ecto.Multi`
- **Multi steps**: Lock -> update status to "removed" -> clear `listing_status` on placement -> emit `listing.removed`

### Write: Mark sold (active -> sold)
- **Table(s)**: `op.listings`, `op.bookshelf_placements`
- **Operation**: UPDATE via `Ecto.Multi`
- **Multi steps**: Lock -> update status to "sold", set `sold_at` -> clear `listing_status` on placement -> emit `listing.sold`

### Write: Expire listing (active -> expired)
- **Table(s)**: `op.listings`, `op.bookshelf_placements`
- **Operation**: UPDATE via `Ecto.Multi` (called by `ListingExpiryJob`)
- **Multi steps**: Lock -> update status to "expired" -> clear `listing_status` on placement -> emit `listing.expired`

### Read: Active listings
- **Table(s)**: `op.listings`
- **Query**: `Marketplace.list_active_listings()` — `WHERE status = "active" ORDER BY listed_at DESC LIMIT 50`
- **Preloads**: `[:book, :seller]`

### Read: User's listings
- **Table(s)**: `op.listings`
- **Query**: `Marketplace.list_user_listings(seller_id)` — `WHERE seller_id = ? ORDER BY created_at DESC LIMIT 50`
- **Preloads**: `[:book, :seller]`

---

## 6. Event Flow & Lifecycle

### Events Emitted
- **`listing.created`**: On draft creation. Payload: `{ book_id, seller_id }`
- **`listing.activated`**: On draft -> active. Payload: `{ book_id, seller_id }`
- **`listing.removed`**: On active -> removed. Payload: `{ book_id, seller_id }`
- **`listing.sold`**: On active -> sold. Payload: `{ book_id, seller_id }`
- **`listing.expired`**: On active -> expired (background job). Payload: `{ book_id, seller_id }`

All emitted via `Events.emit_safe/1` within the `Ecto.Multi` transaction.

### Event Handlers Triggered
N/A — no handlers currently subscribe to listing events.

---

## 7. Background Jobs (Oban)

### ListingExpiryJob (referenced)
- **Worker**: Referenced in `Marketplace` docs as `ListingExpiryJob`
- **Queue**: Presumed `:default`
- **What it does**: Finds active listings past their `expires_at` timestamp and calls `Marketplace.expire_listing/1` for each
- **On success**: Listing expired, placement denormalized, event emitted

---

## 8. External Service Calls

N/A — marketplace listings are entirely local. No external services called during listing CRUD.

---

## 9. Storage (R2 / Local)

### Condition photos (future)
- **Operation**: Upload of 1-3 condition photos
- **Key pattern**: Listing photo URLs stored in `photo_urls` array field
- **Module**: Reuses `Stacks.Storage` (same as book upload flow)
- **Note**: Photo upload for listings uses the same infrastructure as book uploads but is not yet fully integrated in the current codebase

---

## 10. Cache Interactions

N/A

---

## 11. dbt Model Dependencies

### `stg_listings`
- **Model**: `stg_listings`
- **Trigger**: Manual/periodic dbt run
- **Materialisation**: Staging view
- **Consumer**: `mart_marketplace_activity`

### `mart_marketplace_activity`
- **Model**: `mart_marketplace_activity` (view)
- **Trigger**: Periodic dbt run
- **Materialisation**: View — `SELECT status, COUNT(*) AS listing_count FROM stg_listings GROUP BY status`
- **Consumer**: Metrics dashboard marketplace section

---

## 12. Elm Frontend State Machine (Detail)

### Route
- **Route variant**: `Route.MarketplaceCreate`
- **URL**: `/marketplace/create`
- **Public or authenticated**: Authenticated

### Init
- **`initPage` branch**: Calls `Api.getMyPlacements token PlacementsReceived`
- **API calls on init**: `GET /api/placements/mine`
- **Initial model state**: `{ placements = Loading, selectedPlacementId = Nothing, condition = Good, pricingMode = Fixed, priceInput = "", contactInfo = "", description = "", submitState = NotAsked, createdListing = Nothing }`

### Update cycle
- **Msg**: `PlacementsReceived result` -> `placements = Success/Failure`
- **Msg**: `PlacementSelected placementId` -> updates `selectedPlacementId`
- **Msg**: `ConditionSelected condStr` -> parses to `Condition` (New/LikeNew/Good/Fair/Poor)
- **Msg**: `PricingModeSelected modeStr` -> parses to `PricingMode` (Fixed/Offer)
- **Msg**: `PriceChanged priceStr` -> updates `priceInput`
- **Msg**: `ContactInfoChanged info` -> updates `contactInfo`
- **Msg**: `DescriptionChanged desc` -> updates `description`
- **Msg**: `SubmitListing` -> validates (placement selected + contact info), calls `Api.createListing`, sets `submitState = Loading`
- **Msg**: `ListingCreated (Ok listing)` -> `submitState = Success`, `createdListing = Just listing`
- **Msg**: `ActivateListing listingId` -> calls `Api.activateListing`
- **Msg**: `ListingActivated (Ok listing)` -> `OutMsg = NavigateTo Route.MarketplaceMyListings`
- **OutMsg**: `NoOut` for all form interactions; `NavigateTo Route.MarketplaceMyListings` on successful activation

### View
- **Key elements**:
  - **Form view** (when `createdListing = Nothing`):
    - Book selector: dropdown from user's placements (title + shelf name)
    - Condition: radio buttons for New, Like New, Good, Fair, Poor
    - Pricing: radio buttons for Fixed (with ZAR price input) / Open to Offers
    - Contact info: text input (email, phone, or WhatsApp)
    - Description: textarea (optional)
    - Submit button: "Create Listing" (disabled when no placement selected or no contact info)
    - Error display on failure
  - **Success view** (when `createdListing = Just listing`):
    - "Listing Created" heading
    - Status badge (draft/active/sold/expired/removed)
    - Condition label
    - Price display ("R X" or "Open to offers")
    - "Activate" button (only when status is Draft)
- **ARIA attributes**: Standard form labels and inputs
- **CSS classes**: `page page--marketplace-create`, `marketplace-create__form`, `marketplace-create__radio-group`, `marketplace-create__radio-label`, `marketplace-create__success`, `marketplace__status-badge--draft/active/sold/expired/removed`, `form-group`, `form-label`, `form-input`, `btn btn--primary`

---

## 13. Operational Metrics

- **Oban job counts for `ListingExpiryJob`**: enqueued, completed, failed, retried — finds and expires active listings past `expires_at`
- **Listing CRUD counts**: `POST /api/listings` (create), `PUT /api/listings/:id/activate` (activate), `PUT /api/listings/:id/deactivate` (remove), `PUT /api/listings/:id/sold` (mark sold) — success/failure breakdown per endpoint
- **Listing state transition counts**: draft->active, active->removed, active->expired, active->sold — tracked via emitted events (`listing.created`, `listing.activated`, `listing.removed`, `listing.sold`, `listing.expired`)
- **Event emission counts**: all 5 listing event types emitted via `Events.emit_safe/1` within `Ecto.Multi` transactions
- **Ownership verification failures**: `Marketplace.verify_ownership/2` returning `{:error, :unauthorized}` — indicates unauthorized access attempts
- **Unique constraint violations**: `listings_active_book_seller_idx` conflicts — duplicate listing attempts per book per seller

---

## 14. Performance & Usability Metrics

- **Marketplace listing creation time**: elapsed time from `POST /api/listings` to 201 response — includes `Ecto.Multi` (placement verification + insert + event emission). Target: <200ms.
- **Activation rate**: percentage of draft listings that transition to active — measures conversion from creation to publishing
- **Time-to-sold**: elapsed time from `listing.activated` (`listed_at`) to `listing.sold` (`sold_at`) — key marketplace health metric
- **Listing expiry rate**: percentage of active listings that expire (reach `expires_at` without being sold or removed) — high expiry rate may indicate pricing or demand issues
- **Time-to-activation**: elapsed time from `listing.created` to `listing.activated` — measures seller follow-through
- **Listings per user**: average active listings per seller — capacity planning metric
- **Placement verification latency**: time for the `:placement` step in `Ecto.Multi` to verify the seller has an active placement — involves join across `op.bookshelf_placements` and `op.bookshelves`

---

## 15. Cost Tracking

- **Fly.io compute**: core app machine time for listing CRUD endpoints and `ListingExpiryJob` Oban worker. All operations are database-bound (no external API calls). Fly.io shared-cpu-1x: ~$1.94/month base.
- **Neon compute**: listing operations use `Ecto.Multi` transactions with `SELECT FOR UPDATE` locks (activate/deactivate/sold/expire). Each transaction involves 3-4 database operations. Placement verification joins across two tables. Neon free tier: 191.9 compute hours/month; paid: $0.16/compute-hour.
- **R2 storage** (future — condition photos): 1-3 photos per listing. At ~2MB per photo: ~6MB per listing. 100 active listings: ~600MB. Cloudflare R2 free tier: 10GB storage; paid: $0.015/GB/month.
- **dbt model rebuild**: `stg_listings` and `mart_marketplace_activity` refreshed on periodic dbt runs (not event-triggered for listings). Neon compute cost per refresh is minimal for the simple `GROUP BY status` aggregation.
- **No external API costs**: marketplace is entirely local — no Brave, Together AI, scraper, or vision calls.
