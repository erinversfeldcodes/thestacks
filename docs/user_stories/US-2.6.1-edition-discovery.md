# US-2.6.1 — The Other Editions of a Book Find Themselves

## 1. User Story

> **As a** reader who added one printing of a book, **I want** the platform to know about its other editions **so that** I can see which formats exist and get prices from shops that stock a different ISBN than the one I happened to scan.

**Retro-story (spec-of-record).** `Stacks.Workers.DiscoverEditionsJob` shipped as part of the campaign ROOT H remediation and had no story file. Written 2026-08-06 from the code; every claim cites the implementation.

**Family US-2.6.x** is new within the existing Phase 2 (Enrichment) family: *edition discovery*. US-2.1–2.5 cover reviews, prices, author activity, events, and source discovery; the work → editions relationship had no home.

**What the user wants to accomplish:** A work is the abstract book; an edition is a printing with its own ISBN. Shops stock whichever edition they stock. Without this, a price lookup can only ever ask about the one ISBN the reader typed — *"Exclusive Books carries six ISBNs of The Name of the Rose, two of them Spanish; pricing the work means knowing they exist"* (`discover_editions_job.ex:6-8`).

**How they accomplish it — nothing.** This is a system behaviour with a user-visible result:
1. The reader adds a book by any route (photo, manual ISBN, catalogue). A work is created and `book.created` is emitted.
2. `BookCreatedHandler` enqueues `DiscoverEditionsJob` for that work.
3. The job asks Open Library which editions the work has, and creates up to ten of them.
4. On the book detail overlay, the reader now sees an **edition selector** — a dropdown of `"Hardcover — 9780451524935"`-style labels — that appears only when the work has more than one edition (`Page/BookDetail.elm:1196-1226`).
5. Selecting an edition changes the year, publisher, page count and ISBN shown, and the prices below are grouped per edition.

**Acceptance Criteria:**
- Triggered by `book.created`, never by a cron.
- Every discovered ISBN passes the ISBN hard gate — no edition is created on Open Library's word alone.
- Creation is capped per run, and the cap is chosen against what the price layer will consume.
- Re-running does not re-attempt ISBNs already held.
- A work whose ISBN has no Open Library work key is not a failure.
- The book detail cache is invalidated when an edition is added.

---

## 2. UI Interaction Flow

### Happy Path (what the reader sees, and when)
1. Reader adds *The Name of the Rose* by ISBN. The overlay shows one edition and no selector (`List.length book.editions <= 1` → `text ""`).
2. Seconds to minutes later the job completes. `books.edition_merged` invalidates `BookDetailCache` for the work.
3. Reader reopens the book. The edition selector is now present, listing every discovered printing.
4. Reader picks a different edition → `EditionSelected` → `viewEditionDetails` re-renders with that edition's publisher, year, page count, ISBN.
5. Prices appear per edition as `Prices.prices_for_work/2` fills them in over subsequent views (US-2.2.1).

### Sad Paths
- **No primary edition yet**: `perform/1` logs at debug and returns `:ok`. *"Not an error: the work may have been created by a path that has not attached its edition yet"* (`discover_editions_job.ex:44-48`).
- **ISBN resolves but has no Open Library work key**: `{:error, :no_work_id}` → logged at debug, `:ok`. *"Plenty of ISBNs resolve without an Open Library work key at all (Google Books fallback)"* (`discover_editions_job.ex:76-81`).
- **Open Library circuit open**: `{:error, :circuit_open}` is returned to Oban so it retries later — *"the fuse is the signal to retry later, so let Oban do exactly that"*.
- **A listed ISBN fails the hard gate**: skipped, logged at debug, the run continues. *"Expected and frequent: an ISBN Open Library lists but neither upstream can verify fails the ISBN hard gate, which is the gate working as intended"* (`discover_editions_job.ex:109-113`).
- **Duplicate ISBN**: `Books.merge_edition/2` returns `{:error, :duplicate_isbn}` from the changeset's unique constraint; the row is never updated.
- **Unexpected args**: `{:cancel, "invalid args"}` — cancelled, not retried, since a malformed job cannot become well-formed.

### Elm State Machine
No state machine of its own. The result is consumed by `Page.BookDetail`:
- **Model field**: `book.editions : List Edition`, `selectedEdition : Maybe Edition`
- **Msg**: `EditionSelected String` → looks the edition up by id in `book.editions` (`BookDetail.elm:499`)
- **Rendered by**: `viewEditionSelector` (dropdown, hidden below two editions), `viewEditionDetails` (per-edition metadata)
- ⚠️ Grouping prices into editions happens **client-side** — *"it is a presentation concern"* (`BookDetail.elm:252`).

---

## 3. API Calls

This story has no endpoint of its own. Its output reaches the reader through:

### `GET /api/books/:id`
- **Auth**: Optional · **Pipeline**: `:api` → `:optional_auth`
- **Controller**: `StacksWeb.BookController.show/2`
- **Relevance**: the response carries the work's full `editions` list. This is the read that `BookDetailCache` fronts, and therefore the read that a merge must invalidate.

### `POST /api/books/:id/merge-format`
- The **manual** counterpart: a reader adding a format by hand goes through `Books.merge_edition/2` too (`book_controller.ex:140`). US-1.1.8 (multi-format merge) is that story. The job and the reader share one write path, which is why the ISBN gate and the field-narrowing rules below apply to both.

---

## 4. Auth & Middleware Guards

None — this is an Oban worker with no HTTP surface.

The guard that matters is the **ISBN hard gate**, and it is applied inside the write rather than at a boundary this job could skip. `Books.merge_edition/2` calls `resolve_for_write/1` before touching the database, so an ISBN Open Library lists but neither Open Library nor Google Books can verify never becomes a row.

⚠️ **The caller's field set is deliberately narrow, and that is a security property.** `merge_edition/2` accepts only `isbn` and `format_label` from its caller; everything else (`cover_image_url`, `page_count`, `publisher`, `publication_year`, `open_library_id`, `google_books_id`, `verification_source`) comes from the **resolver**. `StacksWeb.BookController.merge_format/2` hands that function raw request params, so honouring a caller-supplied `publisher` or `open_library_id` *"would make `POST /api/books/:id/merge-format` a mass-assignment hole over exactly the columns that record where an ISBN's verification came from"* (`books.ex:963-978`). This job passes only `%{isbn: isbn}` — it does not even state a format label, because Open Library's edition list does not reliably say.

**Visibility / age-gating**: a discovered edition inherits nothing. It attaches to an existing work, and the work's `visibility_tier` governs. There is no path by which discovery can widen an audience.

---

## 5. Database Interactions

### Read: the work's primary ISBN
- **Table**: `op.book_editions`
- **Query**: `where book_id == ^book_id and is_primary == true, select: isbn, limit: 1`
- **Nil is a valid answer** — see the sad path above.

### Read: ISBNs already held for this work
- **Table**: `op.book_editions`
- **Query**: `where book_id == ^book_id, select: isbn` → `MapSet`
- **Why**: *"Skipping ISBNs we already hold keeps the cap meaningful: without it a re-run would spend its whole budget re-attempting rows that exist and rediscovering nothing"* (`discover_editions_job.ex:98-99`).

### Write: create an edition (× up to 10)
- **Table**: `op.book_editions`
- **Operation**: INSERT via `Books.merge_edition/2` → `book_edition_changeset/2`
- **Fields written**: `isbn`, `book_id`, `is_primary: false` (hardcoded), resolver-supplied metadata, `verification_source`
- **Constraint**: unique on `isbn`; the partial index `op.book_editions_one_primary_per_book` is untroubled because every merged edition is non-primary
- **Transaction**: one insert per edition, not a Multi. A partial run is a valid outcome — some editions discovered is better than none.

⚠️ **`is_primary: false` is load-bearing far beyond this story.** Because `merge_edition/2` hardcodes it and `Shelving.place_book/3` always writes the work's *primary* edition onto a placement, **no placement in the system has ever named a merged edition.** That fact is what makes the owner-side un-merge able to reason about placement disposition at all — see US-20.2.1 §5.

### The two caps, and why they are different numbers
| Cap | Value | Protects | Where |
|-----|-------|----------|-------|
| Fetch | 50 | Open Library, from an unbounded page walk | `ISBNResolver.@max_editions_per_work` |
| Create | 10 | **Our own budget** — `merge_edition/2` re-resolves each ISBN to honour the hard gate, so fifty merges is fifty resolver races on a first-time book | `DiscoverEditionsJob.@max_created_per_run` |
| Price | 5 | One-person bookshops, from an (editions × stores) fan-out | `Prices.@max_editions_per_refresh` |

Ten is *"chosen against the consumer, not picked round"*: the price layer prices at most five editions per work, so ten gives it more choice than it can use while keeping the cost per new book bounded. *"Discovering fifty editions to price five would be work nobody collects"* (`discover_editions_job.ex:14-24`).

---

## 6. Event Flow & Lifecycle

### Events Consumed
- **`book.created`** → `Stacks.Enrichment.Handlers.BookCreatedHandler.handle_event/1`, which enqueues this job (`book_created_handler.ex:40`, `79-95`).

⛔ **Triggered by an event rather than a cron, and that is the lesson of the whole thing.** *"This **creates** rather than refreshes, and a cron that creates is the defect that left `discovered_sources` empty for months (campaign ROOT H). Work should arrive in proportion to catalogue growth"* (`discover_editions_job.ex:11-12`). The same reasoning is spelled out at length in `BookCreatedHandler`'s moduledoc for its sibling, `DiscoverAuthorSourcesJob`: a cron entry that may not fire — because the platform scales to zero — means the feature has **never existed**, not that it is stale.

### Events Emitted
- **`books.edition_merged`** — one per created edition, emitted by `Books.merge_edition/2` via `Events.emit_safe/1`
- **Aggregate**: `book_edition` + the new edition's id
- **Payload**: `%{isbn: isbn, work_id: work_id}`

### Event Handlers Triggered
- **`Stacks.Books.Handlers.CacheInvalidationHandler`** on `books.edition_merged`.

⚠️ **Why that subscription exists.** An edition merge is a write to what `GET /api/books/:id` serves: the work gains a row in its `editions` preload, which is the very thing `BookDetailCache` holds. *"Nothing else announced it, so the cache went on serving the pre-merge work for its full 5-minute TTL and the merge prompt's own 'View Book' link showed the reader a book without the edition they had just added (#355)."* The registry comment names this job explicitly: *"Emitted by `Books.merge_edition/2`, so `Stacks.Workers.DiscoverEditionsJob` is covered by the same wire"* (`events/registry.ex:45-56`).

---

## 7. Background Jobs (Oban)

### `Stacks.Workers.DiscoverEditionsJob`
- **Queue**: `:default` · **Max attempts**: 3
- **Args**: `%{"book_id" => uuid}`
- **Uniqueness**: `unique: [period: 86_400, fields: [:worker, :args]]` — deduplicated for a day. *"A work's edition list on Open Library does not change on the timescale of a book being added twice, and re-running would spend the creation cap rediscovering rows that already exist"* (`book_created_handler.ex:72-78`).
- **What it does**:
  1. `primary_isbn(book_id)` — the work's primary edition's ISBN, or `nil` → `:ok`
  2. `ISBNResolver.resolve(isbn)` → `open_library_work_id`, or `{:error, :no_work_id}` → `:ok`
  3. `ISBNResolver.editions_for_work(work_id)` → up to 50 ISBN-13s
  4. Reject ISBNs already held, take 10, `Books.merge_edition(book_id, %{isbn: isbn})` on each
  5. `Logger.info "book=… work=… offered=N created=M"`
- **On success**: up to 10 new `op.book_editions` rows, one `books.edition_merged` event each, book detail cache invalidated
- **On failure**: `{:error, :circuit_open}` is the only retryable outcome; everything else that could go wrong is classified as a non-failure and returns `:ok`

⚠️ **Keyed by `book_id`, not by ISBN — the opposite of its sibling.** `BookCreatedHandler` enqueues `TriggerPriceScrapeJob` with `%{isbn: isbn}` and this job with `%{book_id: book_id}`, and the comment states the rule: *"a price is a fact about one edition, whereas the edition list is a fact about the work"* (`book_created_handler.ex:72-74`).

---

## 8. External Service Calls

### Open Library — editions of a work
- **Endpoint**: `GET {works_url}/{work_id}/editions.json?limit=50`
- **Client module**: `Stacks.Books.ISBNResolver.editions_for_work/1`
- **Auth**: none (open API, open data)
- **Circuit breaker**: `@open_library_fuse` — asked before the request (`:blown` → `{:error, :circuit_open}`) and melted on failure (`isbn_resolver.ex:917-938`)
- **Parsing**: `entries[].isbn_13` — a list per edition, and either key may be absent or `null` on sparse records, hence `list_or_empty/1` rather than a `Map.get/3` default. Non-digits stripped, length-13 filtered, deduplicated, capped at 50.
- **Fallback**: none needed — no editions discovered is a valid state, and the reader still has the edition they added.

### Open Library / Google Books — ISBN verification, once per candidate
- Via `Books.merge_edition/2` → `resolve_for_write/1`. This is the expensive half of the job and the reason the creation cap is 10 rather than 50.

---

## 9. Storage (R2 / Local)

N/A. Cover images for a discovered edition are stored as `cover_image_url` — a remote URL supplied by the resolver — not copied into R2.

---

## 10. Cache Interactions

- **Cache**: `Stacks.Books.BookDetailCache` (ETS, keyed by work id, 5-minute TTL)
- **Operation**: invalidate
- **Key**: the work id
- **Invalidation trigger**: `books.edition_merged` → `CacheInvalidationHandler` (§6)
- **Also read-through**: `cache.isbn_resolver_cache` fronts `ISBNResolver.resolve/1`, so a candidate ISBN already resolved recently costs no outbound request. Swept by `CacheSweepJob` at 03:30 UTC.

---

## 11. dbt Model Dependencies

### `stg_book_editions`
- **Model**: `stg_book_editions` (staging, proto-generated per #131 — do not hand-edit)
- **Trigger**: not triggered by this story — `books.edition_merged` is subscribed only by `CacheInvalidationHandler`
- **Consumer**: `int_book_detail_view` is the **only** model that selects from it (verified 2026-08-06: `grep -rl stg_book_editions dbt/models/` returns `int_book_detail_view.sql` and `staging/schema.yml`, nothing else)

⚠️ **Two corrections for the mapping owner.** `docs/implementation-mapping.md:2180` and `:2198` list `int_format_distribution` as a consumer of `stg_book_editions` (and as US-1.5.4's model). **That model does not exist** — `find dbt -name "*format*"` returns nothing. Whatever format-distribution analytics the mapping promises are unbuilt, so this story's output feeds exactly one intermediate model.

⚠️ **Gap worth naming:** `books.edition_merged` does **not** enqueue a dbt refresh, so a burst of discovered editions leaves `int_book_detail_view` stale until the nightly `{"0 5 * * *", DbtRefreshJob, args: %{full: true}}` run. Acceptable — the reader-facing book detail is served from Postgres via `BookDetailCache`, not from the warehouse — but it is a real staleness window and it is not a documented decision anywhere else.

---

## 12. Elm Frontend State Machine (Detail)

### Route
N/A. The result surfaces inside the book detail overlay, which does not change the URL.

### Init
`Page.BookDetail.init` fetches `GET /api/books/:id`; `book.editions` arrives with it. `selectedEdition` defaults to the work's primary.

### Update cycle
- **Msg `EditionSelected editionId`**: `List.filter (\e -> e.id == editionId) book.editions |> List.head` → `selectedEdition`; `viewEditionDetails` and the price grouping re-render. No API call — every edition is already in the payload.

### View
- **Key elements**:
  - `viewEditionSelector`: renders **only** when `List.length book.editions > 1`. Option label is `formatLabel ++ " — " ++ isbn`, or bare `isbn` when the format is unknown — which is what a job-discovered edition will usually be, since the job supplies no `format_label`.
  - `viewEditionDetails`: format, publication year, publisher, page count, ISBN for the selected edition
- **ARIA attributes**: a bare `select` with no `label` or `aria-label`. **Gap:** a screen-reader user hears an unlabelled combobox. Belongs to the US-19.1.1 family.
- **CSS classes**: `book-detail__edition-selector`, `book-detail__edition-select`, `book-detail__meta-details`, `book-detail__meta-item`, `book-detail__meta-item--format`
- **Test id**: `edition-selector`

---

## 13. Operational Metrics

| Metric | Source | Type | How Measured | Target / SLA |
|--------|--------|------|-------------|-------------|
| Oban outcome for `DiscoverEditionsJob` | `oban_jobs` / `mart_job_stats` | Counter | completed / retryable / cancelled / discarded | `cancelled` > 0 means malformed args are being enqueued |
| `offered` vs `created` per run | Logger info (`offered=N created=M`) | Histogram | The job's own log line | **The ratio is the health metric.** `created` ≪ `offered` means the hard gate is rejecting most of Open Library's list — expected, but a *sudden* collapse means a resolver problem, not a data problem |
| `DiscoverEditionsJob: skipped <isbn>` | Logger debug | Counter | Per hard-gate rejection | Baseline; needs debug level to see, which is a gap (§16) |
| `open_library_fuse` state | `:fuse` / `op.source_health_checks` | Gauge | Blown / reset transitions | A blown fuse stalls discovery entirely; jobs pile up as `retryable` |
| `op.book_editions` rows per work | SQL | Histogram | `count(*) GROUP BY book_id` | **The zero-row sweep for this story**: works with exactly one edition and no `DiscoverEditionsJob` in `oban_jobs` mean the trigger is not firing |
| `books.edition_merged` event count | `event_log` | Counter | Rows with that `event_type` | Must equal created editions across job + manual paths |
| `BookDetailCache` invalidation count | ETS / handler | Counter | Invalidations from `books.edition_merged` | 1 per merged edition — a shortfall reproduces #355 |
| ISBN resolver calls per job run | `op.source_health_checks` | Counter | 1 (work lookup) + up to 10 (verification) | ≤ 11 per run. Higher means the known-ISBN rejection is not working |

---

## 14. Performance & Usability Metrics

| Metric | Source | Type | How Measured | Target / SLA |
|--------|--------|------|-------------|-------------|
| `edition_discovery.latency` | Oban telemetry | Histogram (s) | Job enqueue → completion | p95 < 60s. Dominated by up to 11 sequential upstream round trips |
| `time_to_multi_edition` | Derived | Histogram (min) | `book.created` → the work having ≥ 2 editions | The reader-facing number: how long until the edition selector appears |
| `edition_selector_visibility_rate` | Derived | Gauge (%) | Works with > 1 edition / all works | Directly measures whether this story delivers anything at all |
| `edition_discovery.yield` | Logger info | Histogram | `created` per run | 0 for most works (many books have one edition); the distribution matters, not the mean |
| `price_coverage_per_work` | Derived | Gauge | Editions with a price / editions held | The downstream justification for the 10-cap. If this sits far below 5/10, the cap is too generous |

---

## 15. Cost Tracking

| Cost Service | Unit | Volume Driver | Notes |
|-------------|------|--------------|-------|
| Open Library API | Requests (free, rate-limited by courtesy) | 1 work-editions call + up to 10 verification calls per new book | The verification calls are the real spend, and the creation cap of 10 is the control. Read-through `cache.isbn_resolver_cache` absorbs repeats. |
| Google Books API | Requests | Fallback verification per candidate ISBN | Only when Open Library cannot verify. Free tier with a daily quota. |
| Fly.io compute (core) | CPU-ms per run | New books added | Mostly waiting on HTTP. One `:default` queue slot for the duration. |
| Neon DB | Compute Units | 2 reads + up to 10 inserts + up to 10 event rows per run | Bounded by the cap. |
| **Downstream price scraping** | Requests to bookshops | Editions × stores, capped at 5 editions per read | **This is the cost this story creates for someone else**, and it is why the cap chain exists: 76 ISBN-13s × 11 seeded stores would be ~800 requests against mostly one-person bookshops for a single page view (`prices.ex:158-166`). |

---

## 16. Known Gaps

1. **`format_label` is always `nil` for discovered editions**, because the job passes only the ISBN. So the edition selector labels them by bare ISBN — `"9788845292613"` rather than `"Paperback — 9788845292613"` — which is not a useful choice for a reader. The resolver never supplies a format label and Open Library's edition list is not reliably parsed for one.
2. **The edition `select` has no accessible label** (§12).
3. **No dbt refresh on `books.edition_merged`** (§11), so `int_book_detail_view` is stale until the nightly full run. The same section records a phantom model (`int_format_distribution`) that the mapping claims and dbt does not have.
4. **Hard-gate rejections are logged at `debug`**, i.e. invisible at the default level. The `offered`/`created` ratio in the info line is the only default-visible signal, and it does not say *which* ISBNs were refused or why.
5. **`ISBNResolver.editions_for_work/1` reads only `isbn_13`.** An edition listed with an ISBN-10 alone is invisible to this job — a real gap for pre-2007 printings, which is exactly the long-tail this story exists to find.
6. **No backfill.** The trigger is `book.created`, so every work that existed before the job was wired has never been asked. There is no one-off sweep, and adding a cron one would reintroduce the failure mode §6 warns about — the right shape is a targeted, owner-invoked run.
