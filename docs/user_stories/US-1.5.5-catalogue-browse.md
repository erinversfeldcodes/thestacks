# US-1.5.5 — Browse the Whole Catalogue and Shelve What You Find

## 1. User Story

> **As a** reader, **I want to** browse every book the platform knows about — filtered, sorted, and marked with what I already own — **so that** I can find something to add without knowing what I am looking for.

**Retro-story (spec-of-record).** `/catalogue` and `Page.Catalogue` shipped early and had no story file. Written 2026-08-06 from the code and the 2026-08 live drive; every claim cites the implementation.

**Why this is not US-1.5.1/1.5.2/1.5.3.** Those are *search* — a query typed with something in mind. This is *browse*: a grid you can walk with no query at all, which is the mode a reader is in when they do not yet know the title. It is also the platform's only surface reachable **without signing in** that shows books, and therefore the front door for anyone evaluating whether The Stacks has anything they care about.

**What the user wants to accomplish:** See what is here. Narrow it to a subject. Sort it. Notice which books are already on their shelves and which are not. Put one on a shelf without leaving the page.

**How they accomplish it:**
1. Click **Catalogue** in the top navigation — the first item for a signed-out visitor (`Main.elm:3851`).
2. A grid of book cards loads: cover (or a letter placeholder), title, author, up to three subject chips.
3. Type in "Search by title or author..." — results refresh 300 ms after the last keystroke.
4. Pick a subject from "All Subjects", or a sort from Title A–Z / Author A–Z / Recently Added.
5. Signed in: use **All / In my collection / Not in my collection** to see only what they have or only what they do not.
6. On a book they do not own, click **"Add to Shelf"**, pick one of the five bookshelves from the inline picker, and the card immediately becomes a badge reading "In your Library".
7. Click any card to open the book's detail page.

**What they see on the page:**
- Title "Book Catalogue", subtitle "Browse and discover books in the collection."
- A search bar with a "Clear" button that appears only once something is typed.
- A filter row: the three collection buttons (authenticated only), the subject dropdown (only when subjects are known), the sort selector.
- The card grid, then pagination — "Page 2 of 7" between Previous / Next, hidden entirely when there is only one page.

**Acceptance Criteria:**
- Works fully signed out, with no ownership information anywhere in the response.
- Age-gated books are hidden from any viewer who is not age-verified — anonymous *or* signed-in-but-unverified.
- Search is debounced and paginated server-side.
- Collection filters and ownership badges are driven by the reader's own placements.
- "Add to Shelf" places directly, and the reading-pile cap is surfaced in the reader's own words.

---

## 2. UI Interaction Flow

### Happy Path
1. Reader navigates to `/catalogue`. `Main.requiresAuth Catalogue = False` — an explicit clause, not the fallthrough (`Main.elm:816-817`) — so no bounce.
2. `Catalogue.init maybeToken` sets `books = Loading` and fires **both** `fetchCatalogue` and — only when a token exists — `Api.getUserPlacements`.
3. `GET /api/catalogue?sort=title&page=1` returns `{books, total, page, per_page}`.
4. `CatalogueReceived (Ok response)` → `books = Success response`, and `availableSubjects` is **merged**, not replaced: the union of subjects seen across every page visited so far, deduplicated and sorted (`mergeSubjects`). So the dropdown grows as the reader pages rather than flickering per page.
5. `UserPlacementsLoaded (Ok placements)` → ownership badges and the collection filter become meaningful.
6. Reader types "eco" → `SearchChanged` bumps `debounceCount`, sets `books = Loading`, and schedules `DebounceExpired newCount` after 300 ms.
7. `DebounceExpired count` fires and **only acts if `count == model.debounceCount`** — the standard counter guard, so keystrokes 1 and 2 land as one request.
8. Reader clicks "Add to Shelf" on an unowned book → `OpenShelfPicker bookId` → the picker replaces the button on that one card.
9. Reader picks "Library" → `PlaceOnShelf "library" bookId` → `POST /api/bookshelves/library/placements`.
10. `PlaceBookCompleted (Ok _)` prepends `{bookId, bookshelfName}` to `userPlacements` — an **optimistic local update, no refetch** — so the card flips to its badge immediately.

### Sad Paths
| Situation | Behaviour |
|-----------|-----------|
| Catalogue fetch fails | `books = Failure err` → "Failed to load the catalogue. Please try again." |
| Catalogue returns 401 | **Stays local.** `Api.getCatalogue` sends no auth header, so a 401 here is not a session-expiry signal and must not be routed (`Catalogue.elm:134-138`) |
| Placements fetch fails, non-401 | `userPlacements = Success []` — degrades to "you own nothing", so badges vanish but the page works |
| Placements fetch returns 401 | `OutMsg SessionExpired` → `Main` bounces |
| Reading pile already full | `422 {error: "reading_pile_full"}` → `Api.PlaceReadingPileFull` → page-level `role="alert"`: "Your reading pile is full — finish or remove a book before adding another." (#281) |
| Place fails for any other reason | `placeBookState = Failure (PlaceHttpError err)` — and **nothing is rendered**. `viewPlaceError` matches only `PlaceReadingPileFull`; every other failure is silent (see §16) |
| Place returns 401 | `OutMsg SessionExpired` |
| Filters exclude everything | "No books found matching your criteria." |
| Signed out | The three collection buttons are not rendered at all (`viewCollectionFilter` returns `text ""` when `not model.isAuthenticated`); every card shows "Add to Shelf", and clicking it opens a picker whose `PlaceOnShelf` is a **no-op** with no token (see §16) |

### Elm State Machine
- **Page module**: `Page.Catalogue`
- **Model fields**: `books : RemoteData Http.Error CatalogueResponse`, `search`, `activeSubject : Maybe String`, `sort : String`, `page : Int`, `availableSubjects : List String`, `debounceCount : Int`, `userPlacements : RemoteData Http.Error (List PlacementSummary)`, `shelfPickerBookId : Maybe String`, `placeBookState : RemoteData Api.PlaceError ()`, `collectionFilter : CollectionFilter`, `isAuthenticated : Bool`
- **`CollectionFilter`**: `AllBooks | InMyCollection | NotInMyCollection` — a union, so "both filters at once" is unrepresentable
- **Msg flow**: `SearchChanged → DebounceExpired → CatalogueReceived` · `OpenShelfPicker → PlaceOnShelf → PlaceBookCompleted`
- **RemoteData states**: `books`: `Loading` → `Success` / `Failure`. `userPlacements`: `Success []` when signed out (not `NotAsked` — the answer is known, not unasked)
- **OutMsg pattern**: `NoOut | SessionExpired`

⚠️ **The collection filter is applied client-side, to the current page only.** `applyCollectionFilter` filters `response.books` after they arrive, while `viewPagination` computes its page count from `response.total` — the server's count of *all* matches, unfiltered. So "Not in my collection" on page 1 of 7 shows the unowned books **of page 1**, over a "Page 1 of 7" label that counts owned ones too. Recorded as a gap (§16).

---

## 3. API Calls

### `GET /api/catalogue`
- **Auth**: Optional
- **Pipeline**: `:api` → `:optional_auth` (`router.ex:131-138`)
- **Controller**: `StacksWeb.CatalogueController.index/2`
- **Query params**: `search`, `subject`, `sort` (`"title"` | `"author"` | `"recent"`, default `"title"`), `page` (default 1), `per_page` (default 24, **max 100**)
- **Response (success)** — HTTP 200:
  ```json
  { "books": [ { "id", "title", "subjects", "visibility_tier",
                 "author": {"id","name"}, "editions": [...],
                 "edition_count": 3, "primary_edition": {...} } ],
    "total": 168, "page": 1, "per_page": 24 }
  ```
  Serialized by `StacksWeb.ProtoJSON.catalogue_book/1` (`proto_json.ex:91-103`).
- **Response (error)**: none by design. Unparseable `page`/`per_page` fall back to defaults via `parse_int/2` rather than 422.

⛔ **No ownership information, ever.** The controller's own moduledoc: *"Returns paginated book metadata without any ownership information. No user IDs, shelf names, placement data, or aggregate ownership counts are ever included in the response."* The badges the reader sees are computed in Elm from **their own** placements, fetched separately. That separation is what makes this endpoint safe to serve anonymously.

### `GET /api/placements/mine`
- **Auth**: Required
- **Pipeline**: `:api` → `:authenticated` (`router.ex:236`)
- **Controller**: `StacksWeb.BookshelfPlacementController.mine/2` → `Shelving.get_user_placements_summary/1`
- **Response**: `{placements: [{book_id, bookshelf_name, title}]}` — the reader's own active placements, scoped by the bookshelf join on `bs.user_id == ^user.id`
- **Purpose here**: the ownership badge and the collection filter. Nothing else on this page needs it.

### `POST /api/bookshelves/:bookshelf_name/placements`
- **Auth**: Required · **Pipeline**: `:api` → `:authenticated`
- **Controller**: `BookshelfPlacementController.create/2` → `Shelving.place_book/3`
- **Request body**: `{ book_id: uuid }`; the bookshelf is in the path and validated against `@valid_bookshelves`
- **Response (success)**: `201 {placement: …}`
- **Response (error)**: `422 {error: "reading_pile_full"}` — a stable code the Elm client matches on (#276) · `422 {errors: {...}}` · `404` for an unknown bookshelf name
- **Story of record for the placement itself**: US-1.2.x / US-1.6.1. This page is one of its callers.

---

## 4. Auth & Middleware Guards

- **Plugs fired**: `SecurityHeaders` → `OptionalAuthPipeline` for the catalogue read; `SecurityHeaders` → `AuthPipeline` for the placements read and the place write
- **Visibility checks**: none on `visibility_tier` beyond the age gate below. The catalogue lists **works**, and a work is platform data — it is not a reader's content, so there is no owner/viewer relationship to resolve. Bookshelf visibility (US-10.2.1) does not apply because no shelf is named here.
- **Age gate**: enforced **in SQL**, in the list query, not by a plug.

  ```
  viewer = case Guardian.Plug.current_resource(conn) do
             nil  -> :unauthenticated
             user -> {:platform_user, user.id, user.age_verified == true}
           end
  ```
  `Books.list_catalogue/1` receives that and applies `maybe_exclude_age_gated/2` (#229).

  ⚠️ **It must stay a SQL-level predicate** so that `total` and pagination counts stay honest (`books.ex:570-572`). Filtering after the query would give an unverified viewer a page count that included books they cannot see — a "Page 1 of 7" over five pages of results, which is a lie the reader can detect.

  Note the normalisation: `user.age_verified == true`, because the column is nullable and `nil` must read as unverified, not as truthy-absent.
- **Ownership checks**: `get_user_placements_summary/1` and `place_book/3` both scope by `user.id` from the token. Nothing on this page accepts a user id as a parameter.

---

## 5. Database Interactions

### Read: the catalogue page
- **Table(s)**: `op.books`, with `preload([:author, :editions])`
- **Query** (`Books.list_catalogue/1`, `books.ex:463-493`):
  1. `maybe_search/2` — `fragment("title_tsv @@ plainto_tsquery('english', ?)", ^search)`
  2. `maybe_filter_subject/2` — `where ^subject in b.subjects`
  3. `maybe_exclude_age_gated/2` — the #229 predicate
  4. `Repo.aggregate(filtered, :count)` for `total`
  5. `apply_sort/2` then `limit`/`offset`
- **Indexes used**: the GIN index on `title_tsv` for search; `subjects` is a `text[]` membership test
- **Schema module**: `Stacks.Books.Book`

⚠️ **Search takes the raw query straight to `plainto_tsquery` via a bound parameter, and that is deliberate.** *"Injection-safety comes from Ecto binding + `plainto_tsquery` treating input as plain text, NOT from stripping characters."* A prior `String.replace(~r/[^\w\s]/)` sanitiser was **lossy** — "O'Brien" → "OBrien", "spider-man" → "spiderman" (#296) — so it broke real searches in the name of a safety it was not providing (`books.ex:549-561`). This path uses `plainto_tsquery` rather than `ilike`, so there are no `%`/`_` wildcards to escape either.

### Read: the reader's placements
- **Table(s)**: `op.bookshelf_placements` INNER JOIN `op.bookshelves` INNER JOIN `op.books`
- **Query**: `where is_nil(p.removed_at)`, scoped by `bs.user_id == ^user_id`, selecting `{book_id, bookshelf_name, title}`
- **Schema module**: `Stacks.Shelving.Placement`

### Write: place a book
Covered by US-1.2.x. From this page's perspective it is one INSERT into `op.bookshelf_placements` inside `Shelving.place_book/3`'s `Ecto.Multi`, which also writes the placement's `book_edition_id` (always the work's **primary** edition) and emits `placement.created`.

---

## 6. Event Flow & Lifecycle

### Events Emitted
Browsing emits nothing — it is a read. The **place** action emits `placement.created` via `Shelving.place_book/3`, which is US-1.2.x's event and carries its own handlers (`PlacementHandler` → RSS regeneration, `DbtRefreshHandler` → `mart_community_read_count`).

⚠️ **No search or browse telemetry is emitted.** There is no `catalogue.searched` event, no query logging, and no per-reader browse trail. For a platform whose de-anonymisation boundary is a stated design constraint (ADR-019 §3), a log of *what each reader searched for* would be a new special-category data store needing its own erasure and export path. Its absence is a decision, not an oversight — but it does mean the usability metrics in §14 are aspirational rather than collected (§16).

### Event Handlers Triggered
None by this story directly.

---

## 7. Background Jobs (Oban)

None enqueued directly. Indirectly, a **place** from this page triggers `RegenerateFeedJob` and a `DbtRefreshJob` for `mart_community_read_count` — see US-1.6.4 §7 for that pair.

---

## 8. External Service Calls

None. Everything on this page is served from Postgres. Cover images are `<img src>` against whatever URL the resolver stored, so the reader's browser fetches them directly — no proxying, and no bandwidth cost to us.

---

## 9. Storage (R2 / Local)

N/A for reads. `bookCoverImageUrl book` yields the primary edition's `cover_image_url`; when absent, `viewBookCover` renders a `catalogue__card-cover-placeholder` containing the first letter of the title. No placeholder image is fetched.

---

## 10. Cache Interactions

**None.** `list_catalogue/1` goes to Postgres on every request; `BookDetailCache` fronts single-book reads, not lists.

That is a deliberate simplicity trade with a visible cost: the debounced search issues a fresh two-query round trip (count + page) per settled keystroke sequence, and the count is over the whole filtered set. It is fine at present catalogue size and is the first thing to revisit if `/catalogue` becomes the hot path (§16).

---

## 11. dbt Model Dependencies

**None.** The catalogue reads `op.books` directly, not the warehouse. `stg_books` / `int_book_detail_view` exist but serve other consumers.

This matters for a reason worth stating: a reader browsing the catalogue sees **live** data — a book added a minute ago is on the next page load. Routing this through a mart would have made the front door of the platform as stale as the last dbt refresh.

---

## 12. Elm Frontend State Machine (Detail)

### Route
- **Route variant**: `Route.Catalogue`
- **URL**: `/catalogue` (`Navigation/Route.elm:91` parser, `:184` path)
- **Public or authenticated**: **public** — `Main.requiresAuth Catalogue = False` as an explicit clause (`Main.elm:816-817`), not by the `_ -> True` fallthrough
- **Nav placement**: first item in the signed-out nav list; for a signed-in reader it sits outside the "Bookshelves" disclosure (`Main.elm:3851`)

### Init
- **`initPage` branch**: `Catalogue.init maybeToken` (`Main.elm:1173-1178`)
- **API calls on init**: `GET /api/catalogue` always; `GET /api/placements/mine` only with a token
- **Initial model state**: `books = Loading`, `sort = "title"`, `page = 1`, `collectionFilter = AllBooks`, `userPlacements = Loading` or `Success []`, `isAuthenticated = maybeToken /= Nothing`

### Update cycle
| Msg | Model change | Cmd |
|-----|--------------|-----|
| `SearchChanged q` | `search = q`, `debounceCount + 1`, `books = Loading` | `Process.sleep 300 → DebounceExpired` |
| `DebounceExpired n` | if stale, nothing; else `page = 1` | `fetchCatalogue` |
| `ClearSearch` | `search = ""`, `page = 1`, `books = Loading` | `fetchCatalogue` (immediate, not debounced) |
| `SubjectSelected s` | `activeSubject` (empty string → `Nothing`), `page = 1` | `fetchCatalogue` |
| `ClearSubject` | `activeSubject = Nothing`, `page = 1` | `fetchCatalogue` |
| `SortChanged s` | `sort = s`, `page = 1` | `fetchCatalogue` |
| `PageChanged n` | `page = n`, `books = Loading` | `fetchCatalogue` |
| `CollectionFilterChanged f` | `collectionFilter = f` | **none** — client-side only |
| `OpenShelfPicker id` / `CloseShelfPicker` | `shelfPickerBookId` | none |
| `PlaceOnShelf shelf id` | `shelfPickerBookId = Nothing`, `placeBookState = Loading` | `Api.placeBook` — **only with a token** |
| `PlaceBookCompleted (Ok _)` | prepend to `userPlacements`, `placeBookState = NotAsked` | none |

### View
- **Key elements**:
  - `NotAsked` → nothing · `Loading` → "Loading catalogue..." · `Failure` → "Failed to load the catalogue. Please try again."
  - `Success` with an empty filtered list → "No books found matching your criteria."
  - Card: `a.catalogue__card-link` wrapping cover + title + author + up to 3 `catalogue__subject-chip`s, then the shelf action
  - Shelf action is a three-way: owned → `span.catalogue__card-badge` with `role="status"` and copy per bookshelf ("In your Library", "In your Antilibrary", "On your Wish List", "In your Reading Pile", "You're rehoming"); picker open → `viewShelfPicker`; otherwise → the "Add to Shelf" button
  - Picker: a `div[role="listbox"][aria-label="Choose a bookshelf"]` of five buttons plus Cancel
  - Pagination: hidden when `totalPages <= 1`; Previous/Next rendered only when they lead somewhere
- **ARIA attributes**: `aria-label ("Add " ++ book.title ++ " to a bookshelf")` on the add button — so a screen-reader user hears *which* book; `role="status"` on the badge; `role="listbox"` + `aria-label` on the picker; `role="alert"` on the reading-pile-full notice. **Gap:** the picker's options are `button`s inside a `listbox`, not `role="option"` elements, so the listbox has no options as far as assistive tech is concerned. The search input has a `placeholder` but no `label` or `aria-label`, and the two `select`s are unlabelled.
- **CSS classes** (all present in `frontend/css/main.css`): `page--catalogue`, `catalogue__title`, `catalogue__subtitle`, `catalogue__controls`, `catalogue__error`, `catalogue__filters`, `catalogue__collection-filter`, `catalogue__filter-btn` (+ `--active`), `catalogue__subject-filter`, `catalogue__subject-select`, `catalogue__grid`, `catalogue__empty`, `catalogue__card`, `catalogue__card-link`, `catalogue__card-info`, `catalogue__card-title`, `catalogue__card-author`, `catalogue__card-subjects`, `catalogue__subject-chip`, `catalogue__card-badge`, `catalogue__card-add`, `catalogue__card-picker`, `catalogue__card-picker-option`, `catalogue__card-cover`, `catalogue__card-cover-placeholder`, `catalogue__pagination`, `catalogue__page-info`; shared `search-bar`, `search-bar__input`, `search-bar__clear`, `sort-selector`, `sort-selector__label`, `sort-selector__select`
- **Test ids**: `catalogue-page`, `catalogue-grid`, `reading-pile-full-msg`

---

## 13. Operational Metrics

| Metric | Source | Type | How Measured | Target / SLA |
|--------|--------|------|-------------|-------------|
| `http.request.count{endpoint="/api/catalogue"}` | Phoenix.Telemetry | Counter | Per request; a debounced search is one request | Volume baseline — this is the front door |
| `http.request.count{endpoint="/api/catalogue", authenticated=false}` | Phoenix.Telemetry | Counter | Anonymous share | The evaluation-traffic signal |
| `db.query.duration{query="list_catalogue.count"}` | Ecto.Telemetry | Histogram (ms) | The `Repo.aggregate(filtered, :count)` | p95 < 80ms. **The one to watch** — an uncached count over a growing table |
| `db.query.duration{query="list_catalogue.page"}` | Ecto.Telemetry | Histogram (ms) | The `limit`/`offset` read with `preload([:author, :editions])` | p95 < 120ms |
| `catalogue.deep_page_rate` | Derived from `page` param | Gauge | Share of requests with `page > 5` | Offset pagination degrades with depth; a rising share is the cue to move to keyset |
| `http.response.status{endpoint="…/placements", status=422, body="reading_pile_full"}` | Phoenix.Telemetry | Counter | Cap rejections from this page | Informational |
| `per_page` distribution | Derived | Histogram | Requested vs the 100 ceiling | Requests at 100 are a client not using the UI |
| Age-gate exclusion effect | SQL | Invariant | `total` for an unverified viewer < `total` for a verified one, given age-gated rows exist | **Must hold.** This is the #229 regression test as a live check |

---

## 14. Performance & Usability Metrics

⚠️ Every row here is **aspirational** — no client-side telemetry is collected (§6). They are stated as what would be measured, and their absence is a gap (§16).

| Metric | Source | Type | How Measured | Target / SLA |
|--------|--------|------|-------------|-------------|
| `catalogue.initial_load` | Elm Performance API | Histogram (ms) | `init` → `CatalogueReceived` | p50 < 400ms, p95 < 1.2s |
| `catalogue.search_settle` | Elm Performance API | Histogram (ms) | Last keystroke → rendered results (300ms debounce + round trip) | p95 < 1s |
| `catalogue.requests_per_search` | Elm event tracking | Gauge | `fetchCatalogue` calls / distinct search intents | **≈ 1.** The debounce-counter guard exists to hold this down; > 1.5 means it is not working |
| `catalogue.place_conversion` | Elm event tracking | Gauge (%) | `PlaceBookCompleted (Ok _)` / `OpenShelfPicker` | How often opening the picker leads to a shelved book |
| `catalogue.picker_abandon_rate` | Elm event tracking | Gauge (%) | `CloseShelfPicker` / `OpenShelfPicker` | Informational |
| `catalogue.filter_usage` | Elm event tracking | Histogram | Share of sessions using subject / sort / collection filters | Tells us which of the three earn their place in the control row |
| `catalogue.empty_result_rate` | Elm event tracking | Gauge (%) | "No books found" renders / searches | High means the full-text search is too strict for how readers type |

---

## 15. Cost Tracking

| Cost Service | Unit | Volume Driver | Notes |
|-------------|------|--------------|-------|
| Fly.io compute (core) | CPU-ms per request | Page views + settled searches | Serialization of 24 books with `author` + `editions` preloaded is the bulk of it. |
| Neon DB | Compute Units per request | **2 queries per request** (count + page), no cache | The uncached `COUNT(*)` over the filtered set is the dominant and least bounded cost. Deep offsets compound it. |
| Neon DB | Write IOPS | Only on "Add to Shelf" | Browsing is pure read. |
| Network egress | Bytes | 24 books × (metadata + editions) per page | JSON only. **Cover images are not proxied** — the browser fetches them from the resolver-supplied URL, so image bandwidth is not ours (§8). |
| Cover-image hosts | Requests | 24 per page view | A courtesy cost we impose on Open Library / Google Books covers rather than pay. Worth noting for the same reason §15 of US-2.6.1 notes the bookshop fan-out: the cost lands on someone else. |

---

## 16. Known Gaps

Every item below was found by reading the module against the live drive, and none is recorded elsewhere.

1. **The collection filter fights pagination.** `applyCollectionFilter` filters the current page in Elm; `viewPagination` counts pages from the server's unfiltered `total`. So "Not in my collection" can render an empty grid under "Page 3 of 7", and paging through 7 pages is the only way to see all unowned books. The honest fix is a server-side `exclude_owned` parameter — which would also mean the endpoint learns about ownership, contradicting §3's guarantee. Genuinely a design decision, not a bug fix, and it needs one.
2. **A signed-out reader is offered "Add to Shelf" and gets silence.** `viewShelfAction` renders the button whenever `maybePlacement == Nothing`, with no `isAuthenticated` check — and `PlaceOnShelf` falls through to `( model, Cmd.none, NoOut )` when `maybeToken == Nothing`. So the picker opens, the reader picks a shelf, and nothing whatever happens. Compare `viewCollectionFilter`, which *does* check `isAuthenticated`. Either the button should prompt sign-in or it should not be drawn.
3. **Every place failure except a full reading pile is invisible.** `viewPlaceError` matches only `Failure Api.PlaceReadingPileFull`; a 422 changeset error or a 500 sets `placeBookState = Failure (PlaceHttpError err)` and renders nothing, leaving the card unchanged with no explanation.
4. **`availableSubjects` only ever grows.** `mergeSubjects` unions each page's subjects into the list and nothing clears it, so a subject discovered on page 4 stays in the dropdown after a search that excludes it — offering a filter that will return "No books found".
5. **No accessible labels** on the search input or either `select`, and the shelf picker's `role="listbox"` contains `button`s rather than `role="option"` elements (§12).
6. **No client telemetry at all**, so §14 measures nothing today.
7. **Offset pagination with an uncached count** (§10, §15). Fine now; the first thing to change under load.

**Checked and *not* a gap**, recorded so the next reader does not re-investigate: an arbitrary `sort` value is safe — `Books.apply_sort/2` has clauses for `"author"` and `"recent"` and a catch-all that orders by title (`books.ex:592-604`), so an unknown value degrades to the default rather than reaching the query builder. Likewise `parse_int/2` makes `page`/`per_page` unparseable-safe, and `per_page` is clamped to 1..100.
