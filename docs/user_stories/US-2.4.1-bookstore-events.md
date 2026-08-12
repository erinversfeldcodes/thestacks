# US-2.4.1 — Discover Relevant Bookstore Events

> ## Status — read this first
>
> **Refreshed 2026-08-06 for #321** (Wave 11), replacing a description that had gone false in three separate ways. The old text described a bare `Finch.build(:get, "#{website_url}/events")` fetch, index-paired regex extraction, and events rendering as amber cards on the Third Spaces page. None of those is the code, and the third was never true.
>
> **What is built** (verified against the code): a compliant egress (robots → rate limit → fuse), sitemap-based path resolution that asks the shop instead of guessing (#307), individual-event-page discovery for shops that publish one event per page (#382), block-scoped heading extraction, optional `event_date`, and a classified batch summary.
>
> **What is not built**: the **structured extractor** (schema.org/Event → `.ics` → LLM fallback), any **cron entry** for the job, any **read endpoint**, and any **surface**. `op.bookstore_events` holds zero rows in production, and the book detail's author section says "Events coming soon" for every book because it is passed `Nothing` unconditionally.
>
> **Owner ruling 2026-07-30**: the bookstore-events vertical is **wired, not deleted**. #321 §25 is the work; the acceptance instrument is a zero-row sweep, `op.bookstore_events` 0 → N on preview *via the real job, not a seed*.
>
> Sections are marked **[BUILT]** or **[TO BUILD]** so no reader has to guess.

---

## 1. User Story

> **As a** user, **I want to** be notified of bookstore events related to authors and books in my collection **so that** I can attend signings, readings, and launches in person.

The system discovers events at bookshops with physical locations — signings, readings, launches, book clubs — and matches them against the reader's collection. If the reader owns books by the featured author, the event is surfaced.

**What they will see** (spec): a highlighted event card — *"Exclusive Books Rosebank: Damon Galgut signing, March 15 — you own 2 of his books."* Date, time, venue, a brief description, a link to the shop's own page. Warm amber highlight.

**Acceptance criteria:**
- Events discovered without reader intervention.
- Matched to authors the reader actually owns.
- **Never an invented date, an invented title, or an invented event.** This pipeline has manufactured confident wrong records twice (§9) and the extraction rules exist because of it.
- Surfaced on the book detail author section and on the Third Spaces page.
- Every fetch goes through the compliant egress; a robots.txt disallow stops the scrape.

---

## 2. UI Interaction Flow

### Current state **[BUILT]** — nothing reaches the reader
`Components.AuthorCard.view` takes `Maybe Author -> Maybe AuthorEnrichment -> Html msg`, and `Page.BookDetail` calls it as:

```elm
AuthorCard.view book.author Nothing        -- BookDetail.elm:1599
```

**`Nothing`, unconditionally, at the only call site.** So `viewEvents` always falls to its no-enrichment branch and every book in the system reads **"Events coming soon"** (`AuthorCard.elm:156`). `upcomingEventsCount` is a field of a type alias that nothing ever constructs — `grep -rn upcomingEventsCount frontend/` returns four hits, all inside `AuthorCard.elm` itself.

The component's own moduledoc says so plainly: *"Since the API does not yet return RSS or event data, those sections show 'Coming soon' stubs."*

This is the **wiring-trace defect class**: built, tested, and connected to nothing.

### Happy Path **[TO BUILD]**
1. The cron fires `DiscoverBookstoreEventsJob` with `%{batch: true}`.
2. Per scrapeable store: resolve where events live, fetch, extract, upsert.
3. Events with an `author_id` matching an author the reader owns books by become visible to that reader.
4. On the book detail overlay, `Components.AuthorCard` renders the count and the events.
5. On the Third Spaces page, events appear as amber-highlighted cards.

### Sad Paths **[BUILT]** — all seven classified
`discover_for_store/1` returns a *classified* outcome so the batch summary can tally reasons apart:

| Outcome | Means | Returned |
|---|---|---|
| Events written | — | `{:ok, {:events, n}}` |
| No resolvable events page | The shop lists none — **a normal fact about a bookshop** | `{:ok, :no_events_page}` |
| robots.txt disallow | A determination, not a failure. Recorded on the store; the job **stops for that store**, does not retry, does not try another path | `{:ok, :blocked}` |
| Shop asked us to back off | `retry_after` logged; this run skipped rather than retried | `{:ok, :paced}` |
| 304 Not Modified | Nothing changed. **Emphatically not "no events"** — existing rows stay | `{:ok, :unchanged}` |
| No scraper config | No config means no declared crawl policy, and guessing one is how the hard rule becomes advisory | `:ok`, with a log line |
| Unexpected status / transport failure | Recorded against the store's health | `{:error, reason}` |
| Store id not found (single mode) | — | `{:cancel, "store not found"}` |

⚠️ **A 304 must not be read as an empty page.** *"Treating a 304 as an empty page would delete every event this store has on the first unchanged run"* (`discover_bookstore_events_job.ex:184-185`).

⚠️ **A robots block used to return a bare `:ok`** and vanished into the no-op clause, so *"a batch in which every store was blocked logged '0 event(s) written' with nothing accounting for it — exactly the indistinguishable-from-broken reading this summary exists to prevent"* (`:99-102`).

### Elm State Machine
- **Component module**: `Components.AuthorCard`
- **Model fields**: `AuthorEnrichment.upcomingEventsCount` — constructed by nothing today
- **Msg flow**: N/A — data passed as props
- **RemoteData states**: N/A — `Maybe`
- **To build**: a decoder for the events payload, and a `Just` at the `BookDetail` call site

---

## 3. API Calls

### `GET /api/books/:id` **[BUILT, but carries no events]**
- **Auth**: Optional · **Pipeline**: `:api` → `:optional_auth`
- **Controller**: `StacksWeb.BookController.show/2`
- Nothing in `Stacks.Books.get_book_detail/1` reads `op.bookstore_events`.

### The read path **[TO BUILD]** — from functions that already exist
`Stacks.Enrichment.Events` has **two unused reader functions**, and #321 §25 names them as the read endpoint's source:

```elixir
Events.upcoming_events(store_id)   # dated only, event_date >= now, asc
Events.listed_events(store_id)     # dated (soonest first) + dateless (last)
```

`grep -rn "upcoming_events\|listed_events" apps/core/lib` outside `events.ex` returns **only** `preload_upcoming_events/1` in `enrichment.ex` — which serves `op.third_space_events`, a **different table**. No caller reads bookstore events.

⚠️ **`listed_events/1` is the one to use for a reader-facing surface, and the distinction is load-bearing:**

> *"'Upcoming' is a claim about time, and a dateless event cannot honestly make it — counting one as upcoming would be a structurally valid payload asserting something we do not know. Dateless events sort last: a reader scanning for the next date should not trip over entries that have none, but the entries are real (the shop's own page carries the details) and belong in the list."* (`events.ex:51-58`)

Both functions are keyed by **`store_id`**. A reader-facing surface wants events by *author* or by *proximity*, so the read path needs a query neither function provides — that is real work, not glue (§17).

---

## 4. Auth & Middleware Guards

- **Plugs fired** (for the eventual read): `SecurityHeaders` → `OptionalAuthPipeline`
- **Visibility checks**: inherited from the host surface. Event data is external and public — a bookshop's own listing — so there is no reader content to protect.
- **Age gate**: inherited from the book detail if the event is surfaced there.
- **Ownership checks**: N/A.

### The guard that matters: the compliant egress **[BUILT]**
Every fetch goes through `ScraperClient.fetch_page/2`, *"the scraper service's single compliant egress: robots.txt is consulted first, then the rate limiter, and both circuit breakers gate the call."*

⚠️ **This job previously issued a bare `Finch.build(:get, "#{website_url}/events")` — no robots check, no rate limit, no fuse — a direct violation of the project's hard rule that robots.txt stops a scrape.** It was never scheduled, so nothing was actually fetched non-compliantly, but *"the violation sat in the code waiting for whoever wired the job up. Fixing the egress before that happened is the whole point: the next person to schedule this will not think to check"* (`discover_bookstore_events_job.ex:17-22`).

**Batch mode uses `Prices.scrapeable_stores/0`, not `all_stores/0`** — the compliant egress is keyed by scraper config, which supplies the base URL *and* the rate limit. A store with a website but no config **cannot be fetched at all**, deliberately.

A robots disallow is recorded via `Prices.record_robots_block/3`; a later successful fetch calls `Prices.clear_robots_block/1`, so *"a lifted disallow resumes by itself"* — self-healing without a second moving part.

---

## 5. Database Interactions

### Read: stores to sweep **[BUILT]**
- **Table**: `op.bookstores`
- **Batch**: `Prices.scrapeable_stores/0`; the skipped count (`all_stores` − `scrapeable_stores`) is logged
- **Single**: `Prices.all_stores() |> Enum.find(...)` — so unlike batch it can be handed a store with no registry key, which `discover_for_store/1` refuses explicitly *"rather than asking the service about `null` — that produces a 404 whose message blames the store rather than the missing config"*

### Read/Write: the resolved events path **[BUILT]**
- **Table**: `op.bookstores` — `events_path`, `events_unresolved_reason`, `events_path_checked_at`, `events_page_etag`, `events_page_last_modified`
- **Module**: `Stacks.Enrichment.EventsPath`

⚠️ **`events_path_checked_at` is what makes a negative verdict re-checkable rather than permanent.** *"An empty `events_path` on its own cannot distinguish 'we looked and there is none' from 'we have not looked yet', and treating the second as the first writes a shop off forever. A shop that adds an events page next month should be found"* (`events_path.ex:35-40`).

And the distinction the whole design turns on — only **one** of these is a fact about the shop:

| Outcome | Means | Recorded as |
|---|---|---|
| Candidates found, one verified | we know where events are | `events_path` |
| Sitemap read, no candidate matched | the shop lists no events page | a *resolved* negative |
| `:no_sitemap_declared` | **we could not look** | unresolved, retry later |
| `truncated: true` | we ran out of budget mid-walk | unresolved, retry later |
| `{:rate_limited, _}` | the shop asked us to wait | unresolved, retry later |

*"Banking [the other three] as 'this shop has no events' is how a temporary condition becomes a permanent verdict."*

### Write: upsert an event **[BUILT]**
- **Table**: `op.bookstore_events`
- **Operation**: INSERT ON CONFLICT `(store_id, title, event_date)` UPDATE `[:description, :location, :url, :author_id, :scraped_at]`
- **Changeset**: `Enrichment.bookstore_event_changeset/2` — required `store_id`, `title`, `scraped_at`; optional `event_date`, `description`, `location`, `url`, `author_id`
- **Idempotency for dateless rows**: held by a `NULLS NOT DISTINCT` unique index (migration `20260804200000`)

⚠️ **`event_date` is deliberately OPTIONAL** (#382, owner ruling 2026-08-04):

> *"The one real event either scrapeable shop publishes is a standalone page with no date anywhere on it (measured: wordsworth's book-signing page, 250,873 bytes, zero dates in any common format), and the extraction rule this pipeline lives by is 'never invent a date'. An event without a date is still real information — the shop's own page carries the details — but it must NOT be counted as 'upcoming'."* (`enrichment.ex:122-131`)

### Read: known authors, for matching **[BUILT]**
- **Table**: `op.authors` — `select: {a.id, a.name}`, loaded once per `parse_events/2` call, rescuing to `[]` on failure
- **Matching**: case-insensitive substring of the author's name in the event title

### GDPR position
`op.bookstore_events` is **external data about businesses and public figures**, not personal data of readers. There is no reader FK, so erasure has nothing to reach here. The matching is done by author name against `op.authors`, which is also not reader data. `author_id` is the only FK besides `store_id`.

---

## 6. Event Flow & Lifecycle **[BUILT]**

### Events Emitted
- **Event type**: `enrichment.events_discovered`
- **Aggregate**: `bookstore` + `store_id`
- **Payload**: `%{events_count: N, store_name: "…"}`
- **Metadata**: `%{actor: "system:discover_bookstore_events_job"}`
- **Emitted by**: `persist_events/2`, **only when `successes > 0`**
- **Emission**: `Stacks.Events.emit_safe/1`

### Event Handlers Triggered
- **`Stacks.Workers.DbtRefreshHandler`** → `DbtRefreshJob` for `["int_event_matches"]`

⚠️ **`persist_events/2` returns the COUNT, and that is not cosmetic.** It returned a bare `:ok`, which meant `summarise_batch/2`'s `{:ok, {:events, n}}` clause **never matched** — *"so the batch summary reported '0 event(s) written' on every run, including runs that wrote events. A dead clause in a summary is worse than no summary: it reads as a measurement."* Found by asserting on the return value of a full `perform/1`, which nothing did before (`:394-400`).

---

## 7. Background Jobs (Oban)

### `Stacks.Workers.DiscoverBookstoreEventsJob` **[BUILT]**
- **Queue**: `:default` · **Max attempts**: 3
- **Args**: `%{"store_id" => uuid}` (single) or `%{"batch" => true}`
- **Uniqueness**: none configured
- **Steps** (batch): `scrapeable_stores/0` → per store `EventsPath.resolve/1` → fetch with conditional-request validators → extract → upsert → classify → `summarise_batch/2`
- **Conditional requests**: `[etag: store.events_page_etag, last_modified: store.events_page_last_modified]`, remembered via `EventsPath.remember_validators/2`. *"The shop sent no body at all, which is the entire saving — an events page is re-read on a schedule and changes rarely."*
- **404 handling**: `EventsPath.forget(store)` so the next run re-resolves rather than re-fetching a path now known to be gone. *"The check belongs here, where the failure shows up, which is why `EventsPath.resolve/1` does not re-verify a known path on every run."*
- **Pacing**: deliberately **no snooze/retry** on `{:rate_limited, retry_after}` — *"Holding a job open to sleep would tie up a worker to accomplish waiting, which the schedule already does for free."*

### ⛔ There is no schedule **[TO BUILD]**
`grep -rn DiscoverBookstoreEventsJob apps/core/config/` returns **nothing**. The crontab in `config/config.exs` has entries for eleven other workers and none for this one. `grep -rn DiscoverBookstoreEventsJob apps/core/lib` outside the worker returns only four *comments* in other modules. **Nothing enqueues this job — not a cron, not an event, not a controller.**

That is the root cause the whole 404-on-`/events` saga sat behind: *"The events pipeline had therefore never written a row, and no test noticed, because every test fed it a fixture body rather than a real shop"* (`events_path.ex:8-10`).

#321 §32 states the constraint the cron must answer, and it is not satisfied by adding a line:

> *"`min_machines_running = 0` (ROOT H): the events cron only fires while a node runs — the child must state how it actually runs in prod (accepting freshness-only cost, or the read-time/event-driven alternative), not just add a crontab line."*

A cron is defensible **here** where it was not for `DiscoverEditionsJob` (see US-2.6.1 §6), because this **refreshes** rather than creates: a missed run means stale events, not a feature that has never existed. But that argument has to be *made* in the child issue, and the freshness cost accepted explicitly.

**Also required**: a `unique` option. Nothing stops the same store being enqueued repeatedly.

---

## 8. External Service Calls **[BUILT]**

### Bookshop websites, through the scraper service
- **Client**: `Stacks.Enrichment.ScraperClient.fetch_page/2` — robots.txt, rate limiter, both fuses
- **Path**: resolved by `EventsPath.resolve/1` from the shop's declared sitemap; **never a hardcoded guess**
- **Auth**: none · **User agent**: identifies the project honestly
- **Fallback**: classified per §2; no store's failure stops the batch

⚠️ **There is deliberately no default events path.** *"Reintroducing a fallback constant would restore the quiet failure: a guess that 404s looks exactly like a shop with no events"* (`:84-90`). And the cost of guessing is real: a Shopify 404 is a *styled* page, **measured at 249,540 bytes** on 2026-07-29.

### Fuse isolation **[TO BUILD]**
Per #321 §30: *"the shared `:scraper_fuse` semantics apply — event scraping must not melt the price path's fuse."* The shared fuse *"opens for 15 minutes after 3"* non-200s (`proto/stacks/internal/v1/scraper.proto:236`), and the same contract already defines outcome types that exist so a determination does not count against it (`:97`, `:102`, `:271`). Event scraping must use them.

---

## 9. Extraction **[BUILT: heuristic. TO BUILD: structured]**

This section replaces the old story's "parses events using regex: `<h2>`/`<h3>` tags for titles, ISO date pattern for dates" — a description of code that had already been twice replaced for manufacturing wrong records.

### Two failures worth knowing before touching this
1. **Index-paired scans.** The original took the *n*th `<h2>` and the *n*th ISO date found **anywhere in the document**. Those lists have no relationship: headings include site chrome ("Subscribe", "Follow us", "Disclaimer" — measured on a real Shopify page) and dates appear in footers, scripts, and JSON-LD. *"So it manufactured confident, wrong records — an event titled 'Follow us' carrying a date from an unrelated part of the page."*
2. **The opposite extreme.** A date was then used only if the whole document contained exactly one distinct date. Honest, but *"a normal listing page — several events, several different dates — yields nothing at all"*.

### What is built now
- **Block scoping** (`heading_blocks/1`): one `Regex.scan(…, return: :index)` pass yields both the full match and the title capture, and each block runs from one heading to the next. **A date is used only if it appears after its own heading and before the next one**, so a date can never be borrowed from another event or from page chrome. The final block stops at `<footer`. A heading whose block holds no date gets `nil` — *"the strictness is kept exactly where it was earned."*
- **Byte offsets** with `binary_part/3`: every boundary lands on ASCII (`<h2…>` / `</h2>`), so a heading containing é or ë is never sliced mid-codepoint — *"demonstrated by the 'multi-byte headings are sliced correctly' test rather than merely reasoned about."*
- **Chrome filtering**: `@chrome_headings` — `subscribe newsletter follow disclaimer privacy terms cart menu search shipping returns contact about login account checkout` — *"Measured on a real Shopify storefront, where every one of these renders as an `<h2>` — so without this filter a page reliably produces several 'events' named after its own navigation."*
- **Individual event pages** (`Stacks.Enrichment.EventPages`, #382): the shops that actually exist publish **one event per page**. Wordsworth has `/pages/treive-nicholas-book-signing-at-our-sea-point-store` sitting in its sitemap between `/pages/careers-at-wordsworth-books` and `/pages/payment-logos`. So a `{:error, {:no_candidate, urls}}` from `EventsPath` is not the end — the harvest rides along with the negative and `EventPages.discover_and_store/2` classifies it.
  - **Slug classifier**: a short list of event-shaped phrases (`book-signing`, `book-launch`, `author-evening`, `meet-the-author`, `poetry-reading`, `story-time`, …), *"deliberately precise rather than broad, because the failure modes are asymmetric: a missed event costs us one listing, while a false positive **invents** an event."*
  - **Ground truth**: the shop's real page list — **45 slugs, exactly one event, 44 negatives** including every tempting near-miss (`halloween`, `mothers-day-promotion`, `celebrate-our-birthday-with-us-chapter30`, `book-of-the-month-subscription`). The test suite pins all 45.
  - **Budget**: at most 5 candidate pages fetched per store per run, *"so a hostile or weird sitemap cannot turn classification into a crawl"*. An over-cap is logged by name — *"never a silent cap: dropped candidates are named, or the run reads as complete."*
  - **Title**: from the page's own `<title>`, with the Shopify shop suffix stripped at the **last** em/en dash separator. The `u` regex flag is load-bearing — *"an em dash is multibyte, and without Unicode mode the character class matches its individual BYTES"*, so the suffix quietly stops being stripped. Falls back to the humanised slug, because *"'Untitled' would be an invented fact."*
  - **Date**: only when the page states exactly one distinct ISO date. The real page states none.

### The structured extractor **[TO BUILD]** — #321 §25
The owner ruling replaces the heading heuristic with a cascade, best evidence first:

1. **schema.org/Event JSON-LD.** Shopify and most CMS event pages emit `<script type="application/ld+json">` with `@type: "Event"`, carrying `name`, `startDate`, `location`, `url`, `description` as **stated fields**. This is the shop *telling* us, and it dissolves the whole title/date pairing problem — there is nothing to pair.
2. **`.ics` / iCalendar.** Where a shop publishes a calendar feed, `DTSTART`/`SUMMARY`/`LOCATION` are unambiguous by specification.
3. **LLM fallback**, last and cost-capped, for pages with neither.

**Non-negotiable when this lands:**
- The extraction rule survives the change: **never invent a date**, and `event_date` stays optional. A structured source that omits `startDate` yields a dateless row, exactly as now.
- The LLM path needs cost caps (#321 §30, Milestone E discipline) and inherits **#314's enum-coverage gate**.
- The heuristic must remain as the fallback below the LLM, not be deleted — it is the only thing that works on a plain HTML listing page.
- ⚠️ Note the irony to avoid: the current code **explicitly skips JSON-LD** (dates in *"footers, scripts and JSON-LD"* were a source of wrong pairings). The structured path must read JSON-LD as **structure**, not scan it as text. Those are different operations on the same bytes, and conflating them is how this regresses.

---

## 10. Storage (R2 / Local)

N/A — event data is stored in the database.

---

## 11. Cache Interactions

None in the pipeline. HTTP-level caching is the conditional-request pair (§7), which is a validator store on `op.bookstores` rather than a cache.

**[TO BUILD]** Once events ride on the `GET /api/books/:id` payload, they are inside `BookDetailCache` — so the refresh must invalidate it. Same requirement, same reason, as US-2.1.1 §11 and US-2.6.1 §6 (#355).

---

## 12. dbt Model Dependencies

### `int_event_matches`
- **Trigger**: `enrichment.events_discovered` → `DbtRefreshHandler`
- **Materialisation**: intermediate
- **Consumer**: the Third Spaces page and the author card's event count — **neither of which reads it today** (§2, §3)

---

## 13. Elm Frontend State Machine (Detail)

### Route
N/A — surfaced within the book detail overlay and the Third Spaces page.

### Init
N/A — passed as enrichment props to `Components.AuthorCard`.

### Update cycle
N/A — pure view rendering.

### View **[BUILT]**
- `upcomingEventsCount > 0` → "N upcoming event(s) at bookstores near you"
- `= 0` → "No upcoming events"
- **no enrichment → "Events coming soon"** ← **this is the only branch that ever renders** (§2)
- **ARIA**: inherits the `AuthorCard` region (`role="region"`, `aria-labelledby="section-author"`)
- **CSS classes**: `book-detail__author-events`, `stub-notice`

**[TO BUILD]** A dateless event needs its own rendering. "No upcoming events" is wrong when three dateless ones exist, and a card with a blank date field is worse — the honest form names the event and links to the shop's page for the details we refuse to guess at.

---

## 14. Operational Metrics

| Metric | Source | Type | How Measured | Target / SLA |
|--------|--------|------|-------------|-------------|
| **`op.bookstore_events` row count** | SQL | Gauge | Total rows | **The acceptance instrument (#321 §48).** 0 → N on preview *via the real job, not a seed*. Every metric below is meaningless until this moves |
| Oban outcome for `DiscoverBookstoreEventsJob` | `oban_jobs` / `mart_job_stats` | Counter | enqueued / completed / failed | **Currently always 0 enqueued** (§7). A run existing at all is the first thing to measure |
| Batch tally | The job's own summary log | Gauge ×6 | `events` / `no_page` / `blocked` / `paced` / `unchanged` / `failed` | **Already built and already earned its keep** — the tally exists because "0 events written" was mistaken for breakage |
| 304 rate | Batch tally `unchanged` | Gauge (%) | Conditional requests that saved a body | Should be high in steady state; that is the courtesy working |
| robots-blocked stores | Batch tally `blocked` + `op.bookstores` | Gauge | Stores with a recorded block | Non-zero is fine and self-healing; **a rise is a compliance signal, not a bug** |
| Path resolution outcomes | `events_unresolved_reason` | Histogram | Resolved-negative vs `:no_sitemap_declared` vs `truncated` vs rate-limited | Only the first is a fact about the shop (§5). A pile-up in the other three means we keep failing to *look* |
| Per-store source health | `op.source_health_checks` (`source_type: "event_source"`) | Gauge | `Monitoring.record_success/failure` | Per store, never aggregated |
| Fuse isolation | `:fuse` state | Gauge | Event fetches melting the price fuse | **0** (§8) |
| Author match rate | SQL | Gauge (%) | `bookstore_events` with non-nil `author_id` | Substring matching produces false positives on common names; this is the number that would show it |
| Dateless share | SQL | Gauge (%) | `WHERE event_date IS NULL` | Expected **high** given #382. A sudden drop after the structured extractor lands is good; a rise to 100% means extraction broke |
| LLM spend | `mart_cost_tracking` | Gauge | Per-page fallback cost | Against the §9 cap |

---

## 15. Performance & Usability Metrics

| Metric | Source | Type | How Measured | Target / SLA |
|--------|--------|------|-------------|-------------|
| Freshness per store | Derived | Histogram (days) | `scraped_at` vs `NOW()` | Bounded by the schedule that does not exist yet |
| Yield per store per sweep | `enrichment.events_discovered` payload `events_count` | Histogram | — | 0 is the normal case for most shops |
| **Extraction precision** | Manual review against the ground truth | Gauge (%) | Stored events that are real events | **The metric this pipeline is judged on.** It has produced "Follow us" as an event; a false positive is worse than a miss |
| Classifier accuracy | The 45-slug ground-truth test | Gauge | 1 positive, 44 negatives | **45/45.** Pinned in the suite |
| Candidate-cap overflow | Logger warning | Counter | Stores with > 5 candidates | Names what was dropped |
| Bytes fetched per event stored | Derived | Gauge | Response size / events | The courtesy cost imposed on a small shop. A 249KB styled 404 for zero events is the number that motivated §8 |
| Reader relevance | Elm event tracking **[TO BUILD]** | Gauge (%) | Surfaced events the reader owns the author of | Cannot be measured until anything is surfaced |

---

## 16. Cost Tracking

| Cost Service | Unit | Volume Driver | Notes |
|-------------|------|--------------|-------|
| **Bookshop bandwidth** | Bytes we cause them to serve | Stores × pages per sweep | **The cost that lands on someone else, and the one this design optimises hardest.** Conditional requests, sitemap resolution instead of guessing, a 5-page cap, and no retry on a 404 all exist to keep it small. A single wrong guess costs a small shop a 249KB styled 404. |
| Rust scraper service | Compute | Fetches proxied through the compliant egress | Shared with the price path — hence the fuse-isolation requirement (§8). |
| Fly.io compute (core) | CPU-ms | Batch runs | Oban worker time, dominated by waiting on HTTP. shared-cpu-1x ≈ $1.94/month base. |
| Neon DB | Compute Units | Store reads, path writes, event upserts, dbt rebuilds | Free tier 191.9 compute-hours/month; paid $0.16/compute-hour. |
| Network egress | Bytes | Outbound requests | Fly.io free tier 100GB/month; $0.02/GB after. |
| **LLM fallback [TO BUILD]** | Tokens | Pages with neither JSON-LD nor `.ics` | **The only new cost the structured extractor introduces**, and the reason the cascade is ordered as it is: schema.org and `.ics` are free, so the model is asked only when the shop has told us nothing. Capped per #321 §30, tracked in `mart_cost_tracking`. |

---

## 17. What #321 Has to Build

Ordered so each step is provable before the next. This is the story's contribution to the child issue, not a substitute for it.

1. **A trigger.** With the ROOT H argument *made* — freshness-only cost accepted, or a read-time alternative chosen — plus a `unique` option. Provable by an `oban_jobs` row existing.
2. **The zero-row sweep.** `op.bookstore_events` 0 → N on preview via the real job. **This is #321 §48's acceptance instrument and no amount of green tests substitutes for it** — the pipeline had ~100% test coverage and zero rows for months.
3. **Fuse isolation**, before the structured extractor multiplies the fetches.
4. **schema.org/Event extraction**, reading JSON-LD as structure rather than scanning it as text (§9). This is where the precision comes from, and it may make the LLM unnecessary.
5. **A read path.** `listed_events/1`, not `upcoming_events/1` (§3) — and a query by author or proximity, which neither existing function provides.
6. **The payload key + `BookDetailCache` invalidation, in one change** (§11).
7. **`Just` at the `AuthorCard` call site** — the single line that turns "Events coming soon" into the feature. With dateless-event rendering (§13).
8. **`.ics` and the capped LLM fallback**, last, and only for shops that gave us nothing structured.
