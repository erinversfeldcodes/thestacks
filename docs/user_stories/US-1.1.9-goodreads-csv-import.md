# US-1.1.9 — Import a Goodreads Library Export

## 1. User Story

> **As a** reader arriving from Goodreads, **I want to** import my library export **so that** my shelves are populated on day one instead of empty — and **I want to be told exactly which books could not be brought across**, rather than quietly losing them.

**What they want to accomplish:** Move years of shelving history into The Stacks in one pass, and understand precisely what arrived, what was already here, and what the platform refused.

**Why it is a CSV and not an API:** Goodreads shut its public API in December 2020 and issues no new keys. There is no live sync to build, and pretending otherwise would be dishonest. The user exports `goodreads_library_export.csv` from Goodreads themselves and hands it to us. One direction, one time, no ongoing sync.

**How they accomplish it:**
1. The reader opens `/import` — from Settings, from the empty-shelf state (US-1.6.5), or from the onboarding flow (US-14.1.2).
2. The page explains where to get the file: "Goodreads → My Books → Import and Export → Export Library. You'll get an email with a CSV."
3. They drop the CSV onto the drop zone, or click to choose it.
4. The file is parsed and the reader sees a preview before anything is written: "1,204 rows. 1,180 with an ISBN, 24 without."
5. They confirm. A progress bar advances by verified batch.
6. When it finishes, the **import report** shows four counts and, beneath them, every row that did not make it — each with what to do about it.

**⛔ The ISBN hard gate applies without exception.** An import is just another capture source. Every row is verified against Open Library or Google Books before a book enters the system — the same `Stacks.Books.ISBNResolver` path a photographed cover takes. A Goodreads row is not evidence that a book exists; it is a claim, and Goodreads is full of user-created phantom editions. Rows that cannot be verified are **surfaced to the reader, never silently dropped and never written as unverified books**.

**What they see on the page (after a completed import):**
- A parchment-toned report card headed "1,204 rows read from Goodreads."
- Four figures in a row, each a link to its own filtered list:
  - **1,096 shelved** — "on your shelves now"
  - **62 already here** — "you'd added these already"
  - **41 couldn't be verified** — "no ISBN we could confirm"
  - **5 unreadable rows** — "the file was damaged here"
- Beneath the figures, a shelf-by-shelf breakdown: "Library 812 · Antilibrary 198 · Wishlist 74 · Reading pile 12".
- Then the honest part — an expanded list of the 41 unverifiable rows, each showing the title and author exactly as Goodreads wrote them, the reason ("no ISBN in the export, and no catalogue match for this title and author"), and two actions: **Enter the ISBN** (opens manual entry, US-1.1.5, prefilled with the title and author) and **Leave it out**.
- A closing line in the small caption voice: "Your ratings, review text and read dates came across with each book. Goodreads' own shelf names did not — The Stacks has five shelves, and we mapped yours onto them."
- Nothing about the report is collapsed by default. A report that hides its failures behind a chevron is a report designed not to be read.

**Acceptance criteria:**
- No book, edition, or placement row is created for a row whose ISBN could not be verified against Open Library or Google Books.
- Every row's outcome is recorded and shown: shelved, already-present, unverified, or unreadable. The four counts sum to the row count.
- Partial success is the normal case, not an error state: an import with 41 failures still reports HTTP 200 and still shelves the 1,096.
- Dedup is against the reader's existing placements by ISBN-13, and within the CSV itself.
- Goodreads' `Exclusive Shelf` and `Owned Copies` together decide the destination bookshelf; `My Rating`, `My Review`, `Private Notes`, `Date Read`, `Date Added`, `Read Count` and `Binding` are carried across.
- An import of 2,000 rows enqueues **one** feed regeneration per affected bookshelf, not one per placement.
- Re-running the same file is safe: every row already imported is reported as already-present.
- The raw row data is purged after 30 days; the aggregate counts remain.

---

## 2. UI Interaction Flow

### Happy Path
1. Reader navigates to `/import` (`Route.Import`).
2. `Page.Import.init` fetches `GET /api/imports` for any prior import, so a returning reader sees their last report rather than a blank slate.
3. Reader clicks the drop zone → `Select.file [ "text/csv", ".csv" ] GotFile` (the same `File.Select` pattern `Page.Upload` uses).
4. `GotFile file` → client-side checks: extension, size <= 5 MB. On pass, `uploadState = Ready file`.
5. Reader clicks "Read the file" → `Api.createImport file` posts multipart to `POST /api/imports/goodreads`.
6. HTTP 202 `{ import_id, row_count, isbn_row_count, status: "enqueued" }` → `importState = Running`, poll begins.
7. `CheckStatus` fires every 2s → `GET /api/imports/:id`. The response carries running counts, so the progress bar is real progress and not an animation.
8. `status: "complete"` → `Api.fetchImportRows id { outcome: "unverified" }` and `{ outcome: "unreadable" }` → the report renders.

### Sad Paths
- **Not a CSV**: rejected client-side before any upload. "That doesn't look like a CSV. Goodreads sends you a file ending in `.csv`."
- **Over 5 MB**: rejected client-side. "That file is larger than we can read in one go (5 MB). If your library is enormous, split the CSV and import it in two passes."
- **Headers unrecognised**: HTTP 422 `{ "error": "unrecognised_format", "found_headers": [...] }`. The page shows: "This doesn't look like a Goodreads export. We look for a `Title`, `Author` and `ISBN13` column. If Goodreads has changed their format, please tell us." — with a link to the feedback channel (US-15.5.1).
- **Empty file / headers only**: HTTP 422 `{ "error": "no_rows" }`. "That file has a header row and nothing else."
- **A row with no ISBN and no catalogue match**: `outcome: "unverified"`. Reported, recoverable via manual entry. **No book created.**
- **A row whose ISBN resolves to a different book than the title claims**: the resolved book wins and the row is marked `outcome: "shelved"` with `reason: "resolved_title_differs"`, shown in the report as an italic "Goodreads called this *X*; the catalogue calls it *Y*." The catalogue is the authority — that is what the hard gate means — but the reader is told.
- **Malformed row** (wrong column count, unparseable date): `outcome: "unreadable"` with the row number, so the reader can find it in their own file.
- **Resolver fuse open** (`:open_library_fuse` / `:google_books_fuse` blown): the batch job returns `{:error, :circuit_open}` and Oban retries with backoff. The import stays `running`; the page says "Waiting on the book catalogues — this happens; we'll keep going." It does **not** mark rows unverified, because a blown fuse is not evidence a book does not exist.
- **Second import started while one is running**: HTTP 409 `{ "error": "import_in_progress" }`. "One import at a time — this one is still working."
- **Reader closes the tab mid-import**: the job continues. Returning to `/import` shows the running import and resumes polling.

### Elm State Machine
- **Page module**: `Page.Import`
- **Model fields involved**: `file`, `uploadState`, `importState`, `importId`, `counts`, `unverifiedRows`, `unreadableRows`, `pollCount`
- **Msg flow**: `ClickedChooseFile → GotFile → ClickedConfirm → GotImportCreated → CheckStatus (loop) → GotImportStatus → GotImportRows`
- **RemoteData states**: `NotAsked → Loading → Success Report / Failure Http.Error`
- **OutMsg pattern**: `ImportCompleted { shelved : Int }` propagates to `Main` so the shelf caches are invalidated and the nav badge refreshes — otherwise the reader lands on a bookcase rendered from a pre-import fetch and concludes the import did nothing.

---

## 3. API Calls

### `POST /api/imports/goodreads`
- **Auth**: Required
- **Pipeline**: `:api`, `:authenticated`, `:rate_limit_upload`
- **Controller**: `StacksWeb.ImportController.create/2`
- **Request**: `multipart/form-data` with a single `file` part. Max 5 MB (enforced by the Plug.Parsers length option on this route and re-checked in the controller).
- **Response (success)**: `{ import_id: uuid, row_count: int, isbn_row_count: int, status: "enqueued" }` — HTTP 202
- **Response (error)**: `{ error: "unrecognised_format", found_headers: [...] }` 422 · `{ error: "no_rows" }` 422 · `{ error: "file_too_large" }` 413 · `{ error: "import_in_progress" }` 409
- **Note**: the controller parses and persists rows synchronously (a 20k-row CSV parses in well under a second) and enqueues verification. Parsing in the request means format errors are answered immediately instead of arriving minutes later as a failed job.

### `GET /api/imports/:id`
- **Auth**: Required, owner of the import
- **Pipeline**: `:api`, `:authenticated`
- **Controller**: `StacksWeb.ImportController.show/2`
- **Response**: `{ id, source: "goodreads", filename, status: "enqueued"|"running"|"complete"|"failed", row_count, processed_count, shelved_count, duplicate_count, unverified_count, unreadable_count, by_bookshelf: { library: int, ... }, started_at, finished_at }` — HTTP 200
- **Response (error)**: `{ error: "not_found" }` 404 for another reader's import — 404 rather than 403, so an import id cannot be used to confirm that someone else has one.

### `GET /api/imports/:id/rows`
- **Auth**: Required, owner of the import
- **Query params**: `outcome` (`shelved`|`duplicate`|`unverified`|`unreadable`), `limit` (default 50, max 200), `offset`
- **Response**: `{ rows: [{ row_number, raw_title, raw_author, raw_isbn, goodreads_shelf, outcome, reason, book_id }], total }` — HTTP 200

### `GET /api/imports`
- **Response**: `{ imports: [ …summary… ] }` — the reader's own imports, newest first.

### Reused endpoints
- `POST /api/books/confirm` is **not** used. The import writes through `Stacks.Shelving.place_book/3` in the worker, so there is no per-row round trip to the browser.
- The manual-entry recovery path uses the existing `POST /api/books/isbn` + `POST /api/bookshelves/:bookshelf_name/placements` (US-1.1.5).

---

## 4. Auth & Middleware Guards

- **Plugs fired**: `SecurityHeaders` → `AuthPipeline` → `RequireConfirmedEmail` → `RateLimiter(bucket: :upload)`. The `:upload` bucket keys on user id (120/60s), which is the right shape: an import is a per-reader action, not a per-IP one.
- **Visibility checks**: N/A on write. Imported placements inherit the destination bookshelf's visibility exactly as `place_book/3` already does — an import must never be a way to create content at a wider audience than the reader's own shelf setting.
- **Age gate**: an imported book that resolves to an age-gated work is flagged by the same path as US-1.1.4; the import does not bypass `Stacks.Books.maybe_exclude_age_gated/2`.
- **Ownership checks**: `ImportController` scopes every read by `current_resource.id`. The import id is a UUID but it is not the authorisation.

---

## 5. Database Interactions

### Write: New table `op.library_imports`
- **Proto source**: add `LibraryImport` to a new `proto/stacks/common/v1/import.proto`, register in `proto/persisted.exs`, run `mix proto.sync`. `git add` the generated migration immediately.
- **Columns**: `id` · `user_id` (uuid FK `op.users`, ON DELETE CASCADE) · `source` (text, NOT NULL, default `"goodreads"`) · `filename` (text) · `status` (text, NOT NULL, default `"enqueued"`) · `row_count` · `processed_count` · `shelved_count` · `duplicate_count` · `unverified_count` · `unreadable_count` (all int, NOT NULL, default 0) · `started_at` · `finished_at` · timestamps
- **Indexes**: `library_imports_user_id_created_at_index` (`user_id`, `created_at DESC`) — serves the list and the in-progress check.
- **Changeset validations**: `source` inclusion in `~w(goodreads)`, `status` inclusion in `~w(enqueued running complete failed)`.

### Write: New table `op.library_import_rows`
- **Columns**: `id` · `import_id` (uuid FK `op.library_imports`, ON DELETE CASCADE) · `row_number` (int, NOT NULL) · `raw_title` · `raw_author` · `raw_isbn` · `raw_isbn13` · `goodreads_shelf` · `raw_rating` (int) · `raw_review` (text) · `raw_notes` (text) · `raw_binding` · `raw_date_read` · `raw_date_added` · `raw_read_count` (int) · `raw_owned_copies` (int) · `outcome` (text, nullable until processed) · `reason` (text, nullable) · `book_id` (uuid FK `op.books`, ON DELETE SET NULL) · `placement_id` (uuid FK `op.bookshelf_placements`, ON DELETE SET NULL) · `created_at`
- **Indexes**: `library_import_rows_import_id_row_number_index` (unique on `import_id, row_number`) — this is what makes an Oban retry idempotent; `library_import_rows_import_id_outcome_index` — serves the filtered report.
- ⚠️ **This table holds the reader's own writing.** `raw_review` and `raw_notes` are free-text PII, and `raw_title`/`raw_author` describe their reading. See the GDPR subsection.

### Write: Additive field on `op.bookshelf_placements`
- Add `source` (text, NOT NULL, default `"manual"`) to `proto/stacks/common/v1/placement.proto` and run `mix proto.sync`. Values: `manual`, `upload`, `goodreads_import`. Provenance is a real product fact — the reader should be able to tell, in three years, which shelf entries came from Goodreads — and it is the only way the report's counts can be reconciled after the row-level data is purged.

### Read: Dedup against existing placements
- **Table(s)**: `op.bookshelf_placements` JOIN `op.book_editions`
- **Query**: for the resolved ISBN-13, does the reader already have an active placement (`removed_at IS NULL`) for that `book_id` on **any** of their bookshelves? A book lives on exactly one bookshelf in this model — `move_book/3` exists precisely because moving rather than duplicating is the rule — so a cross-bookshelf match is a duplicate, not a second copy.
- **Outcome**: `duplicate`, with `reason: "already on your Library shelf"`. The import does **not** move an existing placement to where Goodreads thinks it belongs. The reader's current shelving is more recent and more deliberate than their Goodreads history.
- **Constraint interaction**: `bookshelf_placements_book_active_idx` is `UNIQUE (book_id, bookshelf_id) WHERE removed_at IS NULL`. Treat a unique-violation on insert as `duplicate` rather than an error — the pre-check and the constraint must agree, and the constraint is the one that cannot race.

### Write: Book, edition, placement per verified row
- Reuses the existing paths — `Stacks.Books.upsert_from_resolution/1` (or whatever `IdentifyBookJob` already calls to persist a resolved ISBN) and `Stacks.Shelving.place_book/3`, then a follow-up `update_placement/2` for the carried fields. **Do not write a second insert path for imports**: two ways to create a placement is two places for the ISBN gate to be forgotten.

### Field mapping (Goodreads → The Stacks)

| Goodreads column | Destination | Notes |
|---|---|---|
| `ISBN13`, `ISBN` | `ISBNResolver.resolve/1` input | Goodreads wraps these as `="0439023483"` (an Excel formula escape). **Strip `="…"` before use** — the naive parse yields a 13-character string that is not an ISBN and the whole import fails the gate. |
| `Title`, `Author` | `ISBNResolver.search_by_title/3` input | Only for rows with no usable ISBN. |
| `Exclusive Shelf` + `Owned Copies` | destination bookshelf | `read` → **library** · `currently-reading` → **reading_pile** · `to-read` **and** `Owned Copies >= 1` → **antilibrary** · `to-read` **and** `Owned Copies = 0` → **wishlist**. Goodreads' own owned-copies flag is what distinguishes the antilibrary from the wishlist — no need to ask the reader. |
| `Bookshelves` (user shelf names) | not imported | The Stacks has five bookshelves by design. Say so in the report rather than inventing shelves. |
| `My Rating` | `placement.personal_rating` | 1–5 maps straight across; `0` means unrated in Goodreads → `nil` (the changeset validates 1–5). |
| `My Review`, `Private Notes` | `placement.notes` | Concatenated with a blank line when both are present. The reader's own writing — dropping it would be data loss. Erasure reaches it via the placement delete. |
| `Date Read` | `placement.finished_at`, `reading_status = "completed"` | Absent on a `read` row → `reading_status` still `completed`, `finished_at` nil. |
| `Date Added` | `placement.placed_at` | Preserves "on my shelf since 2019" rather than resetting everything to import day. |
| `Read Count` > 1 | `op.bookshelf_placement_history` via `Shelving.reread_book/1`, `n - 1` times | Goodreads gives a count and no dates, so the history rows carry the import date with `reason: "goodreads_read_count"`. |
| `Binding` | `placement.formats` | `Paperback`/`Hardcover`/`Kindle Edition`/`Audiobook`/`ebook` → the platform's format vocabulary; anything unrecognised is left off rather than guessed. |
| `Average Rating`, `Publisher`, `Number of Pages`, `Year Published`, `Spoiler` | not imported | Catalogue metadata belongs to the catalogue, not to the reader's row. The resolver supplies it. |

### GDPR: erasure + export reachability
Two new tables holding personal data, one of them free text. Run the `gdpr-review` skill on the diff.

- **Erasure** (`GDPR.Deletion.delete_user_data/2`) gains one step, ordered **before** `:delete_bookshelves` (so the `placement_id` FK is still resolvable for the operator summary):
  - `:delete_library_imports` — `delete_all` on `op.library_imports where user_id == ^user_id`. `library_import_rows` follows by `ON DELETE CASCADE`. The cascade is sufficient here **because the parent is keyed directly on `user_id`**, unlike `op.feed_cache`, whose only user path is through `bookshelf_id` and therefore needed an explicit step. Still delete explicitly rather than relying on the `op.users` cascade: it keeps the erasure independent of cascade timing and gives the break-glass summary a count.
  - `placement.notes` (which now carries the imported review text) is already erased by the existing `:delete_placements` step — verified, no new step needed.
- **Export** (`GDPR.Export.export_user_data/2`) gains a `library_imports` key: `{ source, filename, status, row_count, shelved_count, duplicate_count, unverified_count, unreadable_count, started_at, finished_at }` per import. Row-level data is **not** exported — the reader already holds the original CSV, which is the portable artefact; re-emitting our parse of it adds no portability and doubles the copy of their review text.
- **Retention**: `op.library_import_rows` is diagnostic. Once the reader has read their report there is no reason to keep their raw review text in a second place. `LibraryImportRowRetentionJob` purges rows for imports finished more than 30 days ago, mirroring the 30-day image retention window, leaving the aggregate counts on `op.library_imports`. The report page says so: "The row-by-row detail is kept for 30 days."
- **Not written to `event_log`**: no title, author, review text, note, or filename. See §6.

---

## 6. Event Flow & Lifecycle

### Events Emitted

#### `library_import.started`
- **Aggregate**: `library_import` / import_id
- **Payload**: `%{source: "goodreads", row_count: integer}`
- **Emitted by**: `Stacks.Imports.create_import/2`
- **Emission method**: `Events.emit_safe/1`

#### `library_import.completed`
- **Aggregate**: `library_import` / import_id
- **Payload**: `%{source: "goodreads", row_count: n, shelved: n, duplicate: n, unverified: n, unreadable: n}`
- **Emitted by**: `GoodreadsImportJob` on the final batch

⚠️ **Counts only.** No filename (which is often `goodreads_library_export_<name>.csv`), no titles, no author names, no review text. `event_log` is immutable except for GDPR redaction, so anything personal written there is a liability for the life of the platform. Add the assertion to `Stacks.Events.PayloadContract`.

#### `placement.created` — per shelved row, and this is the hazard
Each import row that shelves a book emits `placement.created` through the normal `place_book/3` path, which `Stacks.Feeds.Handlers.PlacementHandler` turns into a `RegenerateFeedJob`. A 2,000-row import would enqueue 2,000 regenerations of at most four feeds, each superseding the last.

**Resolution**: `place_book/3` gains an `emit_feed_regeneration: false` option that the import passes, and `GoodreadsImportJob`'s final batch enqueues **one** `RegenerateFeedJob` per bookshelf it touched. The `placement.created` events are still emitted — they are the reader's history and the warehouse's source — only the derived-feed work is coalesced. Suppressing the events themselves would put a hole in the event log.

### Event Handlers Triggered
- **Handler**: `Stacks.Feeds.Handlers.PlacementHandler` — no-ops for import-sourced placements (see above), then runs once per bookshelf at the end.
- **Handler**: `Stacks.Warehouse.DbtRefreshHandler` on `library_import.completed` — one refresh at the end, not per row.

---

## 7. Background Jobs (Oban)

### `Stacks.Workers.GoodreadsImportJob`
- **Queue**: `:default` (not `:vision` — no GPU is involved; the work is upstream catalogue I/O)
- **Args**: `%{"import_id" => uuid, "offset" => integer}`
- **Batch size**: 25 rows per job. On completion the job enqueues itself with `offset + 25` until the rows are exhausted, then finalises.
- **Max attempts**: 5
- **Uniqueness**: `[period: :infinity, keys: [:import_id, :offset], states: [:available, :scheduled, :executing, :retryable]]` — a retry must not double-process a batch.
- **What it does, per row**:
  1. Skip if `outcome` is already set (this is what makes a retry idempotent, together with the unique `(import_id, row_number)` index).
  2. Normalise the ISBN: strip the `="…"` wrapper, strip hyphens, validate the checksum. An ISBN that fails its own checksum is treated as absent, not as a lookup.
  3. `ISBNResolver.resolve/1` on ISBN-13 then ISBN-10; on absence or `:not_found`, `ISBNResolver.search_by_title/3` with the title and author.
  4. `{:error, :circuit_open | :timeout | :transport_error}` → return `{:error, reason}` so Oban retries the **batch**. Do not mark the row unverified: a transient upstream failure is not evidence the book does not exist. This mirrors the `ISBNResolverCache`'s refusal to memoise transient errors.
  5. `{:error, :not_found}` from both providers → `outcome: "unverified"`, `reason` recorded. **No book row written.**
  6. `{:ok, resolution}` → dedup check → `duplicate`, or upsert book/edition, `place_book/3`, carry the mapped fields, `outcome: "shelved"`.
  7. Update `processed_count` and the outcome counters on `op.library_imports` after each batch, so the poll shows real progress.
- **Batch pacing**: 25 rows against a raced pair of catalogue APIs, each with an 8s race timeout, is a worst case of ~30s per job — comfortably inside Oban's defaults and short enough that a retry is cheap. The `ISBNResolverCache` (ETS L1 + Postgres L2) absorbs the repeats a real Goodreads library is full of.
- **On finalise**: set `status: "complete"`, `finished_at`, emit `library_import.completed`, enqueue one `RegenerateFeedJob` per touched bookshelf.
- **On exhausting attempts**: set `status: "failed"`. The rows already processed keep their outcomes and their books stay shelved — a failed import is partial, not rolled back, because unwinding 800 successful placements to punish a network blip would be the worse outcome. The report says which row it stopped at and offers "Carry on from row 812".

### `Stacks.Workers.LibraryImportRowRetentionJob` (new)
- **Queue**: `:default`, daily
- **What it does**: deletes `op.library_import_rows` for imports whose `finished_at` is more than 30 days old. Aggregate counts remain.

---

## 8. External Service Calls

### Open Library + Google Books (per row)
- **Client module**: `Stacks.Books.ISBNResolver.resolve/1` and `search_by_title/3`
- **Strategy**: unchanged from US-1.1.1/US-1.1.2 — the two providers are raced with `Task.async`, first `{:ok, _}` wins, 8s hard race timeout, each behind a Fuse circuit breaker (`:open_library_fuse`, `:google_books_fuse`).
- **Volume**: 1–2 calls per uncached row. A 1,200-row library is the largest single burst of resolver traffic the platform will see — hence the batch pacing and the cache.
- **Fallback**: a blown fuse retries the batch rather than failing rows (see §7).
- **Mock in test**: the existing resolver mock. Fixture a real Goodreads export — including the `="…"` ISBN wrapper, a `to-read` row with `Owned Copies 1`, a row with no ISBN at all, and a row with a Goodreads-only phantom edition — as `test/support/fixtures/goodreads_library_export.csv`.

No vision service is involved. An import costs no GPU time, which is the quiet reason it is the cheapest way to fill a shelf.

---

## 9. Storage (R2 / Local)

The CSV is **not** stored. It is parsed in the request and discarded; only the parsed rows persist, and those expire after 30 days. Keeping the original file would mean holding a second, un-minimised copy of the reader's review text and reading history in object storage, with its own erasure path to maintain, for no functional gain.

---

## 10. Cache Interactions

- **Cache**: `Stacks.Books.ISBNResolverCache` (ETS L1 + Postgres L2). Positive resolutions memoised 24h, `:not_found` 1h, transient errors never. This is what keeps a 1,200-row import from being 1,200 cold upstream calls — a real Goodreads library repeats editions heavily, and the second reader to import a popular library pays almost nothing.
- **Cache**: `BookDetailCache` — untouched on import; each new book's detail is computed on first view.
- **Cache**: `RateLimiter`, `:upload` bucket, keyed on user id.
- **Invalidation**: the `ImportCompleted` OutMsg makes `Main` refetch the shelves. Without it the reader lands on a stale bookcase and concludes the import failed — the "structurally valid but false payload" failure mode.

---

## 11. dbt Model Dependencies

- **Model**: `stg_library_imports` — proto-generated.
- **Model**: `stg_library_import_rows` — ⚠️ **do not generate one.** Set `dbt_path: nil` in `proto/persisted.exs` for this table. It holds raw review text and private notes; the `wh` schema has no erasure path, so copying free-text PII there would put it permanently beyond `delete_user_data/2`'s reach. Assert the absence in the dbt sources test so a later regeneration cannot quietly add it.
- **Model**: `int_placement_provenance` — new intermediate model grouping `stg_bookshelf_placements` by the new `source` column. Answers "how many shelves were filled by import vs by camera", which is the number that says whether the import was worth building.
- **Trigger**: `library_import.completed` via `DbtRefreshHandler`.
- **Consumer**: admin platform stats; the onboarding-funnel figures.

---

## 12. Elm Frontend State Machine (Detail)

### Route
- **Route variant**: `Route.Import` — `/import`
- **Public or authenticated**: authenticated

### Init
- **`initPage` branch**: `Route.Import` → `PageImport Import.init`
- **API calls on init**: `Api.fetchImports` — surfaces a running or previous import
- **Initial model state**: `file = Nothing`, `importState = NotAsked`, `pollCount = 0`

### Model
```
{ file : Maybe File
, fileError : Maybe String
, importId : Maybe String
, importState : RemoteData Http.Error ImportReport
, unverifiedRows : RemoteData Http.Error (List ImportRow)
, unreadableRows : RemoteData Http.Error (List ImportRow)
, pollCount : Int
, ownedToReadDestination : BookshelfName   -- surfaced only when the CSV has to-read rows with no Owned Copies column
}
```

### Update cycle

| Msg | Model change | Cmd | OutMsg |
|-----|-------------|-----|--------|
| `ClickedChooseFile` | — | `Select.file [ "text/csv" ] GotFile` | `NoOut` |
| `GotFile file` | `file = Just file` or `fileError` | None | `NoOut` |
| `ClickedConfirm` | `importState = Loading` | `Api.createImport file` | `NoOut` |
| `GotImportCreated (Ok r)` | `importId = Just r.id` | `Process.sleep 2000` piped into `Task.perform (\_ -> CheckStatus)` | `NoOut` |
| `CheckStatus` | `pollCount + 1` | `Api.fetchImport id` | `NoOut` |
| `GotImportStatus (Ok r)` when running | `importState = Success r` | schedule next poll | `NoOut` |
| `GotImportStatus (Ok r)` when complete | `importState = Success r` | `Api.fetchImportRows` ×2 | `ImportCompleted { shelved = r.shelvedCount }` |
| `ClickedEnterIsbn row` | — | `Nav.pushUrl (Route.toPath (Route.Upload) ++ "?manual=1&title=…&author=…")` | `NoOut` |
| `ClickedLeaveOut row` | removes the row from the list | `Api.dismissImportRow id row` | `NoOut` |

### Drop zone
Drag-and-drop uses `Html.Events.preventDefaultOn "drop" (Decode.map (\f -> ( GotFile f, True )) fileDecoder)` — the same decoder shape `Page.Upload` uses at line 1244. ⚠️ Per the drag-and-drop lesson: every `preventDefaultOn` handler for `dragover`/`dragenter` must dispatch an **inert** message, and a synthetic mouse drag in a test proves nothing. Drive the drop zone with a real file drop in Playwright (`setInputFiles` on the hidden input **and** a `dataTransfer` drop) before calling it built.

### View
- **Key elements**: the drop zone (`import__dropzone`, `import__dropzone--active` while dragging), the pre-flight preview, the progress bar (`import__progress`, `role="progressbar"` with `aria-valuenow`/`aria-valuemax`), the report card (`import__report`), the four count tiles (`import__count`), and the unverified list (`import__row`, `import__row-reason`, `import__row-actions`).
- **ARIA**: the progress region is `aria-live="polite"` and announces at each batch, not each row. The report heading takes focus on completion so a screen-reader user is not left listening to a progress bar that has stopped.
- **CSS classes**: `page--import`, `import__dropzone`, `import__preview`, `import__progress`, `import__report`, `import__count`, `import__count-label`, `import__breakdown`, `import__row`, `import__row-reason`, `import__row-actions`. ⚠️ All of these need rules in `frontend/css/main.css` in the same change; re-run the class-literal set difference and confirm zero new orphans (`scripts/check-css.sh`).
- **Test ids**: `import-dropzone`, `import-file-input`, `import-confirm`, `import-progress`, `import-report`, `import-count-shelved`, `import-count-unverified`, `import-unverified-list`, `import-row-enter-isbn`.

---

## 13. Operational Metrics

- **Import outcome counter**: `[:stacks, :import, :row]` with `%{outcome: :shelved | :duplicate | :unverified | :unreadable}` — bounded labels, so `stacks_import_row_count_total{outcome=…}` is alertable.
- **ISBN verification rate on import**: `shelved / (shelved + unverified)`. The single number that says whether the hard gate is a gate or a wall. Below ~85% and the title-search fallback needs work, not the gate.
- **Resolver call volume during import**: `ISBNResolver` calls per import and the `ISBNResolverCache` hit rate. A low hit rate on a large import means the negative-TTL window is too short.
- **Fuse melts during import**: `:open_library_fuse` / `:google_books_fuse` state transitions correlated with import windows. An import is the most likely thing to blow a catalogue fuse, and blowing one degrades the *upload* path for everyone — worth an alert.
- **Oban metrics**: `GoodreadsImportJob` enqueued/completed/failed/retried per queue `:default`, plus batch duration histogram.
- **Feed regeneration coalescing**: `RegenerateFeedJob` count per `library_import.completed`. Should be `<= 4`. If it tracks the shelved count, the `emit_feed_regeneration: false` option is not wired — exactly the "built but not wired" defect class, and a per-row count is the signal.
- **Imports in flight**: gauge of `op.library_imports where status = 'running'`. A stuck import shows here before the reader complains.

---

## 14. Performance & Usability Metrics

- **Parse latency**: time to parse and persist rows in `POST /api/imports/goodreads`. Target p95 < 1s for 2,000 rows; NimbleCSV on a 5 MB file is not the bottleneck, the inserts are — use `Repo.insert_all` in chunks.
- **End-to-end import duration**: `finished_at - started_at` by row count. Target: 1,200 rows in under 10 minutes on a warm cache, under 25 minutes cold.
- **Time to first visible progress**: from confirm click to the first non-zero `processed_count`. Target < 10s — beyond that the reader believes nothing is happening.
- **Report comprehension**: share of readers with unverified rows who take a recovery action (manual ISBN or explicit dismiss) rather than leaving. Target > 40%. If it is near zero the report is being read as a receipt rather than a to-do list.
- **Abandonment during import**: share who navigate away before completion and never return to `/import`. The job finishes regardless, so this measures whether the progress UI holds attention, not whether the import worked.
- **Shelf-mapping correction rate**: share of imported placements a reader moves within 7 days of import. High means the `Exclusive Shelf` + `Owned Copies` mapping is wrong and the reader is doing our work.
- **First-run effect**: retention at 7 days for readers who imported vs readers who started from empty shelves. This is the whole justification for the feature.

---

## 15. Cost Tracking

### Open Library / Google Books
- **Trigger**: 1–2 calls per uncached row.
- **Unit cost**: Open Library is free. Google Books' free tier is 1,000 requests/day — ⚠️ **a single 1,200-row import can exhaust the daily Google Books quota**, which would then degrade the upload path. Mitigations, in order: the resolver cache; the race means Google Books is only *consulted*, not always the winner; and if imports become common, an import-specific throttle or an API key with a raised quota. Note this explicitly in the runbook.
- **Tracked by**: no cost tracking (free APIs), but quota consumption is worth a metric.

### Modal vision GPU
- **Cost: zero.** No classification, no extraction. An import shelves a book for none of the ~R0.50–R2.50 a photographed cover costs. At 1,200 books that is roughly R600–R3,000 of vision spend avoided — the strongest cost argument for building this at all.

### Neon compute
- **Trigger**: `insert_all` of the parsed rows; per-row dedup query; per-row book/edition/placement writes; counter updates per batch.
- **Volume**: a 1,200-row import is roughly 1,200 reads and up to 3,600 writes. Bounded and one-off.
- **Cost**: Neon at $0.16/compute-hour — a large import is minutes of compute, cents.

### Fly.io compute
- **Trigger**: `GoodreadsImportJob` batches on the `:default` queue. Mostly waiting on upstream HTTP, so cheap in CPU.
- ⚠️ The core VM is small. 25 rows per batch with an 8s race ceiling keeps peak memory flat; do not raise the batch size to "speed things up" without measuring RSS.

### Per-import cost estimate
- Resolver APIs: free (quota risk, not cost risk)
- Neon + Fly compute: a few cents
- Vision: R0
- **Total per 1,200-book import: well under $0.10 — against R600–R3,000 of vision spend it replaces.**

---

## 16. Cross-References

- **CLAUDE.md — ISBN Hard Gate**: *"No book enters the system without a verified ISBN from Open Library or Google Books. This is non-negotiable."* The import is the surface most tempting to exempt — a CSV already "has" an ISBN — and the temptation is exactly why the gate is restated here.
- **US-1.1.1 / US-1.1.2** — the upload happy path and the ISBN rejection path. The import reuses the resolver and reproduces the rejection semantics as a per-row outcome.
- **US-1.1.5** — manual ISBN entry (`docs/user_stories/US-1.1.5-manual-isbn-entry.md`), the recovery path from an unverifiable row.
- **US-1.1.6** — duplicate detection, whose semantics the import's dedup mirrors.
- **US-1.1.7** — bulk upload (`docs/user_stories/US-1.1.7-bulk-upload.md`), the sibling many-books-at-once flow; the batch/progress/report shape should feel like the same product.
- **US-1.1.8** — multi-format merge; a Goodreads export that names two bindings of one work must merge, not duplicate.
- **US-1.6.5** — empty-shelf states, the strongest entry point to this page.
- **US-14.1.2** — onboarding; an import offered during onboarding is the best first-run the closed beta can give (Milestone D reasoning).
- **US-6.1** — RSS feeds, whose regeneration this story must coalesce.
- **US-8.1 / US-8.2** — export and erasure, both of which grow here.
- **notes/phase-1-launch-extension.md** — "Goodreads killed its public API (Dec 2020, no new keys). So this is **CSV import, not a live API** … **through the ISBN hard gate** (an import is just another capture source; junk still can't enter)."
