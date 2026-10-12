# US-2.5.3 — Business Opt-Out from Platform Listings

## 1. User Story

> **As a** business owner whose venue or shop has been discovered and listed on a Stacks instance, **I want to** request removal of my listing **so that** I have control over whether my business appears on the platform.

Every discovered (non-partner) listing includes a discreet "Is this your business?" link. Clicking opens a simple form: business name, contact email, and a choice between "Remove my listing" and "I'd like to become a partner instead." For removal requests: the listing is taken down and the URL is added to an exclusion list so future discovery sweeps do not re-add it. The form does not require account creation. A confirmation email is sent.

The platform owner sees removal requests in the Metrics Dashboard alongside partner requests.

### As shipped — where the built page differs from the story above

The form is built and routed (`frontend/src/Page/ListingRemoval.elm`, `/listing-removal`). Three deliberate divergences from the paragraph above:

- **Submission is not proof of ownership, so it does not always remove.** The story's "the listing is taken down" was implemented unconditionally at first, which meant **anyone who knew a listing's URL could delist any business** (`apps/core/lib/stacks/discovery.ex:542-545`). The test now applied is whether the contact email's domain matches the listing's own domain: a match is honoured immediately, anything else is recorded for human review and **the listing stays live** (`record_removal_request/2`, `discovery.ex:553-585`). The two outcomes are shown to the requester differently, on purpose (§2).
- **No "become a partner instead" radio.** The choice is a link — "Would rather be listed properly? Get in touch about becoming a partner." pointing at `/about` (`ListingRemoval.elm:243-246`) — plus a free-text "Anything you want to add (optional)" field.
- **No confirmation email is sent.** The acknowledgement is on-page only (`viewOutcome`, `ListingRemoval.elm:129-160`). `Discovery.opt_out/2` performs a lookup and an update and enqueues nothing.
- **"Every discovered listing includes the link" is not where the link lives.** The paragraph above put it on the Third Spaces card, and that page is not routed — so for as long as the form has existed it has been reachable by typed URL and by nothing else. The link now sits on the surfaces a reader can actually get to and that actually name a shop: the book detail page's price and author-event blocks, plus the FAQ (§2). Third Spaces keeps its own copy of the link and stays unrouted; nothing about that page changed.

**What they see on the page:** a card headed "Is this your business?", an intro explaining that listings are found publicly and can be taken down with no account needed, three fields (the listing's web address, an email address, an optional note), and a "Request removal" button that is disabled until the two required fields validate. Beneath the email field, a hint says why the address is asked for — that a matching domain is acted on immediately and any other address waits for a person — so the field reads as the thing that decides the outcome rather than as data collection.

---

## 2. UI Interaction Flow

### Happy Path
1. Business owner meets their business named on a page they can actually reach. There are three such places, and the Third Spaces card is not one of them — that page is not routed, so the link it carries (`frontend/src/Page/ThirdSpaces.elm:174-178`) has never been reachable and this story spent that time specifying its own front door out of existence:
   - the book detail page's price block, where a shop the price scraper reads is named beside its price (`frontend/src/Components/PriceInfo.elm:88`);
   - the same page's author-events block, where a shop is named as the host of an event scraped from that shop's own page (`frontend/src/Components/AuthorCard.elm:154`);
   - the FAQ's "Your data" section, under the question "My business is listed here — how do I get it removed?" (`frontend/src/Page/Faq.elm:378`, anchor `/faq#business-listings`).
2. They click the discreet "Is this your business?" link (`frontend/src/Components/BusinessClaim.elm`, linking to `Route.ListingRemoval`). Discreet is the specification, not a style preference: this is a listing the business never asked for, so the way out should be findable without being an apology across the page. It renders only in a block that actually named a shop — the form's first question is the listing's web address, so offering it beside "No price data yet" would send the owner to a question they cannot answer. **The FAQ answer is therefore the only entry that is unconditionally present**, since the two book-detail blocks depend on scrape output that `op.price_snapshots` and `op.bookstore_events` do not yet hold.
3. `/listing-removal` opens (no authentication required — `Main.elm:1170-1171`, `Route.elm:90`). Fields: the listing's web address, a contact email, and an optional note. **The URL is not pre-filled** — the link carries no query parameter, so the requester pastes it.
4. Client-side validation is deliberately minimal (`validate`, `ListingRemoval.elm:66-75`): a non-empty URL and an `@` in the email. Whether a URL matches a listing and whether an address verifies are the server's rules, so re-checking them here would duplicate a rule and drift from it.
5. Submit sends `POST /api/opt-out` with `{url, email, reason}`.
6. **If the email's domain matches the listing's domain**: the source is marked `excluded` with `excluded_at`, `exclusion_requested_at`, and `exclusion_email` set, and the reader-facing `third_space` is delisted too (`discovery.ex:566`). The response is `{status: "removed", …}` and the page says "Your listing has been removed." — "Because you wrote from an address on the same domain as the listing, we could act on it straight away. It will not be added again."
7. **Otherwise**: only `exclusion_requested_at` and `exclusion_email` are written; `status` is deliberately untouched, and that combination *is* the pending state (no new enum value was invented). The response is `{status: "pending_review", …}` and the page says "Your request has been received." — stating plainly that the listing is **still visible** until a person checks it.

### Sad Paths
- **URL not found**: API returns 404. The page says "We could not find a listing at that address. Check it, or paste the link to the page you saw." (`ListingRemoval.elm:272-273`) — the protocol's 404 rendered as something the requester can act on.
- **Invalid email**: API returns 422 — the page says "That email address does not look valid."
- **Missing fields**: API returns 422 `{"error": "url and email are required"}` from the fall-through clause. Not reachable from the form (submit stays disabled), so this guards direct callers.
- **Changeset error**: API returns 422 — the page falls back to "Something went wrong sending your request. Please try again."
- **Unrecognised `status` in the response**: `removalOutcomeDecoder` **fails** rather than defaulting (`frontend/src/Api.elm:886-889`). Defaulting to `Removed` would tell a business their listing is gone on the strength of a value the client does not understand.
- **Re-submitting after a validation error**: `Submit` returns unchanged when `validate` fails, so the visible message is not cleared and no request the server would only reject is fired (`ListingRemoval.elm:91-95`).
- **Two errors at once**: `viewProblem` (`:253-264`) shows a validation problem *or* a server error, never both — a person can act on one thing at a time, and the validation problem is the actionable one.

### Elm State Machine
- **Page module**: `Page.ListingRemoval` (`frontend/src/Page/ListingRemoval.elm`) — a routed, unauthenticated page at `/listing-removal`.
- **Model fields involved**: `url`, `email`, `reason`, `submitting : RemoteData Http.Error RemovalOutcome` (`ListingRemoval.elm:34-39`).
- **Msg flow**: `SetUrl`/`SetEmail`/`SetReason` -> `Submit` -> `Api.requestListingRemoval` -> `Completed (Result Http.Error RemovalOutcome)` (`:42-47`).
- **RemoteData states**: NotAsked -> Loading -> Success `RemovalOutcome` / Failure `Http.Error`.
- **The success type is not `()`**: `RemovalOutcome = Removed | PendingReview` (`frontend/src/Api.elm:841-843`). The two outcomes are kept distinct all the way through the type, because collapsing them into "success" is exactly the bug that would tell a business their listing is gone while it is still live.
- **OutMsg pattern**: none — the page is self-contained and needs nothing from `Main`.

---

## 3. API Calls

### `POST /api/opt-out`
- **Auth**: None (public, unauthenticated)
- **Pipeline**: `:api` -> `:rate_limit_public`
- **Controller**: `StacksWeb.OptOutController.create/2`
- **Client**: `Api.requestListingRemoval` (`frontend/src/Api.elm:859-875`)
- **Request body**: `{ "url": "https://example.com", "email": "owner@example.com", "reason": "optional free text" }`. ⚠️ `reason` is sent by the client and accepted by the action's pattern match, but `Discovery.opt_out(url, %{email: email})` (`apps/core/lib/stacks/discovery.ex:528`) never receives it — the requester's note is discarded. The controller's own `@doc` says "Optionally accepts `reason`", which overstates it.
- **Response (success)** — two distinct shapes, and the distinction is the point:
  - `{ "status": "removed", "message": "Your listing has been removed and will not be re-added." }` — HTTP 200, when the contact address is on the listing's domain.
  - `{ "status": "pending_review", "message": "Your request has been received and will be reviewed. Because the contact address does not belong to the listed website's domain, we verify these by hand before removing a listing." }` — HTTP 200, otherwise.
- **Response (error)**:
  - `{ "error": "No discovered source matches the provided URL." }` — HTTP 404
  - `{ "error": "The provided email address is not valid." }` — HTTP 422
  - `{ "error": "url and email are required" }` — HTTP 422
  - `{ "error": "Unable to process opt-out request." }` — HTTP 422
- **FallbackController handling**: Not used — controller handles errors directly

---

## 4. Auth & Middleware Guards

- **Plugs fired**: `SecurityHeaders` -> `RateLimiter(bucket: :public)`
- **Visibility checks**: N/A — public endpoint
- **Age gate**: N/A
- **Ownership checks**: None — business ownership verified via email (out-of-band confirmation)

---

## 5. Database Interactions

### Read: Find source by URL
- **Table(s)**: `op.discovered_sources`
- **Query**: `Discovery.get_source_by_url(url)` — `WHERE url = ?`
- **Indexes used**: Unique constraint on `url`
- **Schema module**: `Stacks.Enrichment.DiscoveredSource`

### Write: Opt out source (verified requester)
- **Table(s)**: `op.discovered_sources`
- **Operation**: UPDATE — sets `status: "excluded"`, `excluded_at: now`, `exclusion_requested_at: now`, `exclusion_email: email` (`discovery.ex:555-560`)
- **Transaction**: No — single update
- **Denormalization**: ⚠️ **A second table must be written.** The `discovered_source` is how the business was *found*; the `third_space` is what a reader actually sees. Excluding only the source would leave the listing on the map — the exact outcome the request asked us to prevent. `delist_third_space(updated.url)` (`discovery.ex:566`) soft-deletes the reader-facing row.
- **Post-exclusion**: `SourceDiscoveryJob` checks for existing URLs via `Discovery.get_source_by_url/1` before creating new records, so an excluded URL is not re-added.

### Write: Record a pending removal request (unverified requester)
- **Table(s)**: `op.discovered_sources`
- **Operation**: UPDATE of `exclusion_requested_at` and `exclusion_email` **only** (`discovery.ex:576-579`). `status` is deliberately left alone: the listing stays live until a human agrees, and `exclusion_requested_at` set while `status` is not `excluded` *is* the pending state — so no new enum value was needed to represent it.
- **No `third_space` delisting**: correctly, since nothing has been removed.
- **Owner review**: surfaced at `GET /api/admin/removal-requests`, honoured or declined via `PUT …/:id/honour` / `PUT …/:id/decline` (`apps/core/lib/core_web/router.ex:332-334`, `SourceAdminController`). The verbs name what happens to the **listing**, not to the request.

---

## 6. Event Flow & Lifecycle

### Events Emitted
N/A — the opt-out flow does not currently emit a domain event. The status change is recorded directly on the `DiscoveredSource` record.

### Event Handlers Triggered
N/A

---

## 7. Background Jobs (Oban)

N/A — opt-out is a synchronous API call, not a background job. The exclusion is immediate.

---

## 8. External Service Calls

N/A — no external services called during the opt-out flow.

---

## 9. Storage (R2 / Local)

N/A

---

## 10. Cache Interactions

N/A

---

## 11. dbt Model Dependencies

N/A — opt-out does not trigger dbt refreshes. The excluded source is filtered out of downstream queries by its `status: :excluded`.

---

## 12. Elm Frontend State Machine (Detail)

### Route
- **Route variant**: `Route.ListingRemoval` (`frontend/src/Navigation/Route.elm:37`; parser `:90`, path `:181`)
- **URL**: `/listing-removal`
- **Public or authenticated**: Public. Unauthenticated by design — the story says removal "does not require account creation", because a shop owner who never asked to be listed should not have to sign up in order to leave.

### Init
- **`initPage` branch**: `ListingRemoval -> PageListingRemoval ListingRemoval.init` (`frontend/src/Main.elm:1170-1171`). Synchronous — no `Cmd`.
- **API calls on init**: none.
- **Initial model state**: `{ url = "", email = "", reason = "", submitting = NotAsked }`.

### Update cycle

| Msg | Model change | Cmd |
|-----|-------------|-----|
| `SetUrl` / `SetEmail` / `SetReason` | the corresponding field | none |
| `Submit` when `validate` returns `Just _` | none | none — the visible message stands |
| `Submit` when valid | `submitting = Loading` | `Api.requestListingRemoval` with all three fields trimmed |
| `Completed (Ok outcome)` | `submitting = Success outcome` | none |
| `Completed (Err err)` | `submitting = Failure err` | none |

Wired at `Main.elm:2470-2479` (`ListingRemovalMsg`), rendered at `:4245-4246`.

### View
- **Rendered by**: `view` (`ListingRemoval.elm:114-124`) — the outcome replaces the form on success; the heading "Is this your business?" stays either way.
- **Two terminal states, not one**: `viewOutcome` (`:129-160`) branches on `Removed` vs `PendingReview`, and the pending copy says explicitly that the listing is still visible. A business owner who believes it is gone and finds it later has been misled, which is a worse failure than being told there is a wait.
- **Key test hooks**: `removal-url`, `removal-email`, `removal-reason`, `removal-submit`, `removal-validation`, `removal-error`, `removal-removed`, `removal-pending`.
- **Submit button**: disabled while a validation problem stands or a request is in flight; label switches to "Sending…" during `Loading`.
- **CSS classes**: `listing-removal`, `listing-removal__form`, `listing-removal__intro`, `listing-removal__field`, `listing-removal__input`, `listing-removal__textarea`, `listing-removal__hint`, `listing-removal__error`, `listing-removal__submit`, `listing-removal__alt`, `listing-removal__done`, `listing-removal__pending`, `listing-removal__lede`.
- **ARIA**: every field has a `label`/`for` pair. There is no `aria-live` region — the validation and error messages appear and change without being announced, which is a gap on a form whose whole feedback surface is text swapped in place.

---

## 13. Operational Metrics

- **Opt-out request counts**: total `POST /api/opt-out` calls — successful (200) vs failed (404, 422) breakdown
- **Removed vs pending split**: the ratio of `status: "removed"` to `status: "pending_review"` responses. This is the metric that says whether the domain-match test is doing useful work: mostly-pending means the test rarely fires and the flow is effectively manual, and it also sizes the owner's review queue.
- **Review-queue latency**: age of the oldest `discovered_source` with `exclusion_requested_at` set and `status != "excluded"`. A pending request is a listing the business has asked to have removed and which is *still live*, so this is the number with an obligation attached, not just an operational one.
- **Rate limiter activity**: `:rate_limit_public` bucket hits for the opt-out endpoint — monitors for abuse or automated bulk opt-out attempts. Note the pre-verification design change means a flood can no longer delist anyone, only fill the review queue.
- **Source exclusion counts**: number of `DiscoveredSource` records transitioned to `status: "excluded"` over time, plus the corresponding `third_space` delistings — the two should move together, and a divergence means `delist_third_space/1` is failing silently.
- **Duplicate exclusion attempts**: requests where the URL is already excluded — indicates re-discovery prevention is working, or that the "Is this your business?" link remains visible after exclusion.

None of the above are currently emitted as telemetry; they are derivable from the endpoint's HTTP metrics and from `op.discovered_sources`.

---

## 14. Performance & Usability Metrics

- **Opt-out response latency**: `POST /api/opt-out` end-to-end response time — should be <200ms (single DB read + update, no external calls)
- **Opt-out completion rate**: percentage of business owners who land on `/listing-removal` and successfully submit vs abandon. The URL field is not pre-filled, so "had to go and find the link again" is a plausible abandonment cause worth separating from the rest.
- **Re-discovery prevention effectiveness**: after exclusion, verify that `SourceDiscoveryJob` correctly skips excluded URLs via `Discovery.get_source_by_url/1` — zero re-additions expected
- **Partner conversion**: not measurable as originally framed — there is no "become a partner instead" option to select, only an `/about` link (`ListingRemoval.elm:243-246`). Click-through on that link is the available proxy, and it is not instrumented.

---

## 15. Cost Tracking

- **Fly.io compute**: negligible — opt-out is a synchronous API call with minimal compute (one DB read + one DB write). No background jobs, no external service calls.
- **Neon compute**: two database operations per opt-out (read by URL + update status). Effectively zero marginal cost. Neon free tier: 191.9 compute hours/month; paid: $0.16/compute-hour.
- **No external API costs**: opt-out flow is entirely internal. No Brave, SearXNG, Together AI, or scraper calls.
- **Indirect cost savings**: each exclusion removes a URL from future discovery duplicate checks, marginally reducing `SourceDiscoveryJob` processing time.
