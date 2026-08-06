# US-2.1.1 — View Aggregated Review Sentiments (Sanctioned Sources Only)

> ## Status — read this first
>
> **This story is a SPEC, not a description of a working surface.** The scraping-based implementation it used to describe was **deleted** in Wave 9 (#323) under **owner ruling D6, 2026-07-30: *the story survives, re-scoped***. What was removed: `Stacks.Workers.FetchReviewsJob`, the `Stacks.Enrichment.Reviews` context, `Stacks.Enrichment.MockReviewFetcher`, and the `Components.ReviewSummary` Elm component. Nothing writes `op.review_snapshots` and nothing reads it.
>
> **What survives** (verified 2026-08-06): the `op.review_snapshots` table, the proto message `ReviewSnapshot` (`proto/stacks/common/v1/enrichment.proto:146-177`) and its generated Ecto schema `Stacks.Enrichment.ReviewSnapshot`, the `Stacks.Enrichment.review_snapshot_changeset/2` validator, and three dbt models — `stg_review_snapshots`, `int_review_sentiment`, `mart_book_reviews`. The contract and the storage are intact; the acquisition and display layers are gone.
>
> **What ruling D6 changed about the spec**: reviews may come **only from sanctioned sources**. Open scraping of review platforms is out. §4 is the new source policy and is the substance of this revision; everything downstream of it follows.
>
> Written 2026-08-06. Sections describing behaviour are written in the future tense where the behaviour does not exist.

---

## 1. User Story

> **As a** user, **I want to** see a summary of what people think about a book **so that** I can get a balanced sense of reception without reading hundreds of reviews.

**What the user wants to accomplish:** Open a book they are considering and get an honest, attributed sense of how it landed — without leaving The Stacks to assemble it from four tabs, and without being sold a single aggregated number that hides disagreement.

**What they will see on the page** (spec):
- A "What People Think" section in the book detail overlay, already populated — the reader never triggers a fetch.
- One card **per source**, each naming its source explicitly: source name, a one-sentence summary, a colour-coded sentiment bar (deep red critical → warm amber mixed → deep green glowing), an optional rating, and a link to the source.
- A "Last refreshed: 3 days ago" line at the bottom of the section.
- Refresh cadence follows the reader's own interest: books in the Reading Pile refresh more often than books in the Library.

**Acceptance criteria:**
- Per-source cards with summary, score, and a link back to the source.
- Colour-coded sentiment bar per source.
- "Last refreshed" timestamp.
- Populated in the background, without user intervention.
- **Every card names a sanctioned source, and the sanctioned-source list is enforced in code, not by convention** (§4).
- No source's full review text is stored — link, do not host.

---

## 2. UI Interaction Flow

⚠️ `Components.ReviewSummary` **does not exist.** `Page.BookDetail` has no reviews section — `grep -n "Review" frontend/src/Page/BookDetail.elm` returns nothing (verified 2026-08-06). The flow below is the spec to build.

### Happy Path (spec)
1. Reader opens a book detail overlay.
2. The "What People Think" section renders from data already in the book-detail payload.
3. With data: one card per sanctioned source.
4. Each card shows source name, summary, sentiment bar, optional rating, and "Last refreshed".
5. Reader follows a card's link to the original in a new tab.

### Sad Paths (spec)
- **No reviews yet for this book**: "No reviews yet." — not a spinner, and not a fabricated neutral score.
- **Fetch failed**: "Could not load reviews."
- **Not yet loaded**: this is the state that needs the most care. The deleted component rendered **placeholder cards for GoodReads, Storygraph, and Reddit** with "Sentiment data coming soon" stubs. **Do not rebuild that.** Naming three specific platforms as forthcoming sources is now false for two of them (§4), and a card shaped like a real card is the "structurally valid but false payload" failure this project has hit before. An absent section is honest; a promised one is not.
- **A source has been de-sanctioned**: its existing snapshots must stop being displayed. A source list that can only grow is not a policy.

### Elm State Machine (spec)
- **Component module**: `Components.ReviewSummary` (to be written)
- **Model fields**: `RemoteData e ReviewData`, passed as a prop rather than owned — reviews belong to the book detail fetch
- **Msg flow**: none. A pure view function, `view : RemoteData e ReviewData -> Html msg`
- **RemoteData states**: `NotAsked` (render nothing) / `Loading` / `Success` (cards, or the empty message) / `Failure`
- **OutMsg pattern**: N/A — stateless

---

## 3. API Calls

### `GET /api/books/:id`
- **Auth**: Optional (`:optional_auth` pipeline)
- **Pipeline**: `:api` → `:optional_auth`
- **Controller**: `StacksWeb.BookController.show/2`
- **Response (success)**: book detail JSON — which **does not currently include review data**. `Stacks.Books.get_book_detail/1` does not read `op.review_snapshots` (verified: `grep -in review apps/core/lib/stacks/books.ex` returns nothing relevant).
- **Response (error)**: `{error: "Not found"}` — HTTP 404
- **To build**: a `reviews` key on this response, served from the database, cached behind `BookDetailCache` like the rest of the payload. No separate endpoint — a second request for a section of one page is a round trip the reader pays for nothing.

---

## 4. Source Policy — Sanctioned Sources Only (ruling D6)

**This section is the substance of the re-scope and governs everything below it.**

### The rule

> A review source is **sanctioned** when we have a standing, checkable right to the data: an open licence, an official API used within its terms, or the consent of the party that produced it. Everything else is out — including sources we are technically able to fetch.

"Technically able" was the old standard, and it was not a standard. `docs/technical-architecture.md:4959` already recorded the problem in the project's own risk table: **GoodReads — "no public API since 2020, ToS prohibits scraping"** — and the deleted implementation scraped it anyway, hedged by a suggestion to *"consider scraping only aggregate data (rating, count) not full reviews"*. A mitigation for an activity the terms forbid outright is not a mitigation.

### Sanctioned

| Source | Basis | Status |
|--------|-------|--------|
| **Open Library** | Open data (CC0 dumps), open API, no key. Already the ISBN spine of the platform via `Stacks.Books.ISBNResolver` — the fuse, the cache, and the courtesy limits exist. | **Preferred first source.** Ratings and reading-log counts are the realistic payload; there is no sentiment text to summarise, so a card built on it shows a rating and a count and says so. |
| **Reddit, via the official API** | Public posts, official API, registered app, documented rate limits. `technical-architecture.md:4960` classes it "Low — public posts, Reddit API available (respect rate limits)". | **Sanctioned only through the API.** Fetching `old.reddit.com` HTML because it is easier is not this source; it is scraping wearing this source's name. |
| **Partner-pushed reviews** | The partner produced the content and pushed it to us under the partner agreement. Consent is the basis, and it is on file. | Sanctioned. The inbound partner API (Phase 3, US-9.x) is the transport; `source` records the partner. |
| **Author- and publisher-published feeds** | RSS/Atom exists to be syndicated. Already the mechanism behind US-2.3.1 (`Stacks.Workers.FetchAuthorRSSJob`, `Stacks.Enrichment.RSSFetcher`). | Sanctioned, with the caveat that a publisher's own copy is marketing and must be labelled as its source, not laundered into "what people think". |

### Not sanctioned

| Source | Why |
|--------|-----|
| **GoodReads** | ToS prohibits scraping; no public API since 2020. No amount of aggregate-only restraint makes a prohibited fetch permitted. `goodreads.com` is *already* on `DiscoverAuthorSourcesJob`'s `@social_domains` exclusion list (`discover_author_sources_job.ex:19-22`) — the project's own code has treated it as off-limits for author discovery while the reviews path scraped it. |
| **StoryGraph** | No API. "Smaller platform, be respectful" is a sentiment, not a right. |
| **Anything behind a login or paywall** | Already prohibited by `technical-architecture.md:4970` ("No paywalled content… No login-wall bypassing"). Restated because a review platform is exactly where this temptation lives. |
| **Full review text, from any source** | Retained separately from the source question. `technical-architecture.md`'s "Link, don't host" mitigation is now a hard rule: store a summary and a link, never the reviews. `review_snapshot_changeset/2` already caps `summary` at 500 characters, which is the schema agreeing. |
| **A reader's own imported Goodreads CSV** | **Sanctioned data, wrong story.** A reader's own export is theirs to give (Milestone C, #321), but their rating is personal data *about them* and belongs on their placement (`personal_rating`), inside GDPR export and erasure. Pooling reader ratings into `op.review_snapshots` would turn a per-reader field into an aggregate the erasure path cannot reach. Do not conflate these. |

### Enforcement, not documentation

The proto enum already names the wrong things: `ReviewSource` is `UNSPECIFIED | GOODREADS | REDDIT | STORYGRAPH | OTHER` (`enrichment.proto:49-65`). Proto field numbers are forever, so `REVIEW_SOURCE_GOODREADS` and `REVIEW_SOURCE_STORYGRAPH` cannot be removed — but **no sanctioned write path may produce them.** The enforcement point is the changeset:

- `review_snapshot_changeset/2` must gain `validate_inclusion(:source, sanctioned_sources())`, so an unsanctioned source cannot be persisted even by a caller that means to.
- `source_url`'s host must be checked against the same list, so a snapshot cannot claim a sanctioned `source` while linking somewhere else.
- The two deprecated enum values must be documented as unreachable in `enrichment.proto` — a comment, since the numbers must stay.

⛔ **A policy enforced only in the fetcher is a policy that lasts until the next fetcher.** The reason to put it in the changeset is the reason the ISBN hard gate lives in `Books.merge_edition/2` rather than in its callers: the guard has to be where the write is.

---

## 5. Auth & Middleware Guards

- **Plugs fired**: `SecurityHeaders` → `OptionalAuthPipeline`
- **Visibility checks**: inherited from book detail; review data is platform data, not reader content, so there is no owner/viewer relationship to resolve
- **Age gate**: inherited — if the book is age-gated, an unverified viewer does not reach the detail payload at all, reviews included
- **Ownership checks**: N/A — read-only platform data

---

## 6. Database Interactions

### Read: latest review snapshots for a book (to build)
- **Table**: `op.review_snapshots`
- **Query**: `WHERE book_id = ? ORDER BY scraped_at DESC`, one row per source
- **Indexes**: the composite unique index on `(book_id, source)` serves the conflict target; the query benefits from the `book_id` index
- **Schema module**: `Stacks.Enrichment.ReviewSnapshot` (**proto-generated** — `mix proto.sync`, do not hand-edit)

### Read: books needing a refresh (to build)
The old `Reviews.stale_books/1` is gone along with its context. Whatever replaces it must keep the *cadence* rule from §1 — Reading Pile refreshes sooner than Library — which means the staleness query reads placements, not just `scraped_at`. That is a design note, not a restatement: the deleted implementation used a flat 30-day cutoff and therefore never delivered the cadence the story promises.

### Write: upsert a review snapshot (to build)
- **Table**: `op.review_snapshots`
- **Operation**: INSERT … ON CONFLICT `(book_id, source)` UPDATE
- **Changeset**: `Stacks.Enrichment.review_snapshot_changeset/2` — required `book_id`, `source`, `source_url`, `scraped_at`; optional `sentiment_score`, `summary` (max 500), `rating`, `rating_count`, `stale_after`
- **New validations required by §4**: `validate_inclusion(:source, …)` and a `source_url` host check
- **Transaction**: single upsert per source
- **Denormalisation**: none

### GDPR position
`op.review_snapshots` holds **no personal data** and must keep holding none: no reviewer names, no reviewer handles, no reviewer ids, no full review text. It is external, aggregate, and about a book. That is why it has a dbt staging model at all — and it is the property that a "reader's own CSV" source would destroy (§4).

---

## 7. Event Flow & Lifecycle

### Events Emitted (to build)
- **Event type**: `enrichment.reviews_scraped` — ⚠️ **rename on rebuild.** "Scraped" is the wrong verb for a sanctioned-source pipeline and would leave the event log asserting the practice ruling D6 removed. `enrichment.reviews_refreshed` says what happens.
- **Aggregate**: `enrichment` + a generated UUID
- **Payload**: `{book_count: N}` — deliberately no book ids and no sources, keeping the event log free of anything that grows
- **Emission**: `Events.emit_safe/1`

### Event Handlers (to build)
- **`Stacks.Workers.DbtRefreshHandler`** → `["int_review_sentiment", "mart_book_reviews"]`

**Registry status**: the subscription is **still in place and deliberately so** — `Stacks.Events.Registry:121-129` keeps `enrichment.reviews_scraped => [DbtRefreshHandler]` behind an explicit note:

> *"nothing emits `enrichment.reviews_scraped`. It has a handler here, a model mapping in `DbtRefreshHandler`, and a payload contract — and no emitter anywhere in `apps/core`. The subscription is left in place (it is correct for the event it describes, and removing it would lose the wiring) but it is dead until a review scraper emits. Kept out of `@unsubscribed`, which is for types that ARE emitted; this is the opposite drift and is tracked separately."*

So the wiring survives the deletion, which is the right call — but it means **renaming the event costs something**: the registry entry, the `DbtRefreshHandler` model mapping, and the note all move together. Rename anyway (§7's reason stands), and update all three in one change.

---

## 8. Background Jobs (Oban)

⚠️ **`Stacks.Workers.FetchReviewsJob` is deleted.** `ls apps/core/lib/stacks/workers/ | grep -i review` returns nothing (verified 2026-08-06).

### Its replacement, and the trap to avoid
The deleted job's real defect was not only its sources — per `plans/staff-campaign-2026-07-30.md:80` it belonged to the *"built → tested → never scheduled"* root cause: **it had no crontab entry and no event trigger, so it never ran.** ~1,900 LOC including tests, and zero rows.

So the replacement's first requirement is not a fetcher. It is a **trigger that actually fires**, and the campaign's ROOT H rule applies: `min_machines_running = 0` means a cron entry is not a guarantee. A refresh is a *refresh* rather than a create, so a cron is defensible here where it was not for `DiscoverEditionsJob` (see US-2.6.1 §6) — but the acceptance instrument is a **zero-row sweep on a preview stack**, not a passing test on a fixture body.

### Spec
- **Worker**: `Stacks.Workers.RefreshReviewsJob` (name it for what it does)
- **Queue**: `:default` · **Max attempts**: 3
- **Args**: `%{"book_id" => uuid}` (single) or `%{"batch" => true}`
- **Uniqueness**: required — a per-book trigger with no `unique` option is how a popular book becomes a hundred enqueued refreshes
- **Steps**: select stale books by the cadence rule (§6) → per sanctioned source, fetch through that source's own client → summarise → validate → upsert → record source health via `Monitoring.record_success/2` / `record_failure/3` → emit once per batch
- **On failure**: per-source failures logged and recorded in monitoring; the book's other sources still process

---

## 9. External Service Calls

### Open Library
- **Client**: extend `Stacks.Books.ISBNResolver`'s established pattern — it already holds the `@open_library_fuse`, the read-through `cache.isbn_resolver_cache`, and the courtesy limits
- **Auth**: none
- **Circuit breaker**: `:open_library_fuse` (shared — see the caution below)
- **Fallback**: no card for this source. Not a neutral score.

### Reddit (official API)
- **Client**: to be written. Registered app, OAuth, documented rate limits, honest user agent (`TheStacks/1.0 (+…)`)
- **Circuit breaker**: needs **its own** fuse

⚠️ **Do not share the price path's fuse.** #321's constraints note records the rule for the events vertical and it applies identically here: *"the shared `:scraper_fuse` semantics apply — event scraping must not melt the price path's fuse."* The shared fuse is documented at `proto/stacks/internal/v1/scraper.proto:236` — it *"opens for 15 minutes after 3"* non-200 responses — and the same file already carries two outcome types that exist precisely so a determination does not count against it (`:97`, `:102`, `:271`). A review source failing must not take prices down with it, and the mechanism for saying so already exists in the contract.

### LLM summarisation
The deleted implementation called Together AI's `summarize_reviews/2`, with `Reviews.validate_summary/2` stripping hallucinated URLs and truncating to 500 characters. **That validation was doing real work and must be rebuilt with the pipeline** — a summariser that can invent a URL is a summariser that can invent a citation, and a card whose whole claim is "with citations" cannot carry one.

Two things must be true of any summariser here:
1. **Cost caps.** #321's constraint: *"the LLM fallback needs cost caps (Milestone E discipline)"*. `mart_cost_tracking` is where the spend lands.
2. **A blown fuse means no summary, not no snapshot.** The old behaviour was right: `{:error, :circuit_open}` → `summary: nil`, snapshot still persisted. A rating with no summary is useful; a missing row is not.

**And the honest question first:** if Open Library and partner data are the realistic first sources, and neither carries prose to summarise, the LLM may not be needed at all for v1. A card that shows "4.1 / 5 from 1,204 ratings on Open Library" with a link is a complete, truthful card. Build that before building a summariser.

---

## 10. Storage (R2 / Local)

N/A — snapshots live in the database. And no review text is stored anywhere (§4).

---

## 11. Cache Interactions

- **Cache**: `Stacks.Books.BookDetailCache` (ETS, keyed by work id, 5-minute TTL)
- **Operation**: invalidate on refresh
- ⚠️ **Required by construction.** Once reviews ride on the `GET /api/books/:id` payload (§3), they are inside what `BookDetailCache` holds — so a refresh that does not invalidate serves the pre-refresh shape for up to five minutes. This is #355's defect exactly, and `books.edition_merged` had to learn it the hard way (see US-2.6.1 §6). Subscribe the new event to `Stacks.Books.Handlers.CacheInvalidationHandler` in the same change that adds the payload key.

---

## 12. dbt Model Dependencies

All three models exist and are currently fed by nothing.

### `int_review_sentiment`
- **Trigger**: the refresh event via `DbtRefreshHandler`
- **Materialisation**: intermediate
- **Consumer**: `mart_book_reviews`, `mart_enrichment_gaps`

### `mart_book_reviews`
- **Materialisation**: view — `SELECT book_id, avg_rating, avg_sentiment_score, review_count FROM int_review_sentiment`
- **Consumer**: the Grafana observability surface

### `mart_enrichment_gaps`
- **Materialisation**: view — joins `int_book_detail_view` with `int_review_sentiment` to flag `missing_reviews`
- **Consumer**: the `/api/metrics/enrichment-gaps` endpoint was removed in #267 (the in-app metrics dashboard was superseded by Grafana, ADR-021); the mart is retained for Grafana

⚠️ **Every row in all three is currently empty**, and `mart_enrichment_gaps.missing_reviews` therefore reports 100% — which is correct, and is the cleanest available proof that this story is unbuilt.

---

## 13. Elm Frontend State Machine (Detail)

### Route
N/A — a component within the book detail overlay, not a route.

### Init
Data arrives with the parent's book-detail fetch. No call of its own.

### Update cycle
N/A — pure view function.

### View (spec)
- `NotAsked` → **render nothing** (see the §2 sad path; do not restore the three named placeholder cards)
- `Loading` → spinner with "Loading reviews..."
- `Success []` → "No reviews yet"
- `Success data` → per-source cards: header (source name), summary text, sentiment bar, optional rating ("X / 5"), "Last refreshed"
- `Failure` → "Could not load reviews."
- **ARIA**: `role="region"`, `aria-labelledby="section-reviews"`
- **CSS classes** (⚠️ **all currently orphaned** — present in `frontend/css/main.css` with no Elm consumer, since the component was deleted): `book-detail__section`, `book-detail__reviews`, `book-detail__reviews-grid`, `book-detail__review-card`, `book-detail__review-sentiment`, `book-detail__review-sentiment-fill`. Rebuilding against these adds zero new orphans; `scripts/check-css.sh` is the gate.

---

## 14. Operational Metrics

| Metric | Source | Type | How Measured | Target / SLA |
|--------|--------|------|-------------|-------------|
| **`op.review_snapshots` row count** | SQL | Gauge | Total rows | **The acceptance instrument.** 0 → N on a preview stack via the real job, not a seed. Everything below is meaningless until this moves |
| **Unsanctioned-source rows** | SQL | Gauge | `WHERE source NOT IN (sanctioned list)` | **0, always.** The check that ruling D6 is enforced rather than documented |
| **`source_url` host ≠ source's host** | SQL | Gauge | — | **0.** Catches a snapshot claiming a sanctioned source while linking elsewhere |
| Oban outcome for the refresh worker | `oban_jobs` / `mart_job_stats` | Counter | completed / failed / retried | **A run must exist.** The deleted job's defect was never running, and no per-source metric would have shown that |
| Per-source success rate | `op.source_health_checks` | Gauge (%) | `Monitoring.record_success/failure` per source | Per source, never aggregated — an aggregate hides one dead source behind two live ones |
| Fuse state per source | `:fuse` / `op.source_health_checks` | Gauge | Open/closed transitions | **Each source its own fuse** (§9). A shared fuse melting is itself the incident |
| Summary validation rejections | Logger | Counter | Summaries altered by the URL-stripping / truncation validator | > 0 is expected; a sudden rise means the model or the prompt changed |
| LLM spend | `mart_cost_tracking` | Gauge | Per-summary token cost | Against the §9 cap |
| `mart_enrichment_gaps.missing_reviews` | dbt | Gauge (%) | Books with no snapshot | 100% today. Falling is the only progress signal |

---

## 15. Performance & Usability Metrics

| Metric | Source | Type | How Measured | Target / SLA |
|--------|--------|------|-------------|-------------|
| Data freshness per book | Derived | Histogram (days) | `scraped_at` vs `NOW()` | **Must differ by bookshelf.** Reading Pile fresher than Library, or the cadence promise in §1 is unmet — which is exactly what the deleted flat-30-day rule failed |
| Review coverage | `mart_enrichment_gaps` | Gauge (%) | Books with ≥ 1 snapshot | Rising |
| Sources per book | SQL | Histogram | `count(DISTINCT source) GROUP BY book_id` | **> 1 is the point.** One source is a rating, not a balanced sense of reception |
| Card click-through | Elm event tracking | Gauge (%) | Link follows / section renders | Tests whether "link, don't host" serves the reader or just protects us |
| Batch throughput | Oban telemetry | Gauge | Books per batch run | Informational |
| Summary quality | Derived | Gauge (%) | Valid summaries / attempts | Complements the validator's rejection count |

---

## 16. Cost Tracking

| Cost Service | Unit | Volume Driver | Notes |
|-------------|------|--------------|-------|
| **Open Library** | Requests (free, courtesy-limited) | Books refreshed | Read-through `cache.isbn_resolver_cache` absorbs repeats. The cheapest sanctioned source, and the reason to start there. |
| **Reddit API** | Requests against a documented quota | Books refreshed | A registered app has a real ceiling. Budget it the way `BraveClient`'s hard 200/day budget is enforced internally — *"so no trigger can overspend it"* (`book_created_handler.ex:17-18`) — rather than by hoping the trigger is gentle. |
| **LLM summarisation** | ~$0.20 / 1M input, ~$0.60 / 1M output tokens (Llama 3.1 8B class) | Sources with prose to summarise | ~500–2000 input + ~100–200 output tokens per summary ≈ $0.0002–$0.001 per book. Tracked in `mart_cost_tracking`, capped per §9. **Zero if v1 ships without a summariser**, which §9 argues for. |
| **Partner-pushed reviews** | — | — | **Zero.** The partner bears the cost of sending. The cheapest source is the one that pushes. |
| Fly.io compute (core) | CPU-ms | Batch runs | Oban worker time; dominated by waiting on HTTP. |
| Neon DB | Compute Units | Staleness query + upserts + dbt rebuilds | Free tier 191.9 compute-hours/month; paid $0.16/compute-hour. |

---

## 17. Rebuild Checklist

Ordered so that each step is provable before the next.

1. **Fix the write gate first.** `validate_inclusion(:source, …)` + the `source_url` host check on `review_snapshot_changeset/2`; deprecation comments on the two dead proto enum values. Provable by a test that a `"goodreads"` snapshot is refused.
2. **One sanctioned source, end to end.** Open Library ratings → snapshot rows on a preview stack. Provable by the zero-row sweep: `op.review_snapshots` 0 → N via the real job.
3. **A trigger that fires.** With the ROOT H caveat stated in the issue, not assumed away.
4. **The payload key + cache invalidation, in one change.** §3 and §11 together, or #355 recurs.
5. **The component.** Rebuilt against the existing orphaned CSS, with `NotAsked` rendering nothing.
6. **A second source.** Only now is "aggregated" true, and §15's sources-per-book metric becomes meaningful.
7. **A summariser, if and only if a source carries prose** — with the URL-stripping validator and the cost cap in the same change.

**Do not mark this story done on a passing test suite.** Its predecessor had ~890 lines of them and zero rows.
