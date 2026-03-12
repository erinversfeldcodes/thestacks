# The Stacks -- Implementation Mapping

> **Purpose:** Map every user story to the specific technical components required to implement it. This document is the bridge between _what the user experiences_ and _how the system delivers it_.
>
> **Last updated:** 2026-03-05

---

## Table of Contents

1. [Implementation Phases](#implementation-phases)
2. [Service Interaction Matrix](#service-interaction-matrix)
3. [Dependency Graph](#dependency-graph)
4. [Story-by-Story Mapping](#story-by-story-mapping)
   - [1. Core Book Management](#1-core-book-management)
   - [2. Enrichment & Discovery](#2-enrichment--discovery)
   - [3. Third Spaces](#3-third-spaces)
   - [4. Content Moderation](#4-content-moderation)
   - [5. Metrics Dashboard](#5-metrics-dashboard)
   - [6. RSS Feeds](#6-rss-feeds)
   - [7. Marketplace](#7-marketplace-future)
   - [8. GDPR & Privacy](#8-gdpr--privacy)
   - [9. Partner Integration](#9-partner-integration)

---

## Implementation Phases

| Phase | Name | Stories | Rationale |
|-------|------|---------|-----------|
| **Phase 1** | MVP | US-1.1.1, US-1.1.2, US-1.1.3, US-1.1.5, US-1.1.6, US-1.1.7, US-1.2.1, US-1.2.2, US-1.2.3, US-1.2.4, US-1.2.5, US-1.3.1, US-1.3.2, US-1.4.1, US-1.5.1, US-1.5.2, US-1.5.3, US-1.5.4, US-1.6.4, US-1.6.5 | The core loop: upload photo(s), identify book(s), review and confirm, place on shelf, browse and manage. Everything a single user needs to start using The Stacks. |
| **Phase 2** | Enrichment | US-2.1.1, US-2.2.1, US-2.2.2, US-2.3.1, US-2.4.1, US-2.5.1 | Layer intelligence on top of the book graph: reviews, prices, author info, events, and source discovery. |
| **Phase 3** | Partner Integration | US-9.1.1, US-9.1.2, US-9.2.1, US-9.2.2, US-9.3.1, US-9.3.2, US-9.4.1, US-9.4.2, US-9.5.1, US-9.6.1, US-9.6.2, US-9.7.1, US-9.7.2, US-9.8.1 | Inbound partner API, dashboard, CSV import. Depends on Third Spaces cork board and ISBN resolution from Phases 1–2. EDA and Protobuf land here as cross-cutting infrastructure. |
| **Phase 4** | Polish | US-3.1.1, US-5.1.1, US-6.1.1 | Community features (Third Spaces scraping), operational visibility (Metrics), and sharing (RSS/OPDS). |
| **Phase 5** | Marketplace | US-7.1, US-7.2, US-7.3, US-13.2.1, US-13.2.2 | Listings, payments via Stitch Money, shipping via Pargo, seller KYC. Depop/Vinted model: public Q&A + private offer threads. Closed bid mode. |
| **Phase 6** | Social Graph & Visibility | US-10.1.1, US-10.1.2, US-10.2.1, US-10.2.2, US-10.2.3, US-10.3.1, US-10.4.1, US-11.1.1, US-11.1.2, US-11.1.3, US-11.1.4 | Profile visibility, shelf/placement/post visibility, ceiling rule enforcement, view-as mode, user blocks, groups. Requires `resolve_visibility/2` context and `ViewAsPlug`. |
| **Phase 7** | Blog & Comments | US-12.1.1, US-12.1.2, US-12.1.3, US-13.1.1, US-13.1.2 | Native blog posts, LLM book associations via `PostBookAssociationWorker`, threaded comments with block filtering. Requires Phase 6 visibility infrastructure. |
| **Cross-cutting** | GDPR, Moderation, Age, EDA | US-4.1, US-4.2, US-8.1, US-8.2, US-8.3, US-8.4, US-8.5 | Built incrementally across all phases. Moderation pipeline ships with Phase 1; GDPR primitives land in Phase 1 and mature through Phase 3. Event bus (Oban) and Protobuf schema contracts land in Phase 3. Phases 6–7 add new GDPR-covered entities: `blog_posts`, `comments`, `offer_threads`, `groups`, `user_blocks`. |

---

## Service Interaction Matrix

Each cell indicates the role: **R** = Read, **W** = Write, **RW** = Read/Write, **--** = not involved.

| Story | Elm | Phoenix | Vision Service | Rust Scraper | PostgreSQL | dbt | External APIs |
|-------|-----|---------|----------------|--------------|------------|-----|---------------|
| US-1.1.1 | W (upload form, confirm) | RW (intake, pre-process, create) | RW (vision) | -- | W (books, images) | -- | Modal vision service, Open Library, Google Books |
| US-1.1.2 | R (error display) | R (validation) | -- | -- | R (books) | -- | Open Library, Google Books |
| US-1.1.3 | R (error display) | R (validation) | R (classification) | -- | W (audit_log) | -- | Modal (Qwen2.5-VL-7B-Instruct) |
| US-1.1.7 | RW (bulk drop zone, review screen, shelf selector) | RW (batch intake, pre-process, grouping, batch jobs) | RW (classify + extract per image) | -- | W (books, images, batch_id, group_id) | -- | Modal vision service, Open Library, Google Books |
| US-1.1.4 | R (gate UI) | RW (flag + gate) | -- | -- | RW (books, audit_log) | R (BISAC view) | -- |
| US-1.1.5 | RW (ISBN form) | RW (validate + create) | -- | -- | W (books, shelf_placements) | -- | Open Library, Google Books |
| US-1.1.6 | RW (duplicate UI) | R (dedup check) | -- | -- | R (books) | -- | -- |
| US-1.2.1 | RW (shelf view) | R (shelf data) | -- | -- | R (shelves, shelf_placements, books) | -- | -- |
| US-1.2.2 | RW (shelf view) | R (shelf data) | -- | -- | R (shelves, shelf_placements, books) | -- | -- |
| US-1.2.3 | RW (shelf view) | R (shelf data) | -- | -- | R (shelves, shelf_placements, books) | -- | -- |
| US-1.2.4 | RW (pile view) | R (shelf data) | -- | -- | R (shelves, shelf_placements, books) | -- | -- |
| US-1.2.5 | RW (navigation) | -- | -- | -- | -- | -- | -- |
| US-1.3.1 | RW (spine render) | R (book data) | -- | -- | R (books, shelf_placements) | -- | -- |
| US-1.3.2 | RW (detail page) | R (book + related) | -- | -- | R (books, authors, review_snapshots, price_snapshots, my_writing_links) | -- | -- |
| US-1.4.1 | RW (search UI) | R (search query) | -- | -- | R (books, authors, shelves) | -- | -- |
| US-1.5.1 | RW (move action) | RW (placement) | -- | -- | RW (shelf_placements, shelf_placement_history) | -- | -- |
| US-1.5.2 | RW (abandon action) | RW (placement) | -- | -- | RW (shelf_placements, shelf_placement_history) | -- | -- |
| US-1.5.3 | RW (re-read action) | RW (placement) | -- | -- | RW (shelf_placements, shelf_placement_history, books) | -- | -- |
| US-1.5.4 | RW (format picker) | RW (format) | -- | -- | RW (shelf_placements) | -- | -- |
| US-1.6.4 | RW (remove action) | RW (soft delete) | -- | -- | RW (shelf_placements, shelf_placement_history) | -- | -- |
| US-1.6.5 | R (empty states) | R (shelf data) | -- | -- | R (shelves, shelf_placements) | -- | -- |
| US-2.1.1 | R (review display) | RW (aggregation) | -- | -- | RW (review_snapshots) | R (sentiment view) | GoodReads, Reddit, Storygraph |
| US-2.2.1 | R (price display) | R (price data) | -- | RW (scrape) | RW (price_snapshots, bookstores) | R (price history view) | -- |
| US-2.2.2 | -- | RW (config mgmt) | -- | R (config) | RW (bookstores) | -- | -- |
| US-2.3.1 | R (author panel) | RW (author intel) | -- | -- | RW (authors, discovered_sources) | R (author view) | Brave Search, RSS feeds |
| US-2.4.1 | R (events display) | RW (event matching) | -- | -- | RW (bookstore_events, bookstores) | R (event view) | Brave Search, SearXNG |
| US-2.5.1 | R (approval UI) | RW (discovery + approval) | -- | -- | RW (discovered_sources, audit_log) | -- | Brave Search, SearXNG |
| US-3.1.1 | RW (cork board) | RW (spaces) | -- | -- | RW (third_spaces, third_space_events) | -- | Brave Search, SearXNG |
| US-4.1.1 | R (status display) | RW (pipeline) | RW (classification) | -- | RW (books, audit_log) | -- | Modal vision service, Open Library, Google Books |
| US-4.1.2 | RW (verification) | RW (KYC flow) | -- | -- | RW (audit_log) | -- | Smile Identity / Yoti / Sumsub |
| US-5.1.1 | RW (dashboard) | R (metrics) | -- | -- | R (all schemas) | RW (metric models) | -- |
| US-6.1.1 | -- | RW (feed gen) | -- | -- | R (shelves, shelf_placements, books) | -- | -- |
| US-7.1 | RW (listing form) | RW (listing) | -- | -- | RW (shelf_placements, uploaded_images) | -- | -- |
| US-7.2 | RW (purchase flow) | RW (transaction) | -- | -- | RW (shelf_placements, offer_threads, offer_messages, audit_log) | -- | Stitch Money, Pargo |
| US-7.3 | RW (KYC flow) | RW (verification) | -- | -- | RW (audit_log) | -- | Smile Identity / Yoti / Sumsub |
| US-10.1.1 | RW (privacy settings) | RW (profile visibility) | -- | -- | RW (users) | -- | -- |
| US-10.1.2 | RW (block UI) | RW (block) | -- | -- | RW (user_blocks) | -- | -- |
| US-10.2.1 | RW (shelf settings) | RW (shelf visibility) | -- | -- | RW (shelves, groups) | -- | -- |
| US-10.2.2 | RW (placement menu) | RW (placement visibility) | -- | -- | RW (shelf_placements, visibility_grants) | -- | -- |
| US-10.2.3 | RW (post editor) | RW (post visibility) | -- | -- | RW (blog_posts, groups) | -- | -- |
| US-10.3.1 | RW (preview mode) | R (resolve_visibility as viewer) | -- | -- | R (all user content tables, user_blocks, group_members) | -- | -- |
| US-10.4.1 | -- | R (noindex headers) | -- | -- | -- | -- | -- |
| US-11.1.1 | RW (group creation) | RW (group) | -- | -- | RW (groups) | -- | -- |
| US-11.1.2 | RW (invite UI) | RW (invitation) | -- | -- | RW (group_invitations, group_members) | -- | -- |
| US-11.1.3 | RW (leave group) | RW (membership) | -- | -- | RW (group_members) | -- | -- |
| US-11.1.4 | RW (member list) | RW (member mgmt) | -- | -- | RW (group_members, group_invitations) | -- | -- |
| US-12.1.1 | RW (post editor) | RW (post) | -- | -- | RW (blog_posts) | -- | -- |
| US-12.1.2 | R (associations display) | R (associations) | RW (LLM call) | -- | RW (post_book_associations) | -- | Together AI (LLM — future feature) |
| US-12.1.3 | R (blog archive) | R (posts) | -- | -- | R (blog_posts, post_book_associations) | -- | -- |
| US-13.1.1 | RW (comment UI) | RW (comment) | -- | -- | RW (comments) | -- | -- |
| US-13.1.2 | R (filtered thread) | R (recursive CTE) | -- | -- | R (comments, user_blocks) | -- | -- |
| US-13.2.1 | RW (Q&A UI) | RW (comment) | -- | -- | RW (comments) | -- | -- |
| US-13.2.2 | RW (offer thread) | RW (thread + message) | -- | -- | RW (offer_threads, offer_messages) | -- | -- |
| US-8.1.1 | RW (export UI) | RW (export gen) | -- | -- | R (all user data) | -- | -- |
| US-8.1.2 | RW (delete flow) | RW (cascade) | -- | -- | RW (all user data, wh anonymise) | -- | -- |
| US-8.1.3 | RW (consent UI) | RW (consent) | -- | -- | RW (audit_log) | -- | -- |
| US-8.1.4 | -- | RW (cleanup job) | -- | -- | RW (uploaded_images) | -- | -- |
| US-8.1.5 | -- | W (logging) | -- | -- | W (audit_log) | -- | -- |
| US-9.1.1 | RW (registration form) | RW (partner CRUD) | -- | -- | RW (partners, audit_log) | -- | -- |
| US-9.1.2 | RW (key mgmt UI) | RW (key rotation) | -- | -- | RW (partners) | -- | -- |
| US-9.2.1 | -- | RW (ingest + validate) | -- | -- | RW (partner_inventory, books, event_log) | R (availability view) | Open Library, Google Books (ISBN resolution for unknown books) |
| US-9.2.2 | RW (CSV upload UI) | RW (parse + validate) | -- | -- | RW (partner_inventory, books) | -- | Open Library, Google Books |
| US-9.3.1 | -- | RW (event ingest) | -- | -- | RW (partner_events, event_log) | -- | -- |
| US-9.3.2 | RW (event form) | RW (event CRUD) | -- | -- | RW (partner_events) | -- | -- |
| US-9.4.1 | -- | RW (space ingest) | -- | -- | RW (partner_spaces, event_log) | -- | -- |
| US-9.4.2 | RW (suggestion form) | RW (suggestion) | -- | -- | RW (third_spaces, audit_log) | -- | -- |
| US-9.5.1 | RW (metrics dashboard) | R (aggregate queries) | -- | -- | R (event_log, partner_inventory, partner_events, partner_spaces) | R (partner metrics views) | -- |
| US-9.6.1 | RW (approval UI) | RW (moderation) | -- | -- | RW (partners, partner_events, partner_spaces, audit_log) | -- | -- |
| US-9.6.2 | -- | RW (validation pipeline) | -- | -- | R (partners) | -- | -- |
| US-9.7.1 | RW (status page) | R (partner status) | -- | -- | R (partners) | -- | Resend / Postmark (confirmation email) |
| US-9.7.2 | RW (profile form) | RW (partner update) | -- | -- | RW (partners, audit_log) | -- | -- |
| US-9.8.1 | R (availability display) | R (partner inventory) | -- | -- | R (partner_inventory, books) | -- | -- |

---

## Dependency Graph

```
Legend:  A --> B  means "A must be built before B"

US-1.1.1 (Upload + Identify)
  |
  +--> US-1.1.2 (ISBN Hard Gate)           -- validation within upload
  |      |
  |      +--> US-1.1.5 (Manual ISBN Entry) -- fallback when vision fails
  +--> US-1.1.3 (Non-Book Rejection)       -- classification within upload
  +--> US-1.1.6 (Duplicate Detection)      -- dedup check within upload
  +--> US-4.1.1 (Moderation Pipeline)      -- runs as part of upload
  |      |
  |      +--> US-1.1.4 (Age-Gated Content) -- needs BISAC classification from moderation
  |             |
  |             +--> US-4.1.2 (Age Verification) -- needed to unlock gated content
  |
  +--> US-1.2.1 (Library shelf)
  +--> US-1.2.2 (AntiLibrary shelf)
  +--> US-1.2.3 (WishList shelf)
        |
        +------+------+
        |             |
        v             v
  US-1.2.4          US-1.2.5
  (Reading Pile)    (Navigate Between Shelves)
        |
        v
  US-1.3.1 (Spine Rendering)
        |
        v
  US-1.3.2 (Book Detail Page)
        |
        +----+----+----+----+
        |    |    |    |    |
        v    v    v    v    v
  1.5.1  1.5.2  1.5.3  1.5.4  1.4.1  1.6.4
  (Move) (Abandon)(Re-read)(Format)(Search)(Remove)

  US-1.2.1--4 (All shelves)
        |
        +--> US-1.6.5 (Empty Shelf States) -- each shelf needs an empty state

--- Phase 2 branches off US-1.3.2 ---

  US-1.3.2
        |
        +--> US-2.1.1 (Review Aggregation)
        +--> US-2.2.1 (Price Tracking) --> US-2.2.2 (Scraper Config)
        +--> US-2.3.1 (Author Intelligence)
        +--> US-2.4.1 (Bookstore Events) -- depends on US-2.2.2 (bookstores exist)
        +--> US-2.5.1 (Source Discovery Agent) -- feeds 2.1.1, 2.3.1, 2.4.1

--- Phase 3 branches independently ---

  US-2.5.1 --> US-3.1.1 (Third Spaces) -- uses same discovery infra
  US-1.2.x --> US-6.1.1 (RSS Feeds) -- needs shelf data
  US-8.1.5 --> US-5.1.1 (Metrics Dashboard) -- needs audit log

--- Phase 3: Partner Integration ---

  US-9.1.1 (Partner Registration)
    |
    +--> US-9.1.2 (API Key Management)
    |
    +--> US-9.2.1 (Push Inventory API)
    |      |
    |      +--> US-9.2.2 (CSV Import) -- uses same ingest pipeline
    |
    +--> US-9.3.1 (Push Events API)
    |      |
    |      +--> US-9.3.2 (Event Dashboard) -- uses same storage
    |
    +--> US-9.4.1 (Register Space)
    |
    +--> US-9.5.1 (Partner Metrics) -- needs inventory + events data
    |
    +--> US-9.6.1 (Owner Reviews Content) -- cross-cuts all partner data
    +--> US-9.6.2 (Automated Validation) -- cross-cuts all partner API endpoints

  US-9.4.2 (User-Submitted Spaces) -- independent, needs Third Spaces cork board

  US-9.1.1 --> US-9.7.1 (Registration Status) -- partner checks their application
  US-9.1.1 --> US-9.7.2 (Profile Self-Service) -- partner updates their details
  US-9.2.1 --> US-9.8.1 (Partner Availability on Book Detail) -- reader sees local stock

--- Phase 5: Marketplace ---

  US-1.3.2 --> US-7.1.1 (List for Sale)
  US-7.1.1 --> US-7.2.1 (Buy a Book)
  US-4.1.2 --> US-7.3.1 (Seller Verification)
  US-7.3.1 --> US-7.1.1 (must be verified to list)

--- Cross-cutting (incremental) ---

  US-8.1.5 (Audit Logging)        -- Phase 1, grows each phase
  US-8.1.3 (Consent Management)   -- Phase 1, required before any data collection
  US-8.1.4 (Image Retention)      -- Phase 1, runs alongside upload
  US-8.1.1 (Export Data)           -- Phase 2
  US-8.1.2 (Delete Account)       -- Phase 2
  EDA (Event Bus + event_log)     -- Phase 3, benefits all phases retroactively
  Protobuf (.proto schemas)       -- Phase 3, enforced in CI from here on
```

### Ordered Build Sequence

1. **US-8.1.5** Audit Logging (foundation -- everything logs to it)
2. **US-8.1.3** Consent Management (must exist before user data is collected)
3. **US-1.1.1** Upload Photos to Add a Book
4. **US-1.1.2** ISBN Hard Gate (part of upload)
5. **US-1.1.3** Non-Book Image Rejection (part of upload)
6. **US-4.1.1** Content Moderation Pipeline (part of upload)
7. **US-8.1.4** Image Retention (cleanup job for uploads)
8. **US-1.2.1 -- US-1.2.4** All four shelves
9. **US-1.6.5** Empty Shelf States (ships with shelves)
10. **US-1.2.5** Shelf navigation
11. **US-1.3.1** Spine rendering
12. **US-1.3.2** Book detail page
13. **US-1.4.1** Search and sort
14. **US-1.5.1 -- US-1.5.4** Shelf movement, abandon, re-read, format tracking
15. **US-1.6.4** Remove a Book from Collection
16. **US-1.1.5** Manual ISBN Entry (fallback for failed vision)
17. **US-1.1.6** Duplicate Book Detection
18. **US-1.1.4** Age-gated content
19. **US-4.1.2** Age verification
20. **US-2.5.1** Source Discovery Agent
21. **US-2.1.1** Review Aggregation
22. **US-2.2.2** Bookshop Scraper Config
23. **US-2.2.1** Price Tracking
24. **US-2.3.1** Author Intelligence
25. **US-2.4.1** Bookstore Events
26. **US-8.1.1** Export Personal Data
27. **US-8.1.2** Delete Account and Data
28. **Protobuf** Schema contracts (.proto files, buf CI, code generation) — must land before EDA (event envelope is a proto)
29. **EDA** Event bus infrastructure (event_log table, emit/subscribe, Oban workers) — retroactively benefits Phases 1-2 (shelf moves, enrichment fan-out can emit events)
30. **US-9.1.1** Partner Registration
31. **US-9.1.2** API Key Management
32. **US-9.7.1** Partner Registration Status (ships with registration)
33. **US-9.7.2** Partner Profile Self-Service
34. **US-9.6.2** Automated Content Validation (before ingest endpoints)
35. **US-9.2.1** Push Inventory API
36. **US-9.2.2** CSV Import
37. **US-9.8.1** Partner Availability on Book Detail (ships with inventory)
38. **US-9.3.1** Push Events API
39. **US-9.3.2** Event Dashboard
40. **US-9.4.1** Register a Third Space
41. **US-9.4.2** User-Submitted Third Spaces
42. **US-9.6.1** Owner Reviews Partner Content
43. **US-9.5.1** Partner Metrics
44. **US-3.1.1** Third Spaces (scraping — extends cork board)
45. **US-6.1.1** RSS Feeds
46. **US-5.1.1** Metrics Dashboard
47. **US-7.3.1** Seller Verification
48. **US-7.1.1** List a Book for Sale
49. **US-7.2.1** Buy a Book

---

## Story-by-Story Mapping

### 1. Core Book Management

---

#### US-1.1.1 -- Upload Photos to Add a Book

| Dimension | Detail |
|-----------|--------|
| **Summary** | User uploads 1-3 photos; vision model extracts book identity; ISBN resolved; book created on shelf. |
| **Phase** | Phase 1 (MVP) |

| Layer | Components |
|-------|------------|
| **Frontend (Elm)** | `Page.Upload` module -- drag-and-drop / camera capture, upload progress bar, result confirmation. Types: `UploadMsg`, `UploadModel`, `PhotoFile`. Ports for file-input interop. |
| **Backend (Phoenix)** | `Stacks.Books` context -- `Books.store_upload/2` reads the Plug temp file and base64-encodes the bytes; enqueues `IdentifyBookJob` with the image in Oban job args. `Books.create/1`, `Books.find_or_create_author/1`. `StacksWeb.UploadController` (REST). Image is never written to permanent storage. |
| **Database** | **Write:** `op.books`, `op.authors`, `op.uploaded_images`, `op.bookshelf_placements`, `op.audit_log`. **Read:** `op.books` (dedup check by ISBN). Oban job args hold the base64 image in Postgres until the worker processes them. |
| **Jobs (Oban)** | `Stacks.Workers.IdentifyBookJob` -- sends base64 image to Modal vision service over HMAC-authenticated HTTPS. `Stacks.Workers.EnrichBookJob` -- fetch metadata from Open Library / Google Books after ISBN resolved. |
| **External Services** | **Modal** (Qwen2.5-VL-7B-Instruct on A10G GPU) for image classification and book extraction. Open Library API for ISBN lookup. Google Books API as fallback. |
| **dbt Models** | None directly; feeds `stg_books`, `stg_uploaded_images` staging models. |
| **Infrastructure** | Modal hosts the Python vision service (separate from Fly.io). No object storage for uploads -- image bytes live in Oban job args (Postgres) for the duration of processing. |
| **Dependencies** | US-8.1.5 (audit logging), US-8.1.3 (consent). |

---

#### US-1.1.2 -- ISBN Hard Gate

| Dimension | Detail |
|-----------|--------|
| **Summary** | If no ISBN can be resolved from uploaded photos, the book is rejected with a clear message. No ISBN = no book. |
| **Phase** | Phase 1 (MVP) |

| Layer | Components |
|-------|------------|
| **Frontend (Elm)** | Extends `Page.Upload` -- `IdentificationFailed` variant in result type. Displays friendly rejection message with suggestion to try another photo or enter ISBN manually. |
| **Backend (Phoenix)** | `Stacks.Books` -- validation step after vision response. Returns `{:error, :no_isbn}`. Controller maps to 422 with structured error. |
| **Database** | **Write:** `op.audit_log` (record rejection). **Read:** none additional. |
| **Jobs (Oban)** | Handled within `IdentifyBookJob` -- no separate job. |
| **External Services** | Same as US-1.1.1 (failure path). |
| **dbt Models** | `int_upload_rejection_rate` (metrics). |
| **Infrastructure** | None additional. |
| **Dependencies** | US-1.1.1. |

---

#### US-1.1.3 -- Non-Book Image Rejection

| Dimension | Detail |
|-----------|--------|
| **Summary** | Images of pets, nudes, memes, etc. are rejected at the first classification step before ISBN resolution is attempted. |
| **Phase** | Phase 1 (MVP) |

| Layer | Components |
|-------|------------|
| **Frontend (Elm)** | Extends `Page.Upload` -- `NotABook` variant. Displays rejection with humour/clarity. |
| **Backend (Phoenix)** | `Stacks.Books.classify_image/1` -- first step in pipeline. Calls Modal vision service `/classify` endpoint with classification prompt. Returns `{:error, :not_a_book, category}`. |
| **Database** | **Write:** `op.audit_log` (classification result + rejection reason). |
| **Jobs (Oban)** | Part of `IdentifyBookJob` pipeline (step 1). |
| **External Services** | Modal / Qwen2.5-VL-7B-Instruct (same vision model, classification prompt). |
| **dbt Models** | `int_upload_rejection_rate`, `int_rejection_categories`. |
| **Infrastructure** | None additional. |
| **Dependencies** | US-1.1.1. |

---

#### US-1.1.4 -- Age-Gated Content

| Dimension | Detail |
|-----------|--------|
| **Summary** | Books with sensitive subjects (via BISAC codes) are flagged; only 18+ verified users can view them. |
| **Phase** | Phase 1 (late) / Cross-cutting |

| Layer | Components |
|-------|------------|
| **Frontend (Elm)** | `Components.AgeGate` -- interstitial overlay. `Page.BookDetail` checks `visibility_tier` before rendering. Blurred placeholder for gated books in shelf views. |
| **Backend (Phoenix)** | `Stacks.Moderation` context -- `Moderation.classify_subject/1` using BISAC code lookup. `Stacks.Accounts` -- `age_verified?/1` check. Plug `StacksWeb.Plugs.AgeGate` on relevant routes. |
| **Database** | **Read:** `op.books` (BISAC codes, visibility_tier). **Write:** `op.books` (set visibility_tier on classification). `op.audit_log`. |
| **Jobs (Oban)** | Part of moderation pipeline job (US-4.1.1). |
| **External Services** | None (BISAC lookup is local data). |
| **dbt Models** | `int_content_classification`. |
| **Infrastructure** | None additional. |
| **Dependencies** | US-4.1.1, US-4.1.2. |

---

#### US-1.1.5 -- Manual ISBN Entry

| Dimension | Detail |
|-----------|--------|
| **Summary** | Fallback when vision model fails: user types ISBN manually, client-side checksum validation, then standard ISBN resolution pipeline. |
| **Phase** | Phase 1 (MVP) |

| Layer | Components |
|-------|------------|
| **Frontend (Elm)** | `Page.Upload` -- `ManualISBNEntry` variant. `Components.ISBNInput` with client-side ISBN-10/ISBN-13 checksum validation (mod-10/mod-13). Inline validation feedback before submit. |
| **Backend (Phoenix)** | `Stacks.Books.create_from_isbn/1` -- skips vision, goes straight to ISBN resolution. Same `ISBNResolver` pipeline as US-1.1.1. |
| **Database** | Same as US-1.1.1 (books, shelf_placements, audit_log). |
| **Jobs (Oban)** | `EnrichBookJob` -- same as US-1.1.1. |
| **External Services** | Open Library, Google Books (ISBN resolution). |
| **dbt Models** | `int_upload_method` (track manual vs. vision entry rates). |
| **Infrastructure** | None additional. |
| **Dependencies** | US-1.1.2 (ISBN Hard Gate — same validation applies). |

---

#### US-1.1.6 -- Duplicate Book Detection

| Dimension | Detail |
|-----------|--------|
| **Summary** | When a resolved ISBN already exists in the user's collection, show the existing book with options: view it, move it to another shelf, or close and continue. |
| **Phase** | Phase 1 (MVP) |

| Layer | Components |
|-------|------------|
| **Frontend (Elm)** | `Components.DuplicateDetected` -- shows existing book cover + current shelf, with "View Book", "Move to Shelf", and "Close" actions. |
| **Backend (Phoenix)** | `Stacks.Books.find_existing/1` -- ISBN dedup check (already implicit in US-1.1.1, now surfaced to user). Returns existing book data if found. |
| **Database** | **Read:** `op.books` (ISBN lookup), `op.shelf_placements` (current shelf). |
| **Jobs (Oban)** | None. |
| **External Services** | None. |
| **dbt Models** | `int_duplicate_detection_rate`. |
| **Infrastructure** | None additional. |
| **Dependencies** | US-1.1.1 (part of upload flow). |

---

#### US-1.1.7 -- Bulk Image Upload with Grouping and Review

| Dimension | Detail |
|-----------|--------|
| **Summary** | User drops N images; system classifies, extracts, and groups related images (same book → same group); user reviews a confirmation screen with one card per detected book; shelf is chosen per card; confirmed books go through standard ISBN pipeline. Multi-book images (shelfie, screenshot of reading list) produce multiple cards from a single image. |
| **Phase** | Phase 1 (MVP) |

| Layer | Components |
|-------|------------|
| **Frontend (Elm)** | `Page.Upload` extended — bulk drop zone accepting N files. `Page.Upload.Review` — card grid with confirmed/ambiguous/rejected buckets. `Components.BookReviewCard` — thumbnail, title, author, shelf selector, confirm/dismiss actions. `Components.BulkProgress` — processing indicator. |
| **Backend (Phoenix)** | `StacksWeb.UploadController.create_batch/2` — accepts N images, stores each, enqueues `BatchIdentifyJob`. `StacksWeb.UploadController.batch_status/2` — polls overall batch progress. `Stacks.Books.group_by_isbn/1` — merges images that resolved to the same ISBN into a single group. |
| **Database** | **Write:** `op.uploaded_images` with `batch_id UUID` and `group_id UUID` columns (new — migration required). **Write:** `op.books`, `op.bookshelf_placements`, `op.audit_log` per confirmed book. |
| **Jobs (Oban)** | `Stacks.Workers.BatchIdentifyJob` — orchestrator: fans out one `IdentifyBookJob` per image, collects results, performs grouping, writes batch status. |
| **External Services** | Modal vision service (classify + extract per image). Open Library, Google Books (ISBN resolution per confirmed book). |
| **dbt Models** | `int_bulk_upload_batch_size`, `int_bulk_upload_confirmation_rate` (how many detected books users confirm vs. dismiss). |
| **Infrastructure** | No new services. Requires `batch_id` and `group_id` migration on `op.uploaded_images`. |
| **Dependencies** | US-1.1.1 (single-image pipeline); Issue #008 (multi-book extraction API — `/extract` must return `books: list` before this can be implemented); Issue #009 (bulk upload issue). |

---

#### US-1.2.1 -- The Library Shelf

| Dimension | Detail |
|-----------|--------|
| **Summary** | Dark walnut shelf, green damask background. Displays books the user has read. |
| **Phase** | Phase 1 (MVP) |

| Layer | Components |
|-------|------------|
| **Frontend (Elm)** | `Page.Shelf.Library` module. Shared `Shelf.View` component with theme config (`ShelfTheme` type: `{ wood: DarkWalnut, backdrop: GreenDamask }`). Renders list of spines via `Components.Spine`. |
| **Backend (Phoenix)** | `Stacks.Shelving` context -- `Shelves.get_shelf_books/2` with shelf_type `:library`. `StacksWeb.ShelfController.show/2`. |
| **Database** | **Read:** `op.shelves`, `op.shelf_placements`, `op.books`, `op.authors`. |
| **Jobs (Oban)** | None. |
| **External Services** | None. |
| **dbt Models** | `stg_shelf_placements`, `int_shelf_composition`. |
| **Infrastructure** | None additional. |
| **Dependencies** | US-1.1.1 (books must exist). |

---

#### US-1.2.2 -- The AntiLibrary Shelf

| Dimension | Detail |
|-----------|--------|
| **Summary** | Lighter oak shelf, botanical prints. Books owned but not yet read. |
| **Phase** | Phase 1 (MVP) |

| Layer | Components |
|-------|------------|
| **Frontend (Elm)** | `Page.Shelf.AntiLibrary` module. `ShelfTheme` config: `{ wood: LightOak, backdrop: BotanicalPrints }`. Same `Shelf.View` component as Library. |
| **Backend (Phoenix)** | Same `Stacks.Shelving` context, shelf_type `:anti_library`. |
| **Database** | Same as US-1.2.1. |
| **Jobs (Oban)** | None. |
| **External Services** | None. |
| **dbt Models** | Same as US-1.2.1. |
| **Infrastructure** | None additional. |
| **Dependencies** | US-1.1.1. |

---

#### US-1.2.3 -- The WishList Shelf

| Dimension | Detail |
|-----------|--------|
| **Summary** | Blue-grey shelf, watercolour florals. Books the user wants but does not own. |
| **Phase** | Phase 1 (MVP) |

| Layer | Components |
|-------|------------|
| **Frontend (Elm)** | `Page.Shelf.WishList` module. `ShelfTheme` config: `{ wood: BlueGrey, backdrop: WatercolourFlorals }`. |
| **Backend (Phoenix)** | Same `Stacks.Shelving` context, shelf_type `:wish_list`. |
| **Database** | Same as US-1.2.1. |
| **Jobs (Oban)** | None. |
| **External Services** | None. |
| **dbt Models** | Same as US-1.2.1. |
| **Infrastructure** | None additional. |
| **Dependencies** | US-1.1.1. |

---

#### US-1.2.4 -- The Reading Pile

| Dimension | Detail |
|-----------|--------|
| **Summary** | Books stacked on a side table next to an armchair, face-on view showing spines. Cosy aesthetic. Currently reading. |
| **Phase** | Phase 1 (MVP) |

| Layer | Components |
|-------|------------|
| **Frontend (Elm)** | `Page.Shelf.ReadingPile` module. Different layout from shelves -- vertical stack / pile metaphor rather than horizontal shelf. `PileView` component with armchair background. |
| **Backend (Phoenix)** | Same `Stacks.Shelving` context, shelf_type `:reading_pile`. May include reading progress data. |
| **Database** | Same as US-1.2.1. |
| **Jobs (Oban)** | None. |
| **External Services** | None. |
| **dbt Models** | Same as US-1.2.1. |
| **Infrastructure** | None additional. |
| **Dependencies** | US-1.1.1. |

---

#### US-1.2.5 -- Navigate Between Shelves

| Dimension | Detail |
|-----------|--------|
| **Summary** | Horizontal slide animation for adjacent shelves; room-transition animation for different metaphors (shelf vs. pile). |
| **Phase** | Phase 1 (MVP) |

| Layer | Components |
|-------|------------|
| **Frontend (Elm)** | `Navigation.ShelfRouter` module. Elm `Browser.application` with URL-driven routing. `Animation.SlideTransition` and `Animation.RoomTransition` modules using `elm-animator` or CSS keyframe ports. Swipe gesture detection via ports for mobile. |
| **Backend (Phoenix)** | None -- purely client-side routing. Phoenix handles initial page load and falls back to SSR for direct URL access. |
| **Database** | None. |
| **Jobs (Oban)** | None. |
| **External Services** | None. |
| **dbt Models** | None. |
| **Infrastructure** | None additional. |
| **Dependencies** | US-1.2.1, US-1.2.2, US-1.2.3, US-1.2.4 (all shelves must exist to navigate between them). |

---

#### US-1.3.1 -- Spine Rendering

| Dimension | Detail |
|-----------|--------|
| **Summary** | Spine thickness proportional to page count. Wear level by engagement (pristine, softened, cracking, well-read, well-loved). Bookmark icon for books with linked writing. |
| **Phase** | Phase 1 (MVP) |

| Layer | Components |
|-------|------------|
| **Frontend (Elm)** | `Components.Spine` module. Types: `SpineData { pageCount: Int, wearLevel: WearLevel, hasWriting: Bool, colour: SpineColour }`. `WearLevel` = `Pristine | Softened | Cracking | WellRead | WellLoved`. CSS/SVG rendering with texture maps per wear level. |
| **Backend (Phoenix)** | `Stacks.Shelving.spine_data/1` -- computes wear level from shelf_placement_history (number of reads, time on shelves). Returns precomputed spine metadata. |
| **Database** | **Read:** `op.books` (page_count), `op.shelf_placement_history` (engagement calc), `op.my_writing_links` (has_writing flag). |
| **Jobs (Oban)** | `Stacks.Workers.RecalculateWearJob` -- periodic recalculation of wear levels (or on shelf-move events). |
| **External Services** | None. |
| **dbt Models** | `int_book_engagement` (materialized view for wear calculation). |
| **Infrastructure** | None additional. |
| **Dependencies** | US-1.2.1 -- US-1.2.4 (shelves to render spines on). |

---

#### US-1.3.2 -- Book Detail Page

| Dimension | Detail |
|-----------|--------|
| **Summary** | Click spine to open: cover image, metadata, reviews, prices, author info, writing links, move-to-shelf action. |
| **Phase** | Phase 1 (MVP) |

| Layer | Components |
|-------|------------|
| **Frontend (Elm)** | `Page.BookDetail` module. Sub-components: `Components.CoverImage`, `Components.BookMeta`, `Components.ReviewSummary` (stub in Phase 1), `Components.PriceInfo` (stub in Phase 1), `Components.AuthorCard`, `Components.WritingLinks`, `Components.ShelfMover`, `Components.PartnerAvailability` (Phase 3+, "Available at [Shop] for R149"). Messages: `MoveToShelf ShelfType`, `OpenExternalLink Url`. |
| **Backend (Phoenix)** | `Stacks.Books.get_book_detail/1` -- aggregates book + author + reviews + prices + writing links + partner availability (Phase 3+). `StacksWeb.BookController.show/2`. |
| **Database** | **Read:** `op.books`, `op.authors`, `op.review_snapshots`, `op.price_snapshots`, `op.my_writing_links`, `op.shelf_placements`. Phase 3+: `op.partner_inventory`, `op.partner_events` (for ISBN-linked events). |
| **Jobs (Oban)** | None directly (data populated by enrichment jobs). |
| **External Services** | None at render time. |
| **dbt Models** | `int_book_detail_view` (pre-joined view for performance). |
| **Infrastructure** | SSR rendering for public book pages (Phoenix templates). |
| **Dependencies** | US-1.3.1 (spine must be clickable), US-1.1.1 (books exist). |

---

#### US-1.4.1 -- Search and Sort Books

| Dimension | Detail |
|-----------|--------|
| **Summary** | Search across all shelves or within a specific shelf. Sort by title, author, date added, rating. Filter by genre, format, price range. |
| **Phase** | Phase 1 (MVP) |

| Layer | Components |
|-------|------------|
| **Frontend (Elm)** | `Page.Search` module. `Components.SearchBar` (debounced input). `Components.FilterPanel` (genre tags, format checkboxes, price range slider). `Components.SortSelector`. Types: `SearchQuery`, `SortField`, `FilterSet`. |
| **Backend (Phoenix)** | `Stacks.Books.search_books/2` -- Ecto query with full-text search (`pg_trgm` or `tsvector`), dynamic sort, filter composition. `StacksWeb.SearchController.index/2`. |
| **Database** | **Read:** `op.books` (with GIN index on title/author tsvector), `op.authors`, `op.shelves`, `op.shelf_placements`, `op.price_snapshots` (for price filter). |
| **Jobs (Oban)** | None. |
| **External Services** | None. |
| **dbt Models** | None directly. |
| **Infrastructure** | PostgreSQL GIN / GiST indexes for full-text search. |
| **Dependencies** | US-1.1.1, US-1.2.1 -- US-1.2.4. |

---

#### US-1.5.1 -- Move Books Between Shelves

| Dimension | Detail |
|-----------|--------|
| **Summary** | Standard flow: WishList -> AntiLibrary -> Reading Pile -> Library. History of all movements preserved. |
| **Phase** | Phase 1 (MVP) |

| Layer | Components |
|-------|------------|
| **Frontend (Elm)** | `Components.ShelfMover` -- dropdown or contextual menu showing valid target shelves. Animation of book sliding to new shelf. Confirmation toast. |
| **Backend (Phoenix)** | `Stacks.Shelving.move_book/3` -- validates transition, updates placement, writes history. `StacksWeb.ShelfPlacementController.update/2`. |
| **Database** | **Write:** `op.shelf_placements` (update shelf_id), `op.shelf_placement_history` (insert movement record). **Read:** `op.shelf_placements` (current location). |
| **Jobs (Oban)** | `Stacks.Workers.RecalculateWearJob` triggered on move (wear may change). |
| **External Services** | None. |
| **dbt Models** | `stg_shelf_placement_history`, `int_book_journey`. |
| **Infrastructure** | None additional. |
| **Dependencies** | US-1.2.1 -- US-1.2.4, US-1.3.2 (move action lives on detail page). |

---

#### US-1.5.2 -- Abandon a Book

| Dimension | Detail |
|-----------|--------|
| **Summary** | Move from Reading Pile back to AntiLibrary. Optional note about why abandoned. |
| **Phase** | Phase 1 (MVP) |

| Layer | Components |
|-------|------------|
| **Frontend (Elm)** | `Components.AbandonModal` -- optional textarea for note, confirm/cancel. Triggered from Reading Pile or Book Detail. |
| **Backend (Phoenix)** | `Stacks.Shelving.abandon_book/2` -- special case of move with optional `abandon_note`. |
| **Database** | **Write:** `op.shelf_placements`, `op.shelf_placement_history` (with note field). |
| **Jobs (Oban)** | Wear recalculation. |
| **External Services** | None. |
| **dbt Models** | `int_abandonment_rate` (metrics). |
| **Infrastructure** | None additional. |
| **Dependencies** | US-1.5.1, US-1.2.4 (Reading Pile). |

---

#### US-1.5.3 -- Re-Read a Book

| Dimension | Detail |
|-----------|--------|
| **Summary** | Move from Library back to Reading Pile. Wear level increases. |
| **Phase** | Phase 1 (MVP) |

| Layer | Components |
|-------|------------|
| **Frontend (Elm)** | Re-read button on Book Detail when book is on Library shelf. Uses `Components.ShelfMover` with pre-selected target. |
| **Backend (Phoenix)** | `Stacks.Shelving.reread_book/1` -- moves to Reading Pile, triggers wear recalculation. Read count is derived from `shelf_placement_history` (no denormalised counter). |
| **Database** | **Write:** `op.shelf_placements`, `op.shelf_placement_history`. |
| **Jobs (Oban)** | `RecalculateWearJob`. |
| **External Services** | None. |
| **dbt Models** | `int_book_engagement`. |
| **Infrastructure** | None additional. |
| **Dependencies** | US-1.5.1, US-1.2.1 (Library). |

---

#### US-1.5.4 -- Format Tracking

| Dimension | Detail |
|-----------|--------|
| **Summary** | Track which formats the user owns per book: hardcover, softcover, kindle, e-book, audiobook. |
| **Phase** | Phase 1 (MVP) |

| Layer | Components |
|-------|------------|
| **Frontend (Elm)** | `Components.FormatPicker` -- multi-select checkboxes on Book Detail. Icons for each format. |
| **Backend (Phoenix)** | `Stacks.Books.update_placement_formats/2`. Formats stored as `TEXT[]` on `shelf_placements`. |
| **Database** | **Write:** `op.shelf_placements` (formats array). |
| **Jobs (Oban)** | None. |
| **External Services** | None. |
| **dbt Models** | `int_format_distribution`. |
| **Infrastructure** | None additional. |
| **Dependencies** | US-1.3.2 (format picker lives on detail page). |

---

#### US-1.6.4 -- Remove a Book from Collection

| Dimension | Detail |
|-----------|--------|
| **Summary** | Soft delete via `shelf_placements.removed_at`. Book row preserved. Reading history preserved. Confirmation dialog warns this removes from all shelves. |
| **Phase** | Phase 1 (MVP) |

| Layer | Components |
|-------|------------|
| **Frontend (Elm)** | `Components.RemoveBookModal` -- confirmation with book title, warning text ("This removes [title] from your collection. Your reading history is preserved."), confirm/cancel. Triggered from Book Detail page. |
| **Backend (Phoenix)** | `Stacks.Shelving.remove_book/1` -- sets `removed_at` on all `shelf_placements` for the book. Does NOT delete the `books` row. Writes history record. |
| **Database** | **Write:** `op.shelf_placements` (set removed_at), `op.shelf_placement_history` (removal record). **Read:** `op.shelf_placements` (current placements). |
| **Jobs (Oban)** | `RecalculateWearJob` (no longer on shelf). |
| **External Services** | None. |
| **dbt Models** | `int_collection_churn`. |
| **Infrastructure** | None additional. |
| **Dependencies** | US-1.3.2 (remove action lives on detail page). |

---

#### US-1.6.5 -- Empty Shelf States

| Dimension | Detail |
|-----------|--------|
| **Summary** | Each shelf displays a themed empty state when no books are present: Library ("Your library awaits..."), AntiLibrary ("Unread worlds..."), WishList ("What will you read next?"), Reading Pile ("Pick up something new"), Third Spaces ("Discover reading spaces"), Metrics ("Add books to see insights"). |
| **Phase** | Phase 1 (MVP) |

| Layer | Components |
|-------|------------|
| **Frontend (Elm)** | `Components.EmptyShelf` -- per-shelf variant with themed illustration and message. Rendered when `shelf_placements` count is 0 for a shelf. Includes CTA button ("Add a book" → upload). |
| **Backend (Phoenix)** | None additional (empty state is client-side based on empty shelf data). |
| **Database** | **Read:** `op.shelves`, `op.shelf_placements` (count check). |
| **Jobs (Oban)** | None. |
| **External Services** | None. |
| **dbt Models** | None. |
| **Infrastructure** | None additional. |
| **Dependencies** | US-1.2.1 -- US-1.2.4 (shelves must exist). |

---

### 2. Enrichment & Discovery

---

#### US-2.1.1 -- Review Aggregation

| Dimension | Detail |
|-----------|--------|
| **Summary** | Aggregate reviews from GoodReads, Reddit, Storygraph. Show sentiment overview and source links. |
| **Phase** | Phase 2 (Enrichment) |

| Layer | Components |
|-------|------------|
| **Frontend (Elm)** | `Components.ReviewSummary` -- sentiment bar (positive/mixed/negative), source cards with rating + link. Expandable detail. |
| **Backend (Phoenix)** | `Stacks.Enrichment.Reviews` context. `ReviewAggregator` Broadway pipeline for ingestion. `Enrichment.Reviews.get_review_summary/1`. |
| **Database** | **Write:** `op.review_snapshots`. **Read:** `op.books` (ISBN for lookup). |
| **Jobs (Oban)** | `Stacks.Workers.FetchReviewsJob` -- per-book, scheduled with adaptive staleness (popular books refresh more often). |
| **External Services** | GoodReads (scrape/API), Reddit API, Storygraph (scrape). |
| **dbt Models** | `stg_review_snapshots`, `int_review_sentiment`, `mart_book_reviews`. |
| **Infrastructure** | Broadway pipeline for backpressure on bulk review fetching. |
| **Dependencies** | US-1.1.1, US-1.3.2 (reviews displayed on detail page). |

---

#### US-2.2.1 -- Price Tracking

| Dimension | Detail |
|-----------|--------|
| **Summary** | Track prices from SA bookshops. Show price history with sparkline trends. |
| **Phase** | Phase 2 (Enrichment) |

| Layer | Components |
|-------|------------|
| **Frontend (Elm)** | `Components.PriceInfo` -- current prices by store, sparkline chart (SVG or elm-charts), lowest price highlight. |
| **Backend (Phoenix)** | `Stacks.Enrichment.Prices` context. Receives scraped data from Rust scraper via internal API or message queue. `Enrichment.Prices.get_price_history/1`. |
| **Database** | **Write:** `op.price_snapshots`, `op.bookstores`. **Read:** `op.books` (ISBN). |
| **Jobs (Oban)** | `Stacks.Workers.TriggerPriceScrapeJob` -- signals Rust scraper for a batch of ISBNs. |
| **External Services** | Rust scraper microservice (internal). |
| **dbt Models** | `stg_price_snapshots`, `int_price_trends`, `mart_book_prices`. |
| **Infrastructure** | Rust scraper as separate Fly.io machine. Internal networking between Phoenix and Rust service. |
| **Dependencies** | US-1.1.1, US-2.2.2 (scraper config must exist). |

---

#### US-2.2.2 -- Configure Bookshop Scrapers

| Dimension | Detail |
|-----------|--------|
| **Summary** | TOML configuration per bookstore per country. Defines scraping targets, selectors, rate limits. |
| **Phase** | Phase 2 (Enrichment) |

| Layer | Components |
|-------|------------|
| **Frontend (Elm)** | Admin-only `Page.Admin.ScraperConfig` -- TOML editor with validation feedback. |
| **Backend (Phoenix)** | `Stacks.Admin.ScraperConfig` context -- CRUD for bookstore scraper configs. Validates TOML, pushes to Rust scraper. `StacksWeb.Admin.ScraperConfigController`. |
| **Database** | **Write:** `op.bookstores` (config column). |
| **Jobs (Oban)** | None (config is synchronous). |
| **External Services** | Rust scraper (config reload endpoint). |
| **dbt Models** | None. |
| **Infrastructure** | TOML files or DB-stored config synced to Rust service. |
| **Dependencies** | None (can be built independently, needed before US-2.2.1). |

---

#### US-2.3.1 -- Author Intelligence

| Dimension | Detail |
|-----------|--------|
| **Summary** | Track author websites, RSS feeds, events, new releases. |
| **Phase** | Phase 2 (Enrichment) |

| Layer | Components |
|-------|------------|
| **Frontend (Elm)** | `Components.AuthorCard` (expanded) -- website link, latest RSS posts, upcoming events, new releases list. |
| **Backend (Phoenix)** | `Stacks.Enrichment.Authors` context. `Enrichment.Authors.get_author_intel/1`. RSS feed parser (Elixir `feeder_ex` or similar). |
| **Database** | **Write:** `op.authors` (website, rss_url, last_fetched). `op.discovered_sources` (author-related sources). **Read:** `op.books` (by author). |
| **Jobs (Oban)** | `Stacks.Workers.FetchAuthorRSSJob` -- periodic RSS poll. `Stacks.Workers.DiscoverAuthorSourcesJob` -- uses Brave Search to find author info. |
| **External Services** | Brave Search API, author RSS feeds, publisher sites. |
| **dbt Models** | `stg_authors`, `int_author_activity`. |
| **Infrastructure** | None additional. |
| **Dependencies** | US-1.1.1, US-2.5.1 (source discovery feeds author intelligence). |

---

#### US-2.4.1 -- Bookstore Events

| Dimension | Detail |
|-----------|--------|
| **Summary** | Discover book signings, readings at physical stores. Match to user's books/authors. |
| **Phase** | Phase 2 (Enrichment) |

| Layer | Components |
|-------|------------|
| **Frontend (Elm)** | `Page.Events` module. `Components.EventCard` -- store name, event type, date, matched book/author. Calendar-style or list view. |
| **Backend (Phoenix)** | `Stacks.Enrichment.Events` context. `Enrichment.Events.get_matched_events/1` -- joins events with user's book/author graph. |
| **Database** | **Write:** `op.bookstore_events`. **Read:** `op.bookstores`, `op.books`, `op.authors`, `op.shelf_placements`. |
| **Jobs (Oban)** | `Stacks.Workers.DiscoverBookstoreEventsJob` -- periodic search for events. |
| **External Services** | Brave Search, SearXNG, bookstore websites. |
| **dbt Models** | `stg_bookstore_events`, `int_event_matches`. |
| **Infrastructure** | None additional. |
| **Dependencies** | US-2.2.2 (bookstores must exist), US-2.5.1 (discovery agent). |

---

#### US-2.5.1 -- Source Discovery Agent

| Dimension | Detail |
|-----------|--------|
| **Summary** | Automatic + scheduled agent that uses Brave Search and SearXNG to discover review sources, author info, events. LLM confidence scoring. Human approval before activation. |
| **Phase** | Phase 2 (Enrichment) |

| Layer | Components |
|-------|------------|
| **Frontend (Elm)** | `Page.Admin.SourceApproval` -- queue of discovered sources with confidence scores. Approve/reject actions. |
| **Backend (Phoenix)** | `Stacks.Discovery` context. `Discovery.Agent` GenServer or Oban-driven. `Discovery.search_and_score/1` -- calls search APIs, runs LLM scoring. `Discovery.approve_source/1`, `Discovery.reject_source/1`. |
| **Database** | **Write:** `op.discovered_sources` (url, type, confidence, status, approved_at). `op.audit_log`. **Read:** `op.books`, `op.authors` (to generate search queries). |
| **Jobs (Oban)** | `Stacks.Workers.SourceDiscoveryJob` -- scheduled (e.g., daily). `Stacks.Workers.ScoreSourceJob` -- LLM confidence scoring per discovered URL. |
| **External Services** | Brave Search API, SearXNG (self-hosted), Together AI (LLM scoring — future feature). |
| **dbt Models** | `stg_discovered_sources`, `int_source_approval_rate`. |
| **Infrastructure** | SearXNG instance on Fly.io. Rate limiting for Brave Search API. |
| **Dependencies** | US-1.1.1 (books/authors must exist to search for). |

---

### 3. Third Spaces

---

#### US-3.1.1 -- Third Spaces Page

| Dimension | Detail |
|-----------|--------|
| **Summary** | Cork board aesthetic displaying reading groups, cafes, festivals. Discovered via search. Users share off-platform links. Country-aware location settings. |
| **Phase** | Phase 4 (Polish) |

| Layer | Components |
|-------|------------|
| **Frontend (Elm)** | `Page.ThirdSpaces` module. `Components.CorkBoard` -- pinned card layout. `Components.SpaceCard` -- name, type, location, external link. `Components.LocationFilter` -- country/city selector. |
| **Backend (Phoenix)** | `Stacks.ThirdSpaces` context. CRUD for spaces. `StacksWeb.ThirdSpaceController`. Location-based filtering with country config. |
| **Database** | **Write:** `op.third_spaces`, `op.third_space_events`. **Read:** same. |
| **Jobs (Oban)** | `Stacks.Workers.DiscoverThirdSpacesJob` -- periodic discovery of new spaces. |
| **External Services** | Brave Search, SearXNG. |
| **dbt Models** | `stg_third_spaces`. |
| **Infrastructure** | None additional. |
| **Dependencies** | US-2.5.1 (uses same discovery infrastructure). |

---

### 4. Content Moderation

---

#### US-4.1.1 -- Content Moderation Pipeline

| Dimension | Detail |
|-----------|--------|
| **Summary** | 4-step pipeline: (1) book check via vision, (2) ISBN resolution, (3) BISAC subject classification, (4) store with visibility tier. |
| **Phase** | Phase 1 (MVP) / Cross-cutting |

| Layer | Components |
|-------|------------|
| **Frontend (Elm)** | Status indicators on upload flow -- progress through pipeline steps. Error states per step. |
| **Backend (Phoenix)** | `Stacks.Moderation` context. `Moderation.Pipeline` -- orchestrates 4 steps as a state machine. Steps: `classify_image/1` -> `resolve_isbn/1` -> `classify_subject/1` -> `store_with_tier/1`. |
| **Database** | **Write:** `op.books` (visibility_tier), `op.audit_log` (each step logged). **Read:** `op.books` (dedup). |
| **Jobs (Oban)** | Integrated into `IdentifyBookJob` as sub-steps, or `Stacks.Workers.ModerationPipelineJob` as separate orchestrator. |
| **External Services** | Modal vision service (step 1), Open Library / Google Books (step 2). |
| **dbt Models** | `int_moderation_outcomes`. |
| **Infrastructure** | None additional. |
| **Dependencies** | US-1.1.1 (runs as part of upload). |

---

#### US-4.1.2 -- Age Verification

| Dimension | Detail |
|-----------|--------|
| **Summary** | KYC integration for age verification. Self-config for single-user. Proper verification for multi-user. |
| **Phase** | Cross-cutting (Phase 1 for self-config, Phase 3 for full KYC) |

| Layer | Components |
|-------|------------|
| **Frontend (Elm)** | `Page.Settings.AgeVerification` -- self-declaration toggle (single-user) or KYC upload flow (multi-user). `Components.KYCWidget` -- iframe or redirect to provider. |
| **Backend (Phoenix)** | `Stacks.Accounts.Verification` -- `verify_age/1`, `self_declare_age/1`. KYC provider integration module. `StacksWeb.VerificationController`. |
| **Database** | **Write:** `op.audit_log` (verification events). User account flags (age_verified, verification_method). |
| **Jobs (Oban)** | `Stacks.Workers.KYCCallbackJob` -- process async KYC provider callbacks. |
| **External Services** | Smile Identity, Yoti, or Sumsub (KYC provider). |
| **dbt Models** | None. |
| **Infrastructure** | Webhook endpoint for KYC provider callbacks. |
| **Dependencies** | US-4.1.1 (need content to gate). |

---

### 5. Metrics Dashboard

---

#### US-5.1.1 -- Operational Metrics

| Dimension | Detail |
|-----------|--------|
| **Summary** | System health, job status, data freshness, source discovery stats, costs, GDPR compliance. Curator's desk aesthetic. NOT user reading analytics. |
| **Phase** | Phase 4 (Polish) |

| Layer | Components |
|-------|------------|
| **Frontend (Elm)** | `Page.Admin.Metrics` module. `Components.MetricCard`, `Components.JobStatusTable`, `Components.FreshnessGauge`, `Components.CostTracker`. Curator's desk visual theme. |
| **Backend (Phoenix)** | `Stacks.Admin.Metrics` context -- aggregates from Oban telemetry, dbt freshness, audit log. `StacksWeb.Admin.MetricsController`. |
| **Database** | **Read:** `op.audit_log`, `wh.*` (warehouse views), Oban job tables, `op.discovered_sources`. |
| **Jobs (Oban)** | `Stacks.Workers.MetricsSnapshotJob` -- periodic snapshot of system state. |
| **External Services** | None (all internal data). |
| **dbt Models** | `mart_system_health`, `mart_job_stats`, `mart_data_freshness`, `mart_cost_tracking`, `mart_gdpr_compliance`. |
| **Infrastructure** | dbt scheduled runs (could be Oban-triggered or cron). |
| **Dependencies** | US-8.1.5 (audit log must exist). Most useful after Phase 2 when enrichment jobs are running. |

---

### 6. RSS Feeds

---

#### US-6.1.1 -- Shelf RSS Feeds

| Dimension | Detail |
|-----------|--------|
| **Summary** | Atom feed per public shelf. Friends can follow shelves. Enables IRL book borrowing. |
| **Phase** | Phase 4 (Polish) |

| Layer | Components |
|-------|------------|
| **Frontend (Elm)** | RSS icon/link on shelf pages. `Components.RSSLink`. No Elm rendering of feed itself (consumed by RSS readers). |
| **Backend (Phoenix)** | `Stacks.Feeds` context. `Feeds.generate_atom/2` -- builds Atom XML for a shelf. `StacksWeb.FeedController.show/2` -- serves XML with correct content type. Cache with ETag/Last-Modified. |
| **Database** | **Read:** `op.shelves`, `op.shelf_placements`, `op.books`, `op.authors`. |
| **Jobs (Oban)** | `Stacks.Workers.RegenerateFeedJob` -- regenerate cached feed when shelf changes (event-driven). |
| **External Services** | None. |
| **dbt Models** | None. |
| **Infrastructure** | CDN caching for feed XML. |
| **Dependencies** | US-1.2.1 -- US-1.2.4 (shelves must exist). |

---

### 7. Marketplace (Future)

---

#### US-7.1.1 -- List a Book for Sale

| Dimension | Detail |
|-----------|--------|
| **Summary** | Photos required, condition grading, fixed price or make-an-offer with seller-set minimum or decline. |
| **Phase** | Phase 5 (Marketplace) |

| Layer | Components |
|-------|------------|
| **Frontend (Elm)** | `Page.Marketplace.CreateListing` -- photo upload (reuse upload components), condition selector (enum), pricing mode toggle (fixed / offer), minimum price input. `Components.ConditionGrader`. |
| **Backend (Phoenix)** | `Stacks.Marketplace` context. `Marketplace.create_listing/1`. `StacksWeb.ListingController`. Listing state machine: `draft -> active -> sold -> removed`. |
| **Database** | **Write:** `op.books` (listing fields or separate listings table), `op.uploaded_images` (listing photos). **Read:** `op.books`. |
| **Jobs (Oban)** | `Stacks.Workers.ListingExpiryJob` -- auto-expire stale listings. |
| **External Services** | None. |
| **dbt Models** | `stg_listings`, `mart_marketplace_activity`. |
| **Infrastructure** | Image storage for listing photos. |
| **Dependencies** | US-7.3.1 (seller must be verified), US-1.1.1 (book must exist). |

---

#### US-7.2.1 -- Buy a Book

| Dimension | Detail |
|-----------|--------|
| **Summary** | Browse listings, make offer or buy at fixed price. Stitch Money payment. Pargo shipping at checkout. |
| **Phase** | Phase 5 (Marketplace) |

| Layer | Components |
|-------|------------|
| **Frontend (Elm)** | `Page.Marketplace.Browse` -- listing cards with price/condition. `Page.Marketplace.Checkout` -- payment form (Stitch widget), shipping address, Pargo pickup point selector. `Components.OfferModal`. |
| **Backend (Phoenix)** | `Stacks.Marketplace.Transactions` -- `create_offer/1`, `accept_offer/1`, `initiate_payment/1`, `create_shipment/1`. `StacksWeb.TransactionController`. Webhook handlers for Stitch and Pargo callbacks. |
| **Database** | **Write:** transactions table, `op.audit_log`. **Read:** listings, `op.books`. |
| **Jobs (Oban)** | `Stacks.Workers.PaymentCallbackJob`, `Stacks.Workers.ShipmentTrackingJob`. |
| **External Services** | Stitch Money (payment), Pargo (shipping). |
| **dbt Models** | `mart_transaction_volume`, `mart_marketplace_revenue`. |
| **Infrastructure** | Webhook endpoints for payment/shipping providers. PCI considerations for payment flow. |
| **Dependencies** | US-7.1.1 (listings must exist). |

---

#### US-7.3.1 -- Seller Verification

| Dimension | Detail |
|-----------|--------|
| **Summary** | KYC and age verification required before listing books for sale. |
| **Phase** | Phase 5 (Marketplace) |

| Layer | Components |
|-------|------------|
| **Frontend (Elm)** | `Page.Marketplace.SellerOnboarding` -- KYC flow, age verification, terms acceptance. Reuses `Components.KYCWidget` from US-4.1.2. |
| **Backend (Phoenix)** | `Stacks.Marketplace.SellerVerification` -- extends `Stacks.Accounts.Verification`. Additional checks: identity + age + terms. |
| **Database** | **Write:** `op.audit_log`, seller verification status. |
| **Jobs (Oban)** | Reuses `KYCCallbackJob` from US-4.1.2. |
| **External Services** | Smile Identity / Yoti / Sumsub. |
| **dbt Models** | `int_seller_verification_funnel`. |
| **Infrastructure** | Same as US-4.1.2. |
| **Dependencies** | US-4.1.2 (age verification infrastructure). |

---

### 8. GDPR & Privacy

---

#### US-8.1.1 -- Export Personal Data

| Dimension | Detail |
|-----------|--------|
| **Summary** | User can export all personal data in JSON, CSV, or OPDS format. |
| **Phase** | Phase 2 (Enrichment) / Cross-cutting |

| Layer | Components |
|-------|------------|
| **Frontend (Elm)** | `Page.Settings.DataExport` -- format selector (JSON/CSV/OPDS), download button, progress indicator. |
| **Backend (Phoenix)** | `Stacks.GDPR.Export` -- `export_user_data/2`. Collects from all user-related tables. Serialisers for JSON, CSV, OPDS. `StacksWeb.GDPRController.export/2`. |
| **Database** | **Read:** All tables with user data: `op.books`, `op.shelves`, `op.shelf_placements`, `op.shelf_placement_history`, `op.my_writing_links`, `op.audit_log` (user's entries). |
| **Jobs (Oban)** | `Stacks.Workers.DataExportJob` -- async generation for large datasets. Notifies user when ready. |
| **External Services** | None. |
| **dbt Models** | None. |
| **Infrastructure** | Temporary file storage for export downloads. |
| **Dependencies** | US-8.1.3 (consent must be in place). |

---

#### US-8.1.2 -- Delete Account and Data

| Dimension | Detail |
|-----------|--------|
| **Summary** | Cascade delete all user data from operational DB. Anonymise records in warehouse. |
| **Phase** | Phase 2 (Enrichment) / Cross-cutting |

| Layer | Components |
|-------|------------|
| **Frontend (Elm)** | `Page.Settings.DeleteAccount` -- confirmation flow with typed confirmation phrase. Explains consequences. |
| **Backend (Phoenix)** | `Stacks.GDPR.Deletion` -- `delete_user_data/1`. Ecto.Multi transaction for cascade delete across op schema. Separate call to anonymise `wh` schema records. `StacksWeb.GDPRController.delete/2`. |
| **Database** | **Delete:** All user rows in `op.*`. **Update:** `wh.*` (anonymise user_id, hash PII). |
| **Jobs (Oban)** | `Stacks.Workers.AccountDeletionJob` -- async cascade + warehouse anonymisation. `Stacks.Workers.ConfirmDeletionJob` -- verification email before execution. |
| **External Services** | None. |
| **dbt Models** | `mart_gdpr_deletions` (tracking). |
| **Infrastructure** | None additional. |
| **Dependencies** | US-8.1.3 (consent), US-8.1.5 (audit log records deletion event). |

---

#### US-8.1.3 -- Consent Management

| Dimension | Detail |
|-----------|--------|
| **Summary** | Per-use consent with timestamps. User controls what data is collected and how it is used. |
| **Phase** | Phase 1 (MVP) / Cross-cutting |

| Layer | Components |
|-------|------------|
| **Frontend (Elm)** | `Page.Settings.Consent` -- toggle switches per consent category. `Components.ConsentBanner` -- first-visit consent collection. Timestamps displayed per consent. |
| **Backend (Phoenix)** | `Stacks.GDPR.Consent` -- `grant_consent/2`, `revoke_consent/2`, `check_consent/2`. Plug `StacksWeb.Plugs.ConsentCheck` for gating features on consent. |
| **Database** | **Write:** Consent records (user_id, consent_type, granted_at, revoked_at) in `op.audit_log` or dedicated consent table. |
| **Jobs (Oban)** | None. |
| **External Services** | None. |
| **dbt Models** | `mart_consent_status`. |
| **Infrastructure** | None additional. |
| **Dependencies** | None (foundational -- built first). |

---

#### US-8.1.4 -- Image Retention

| Dimension | Detail |
|-----------|--------|
| **Summary** | Uploaded images auto-deleted after 30 days. Only thumbnails retained permanently. |
| **Phase** | Phase 1 (MVP) / Cross-cutting |

| Layer | Components |
|-------|------------|
| **Frontend (Elm)** | Info text on upload page explaining retention policy. |
| **Backend (Phoenix)** | `Stacks.GDPR.ImageRetention` -- `cleanup_expired_images/0`. Generates thumbnail on upload, stores separately. |
| **Database** | **Write:** `op.uploaded_images` (delete originals, keep thumbnail_url). **Read:** `op.uploaded_images` (where uploaded_at < 30 days ago). |
| **Jobs (Oban)** | `Stacks.Workers.ImageRetentionJob` -- daily scheduled cleanup. |
| **External Services** | Object storage (Tigris / S3) -- delete original files. |
| **dbt Models** | `mart_image_retention_stats`. |
| **Infrastructure** | Object storage lifecycle policies as backup. |
| **Dependencies** | US-1.1.1 (images must be uploaded). |

---

#### US-8.1.5 -- Audit Logging

| Dimension | Detail |
|-----------|--------|
| **Summary** | Immutable append-only log. Hashed IPs. Encrypted metadata. |
| **Phase** | Phase 1 (MVP) / Cross-cutting |

| Layer | Components |
|-------|------------|
| **Frontend (Elm)** | None (backend-only). Admin view in US-5.1.1. |
| **Backend (Phoenix)** | `Stacks.Audit` context -- `Audit.log/3` (action, actor, metadata). IP hashing via `:crypto.hash(:sha256, ip)`. Metadata encryption via `Cloak` or similar. Append-only (no UPDATE/DELETE on audit_log). |
| **Database** | **Write:** `op.audit_log` (action, actor_hash, ip_hash, encrypted_metadata, inserted_at). Table has no UPDATE/DELETE grants for app role. |
| **Jobs (Oban)** | None (synchronous writes, or async via `Stacks.Workers.AuditLogJob` if performance requires). |
| **External Services** | None. |
| **dbt Models** | `stg_audit_log`, `mart_audit_summary`. |
| **Infrastructure** | Database role with INSERT-only permission on `audit_log`. Partition by month for performance. |
| **Dependencies** | None (foundational -- built first). |

---

### 9. Partner Integration

---

#### US-9.1.1 -- Register as a Partner

| Dimension | Detail |
|-----------|--------|
| **Summary** | Bookshops, reading groups, cafés register to push data to the platform. Owner approves. |
| **Phase** | Phase 3 (Partner Integration) |

| Layer | Components |
|-------|------------|
| **Frontend (Elm)** | `Page.Partner.Register` -- registration form (name, type, location, description, links). `Page.Metrics.PartnerRequests` -- owner approval UI as pinned index cards. |
| **Backend (Phoenix)** | `Stacks.Partners` context -- `register/1`, `approve/1`, `decline/1`, `suspend/1`. `StacksWeb.PartnerController.create/2`. API key generation on approval (32-byte random hex, Argon2 hash stored). Event emission: `partner.registered`, `partner.approved`. |
| **Database** | **Write:** `partners` (name, type, country_code, city, api_key_hash, status). **Write:** `audit_log`, `event_log`. |
| **Jobs (Oban)** | `Stacks.Workers.PartnerApprovalNotificationJob` -- notify partner on approval/decline. |
| **External Services** | None. |
| **dbt Models** | `stg_partners`, `int_partner_approval_rate`. |
| **Infrastructure** | Partner API rate limiter (separate tier: 100/min, 10k/day). |
| **Dependencies** | US-8.1.5 (audit logging). EDA infrastructure (event_log, emit/subscribe). |

---

#### US-9.1.2 -- Manage Partner API Keys

| Dimension | Detail |
|-----------|--------|
| **Summary** | Partners rotate or revoke their API keys from the partner dashboard. |
| **Phase** | Phase 3 (Partner Integration) |

| Layer | Components |
|-------|------------|
| **Frontend (Elm)** | `Page.Partner.Settings` -- key management panel showing prefix, created date, last used. "Rotate Key" with confirmation dialog. |
| **Backend (Phoenix)** | `Stacks.Partners.rotate_key/1` -- generates new key, hashes, invalidates old. `StacksWeb.PartnerSettingsController`. |
| **Database** | **Update:** `partners.api_key_hash`, `partners.api_key_prefix`. **Write:** `audit_log`. |
| **Jobs (Oban)** | None. |
| **External Services** | None. |
| **dbt Models** | None. |
| **Infrastructure** | None additional. |
| **Dependencies** | US-9.1.1 (partner exists). |

---

#### US-9.2.1 -- Push Book Inventory

| Dimension | Detail |
|-----------|--------|
| **Summary** | Partners push inventory (ISBN, price, condition, quantity) via API. Books with known ISBNs link immediately; unknown ISBNs queue for resolution. |
| **Phase** | Phase 3 (Partner Integration) |

| Layer | Components |
|-------|------------|
| **Frontend (Elm)** | Book detail view: `Components.PartnerAvailability` -- "Available at [Shop] for R149" sidebar section. Shelf view: green dot on spine for partner-stocked books. |
| **Backend (Phoenix)** | `Stacks.Partners.Inventory` context -- `sync/2` (upsert/remove). `StacksWeb.PartnerAPI.InventoryController`. Schema validation via Protobuf-generated JSON schema (`InventorySyncRequest`). Event emission: `inventory.updated`. ISBN resolution via existing `Stacks.Books.ISBNResolver` for unknown ISBNs. |
| **Database** | **Write:** `partner_inventory` (isbn, price_cents, currency, condition, quantity). **Read:** `books` (ISBN lookup). **Write:** `event_log`. |
| **Jobs (Oban)** | `Stacks.Workers.PartnerISBNResolveJob` -- resolve unknown ISBNs from partner inventory. Reuses existing ISBN pipeline. |
| **External Services** | Open Library, Google Books (for unknown ISBN resolution). |
| **dbt Models** | `stg_partner_inventory`, `int_partner_availability`, `mart_partner_stock_coverage`. |
| **Infrastructure** | Protobuf schema (`proto/stacks/partner/inventory.proto`). |
| **Dependencies** | US-9.1.1 (partner approved), US-9.6.2 (validation). US-1.1.1 (ISBN resolution pipeline). Protobuf schemas. |

---

#### US-9.2.2 -- Bulk Inventory Import via CSV

| Dimension | Detail |
|-----------|--------|
| **Summary** | Non-technical partners upload a CSV instead of using the API. Same ingest pipeline underneath. |
| **Phase** | Phase 3 (Partner Integration) |

| Layer | Components |
|-------|------------|
| **Frontend (Elm)** | `Page.Partner.InventoryImport` -- file upload area, template download link, preview table (matched/pending/invalid rows), confirm button. |
| **Backend (Phoenix)** | `Stacks.Partners.Inventory.CSVImport` -- parse, validate per-row, generate preview, then delegate to `sync/2` on confirmation. `StacksWeb.PartnerDashboard.InventoryController.import/2`. |
| **Database** | Same as US-9.2.1. |
| **Jobs (Oban)** | Same as US-9.2.1 (ISBN resolution for unknowns). |
| **External Services** | Same as US-9.2.1. |
| **dbt Models** | Same as US-9.2.1. |
| **Infrastructure** | None additional. |
| **Dependencies** | US-9.2.1 (same ingest pipeline). |

---

#### US-9.3.1 -- Push Events

| Dimension | Detail |
|-----------|--------|
| **Summary** | Partners push events (signings, meetups, launches) via API. Events appear on the Third Spaces cork board and optionally on book detail views (if ISBN-linked). |
| **Phase** | Phase 3 (Partner Integration) |

| Layer | Components |
|-------|------------|
| **Frontend (Elm)** | Third Spaces cork board: `Components.PartnerEventCard` -- hand-lettered flyer style. Book detail: "Upcoming event at [Shop]" in sidebar when ISBN matches. |
| **Backend (Phoenix)** | `Stacks.Partners.Events` context -- `create/2`, `update/2`, `cancel/1`. `StacksWeb.PartnerAPI.EventController`. Schema validation via Protobuf (`PartnerEvent`). Event emission: `event.created`. Auto-archive past events via scheduled job. |
| **Database** | **Write:** `partner_events` (title, event_type, event_date, location, related_isbns). **Write:** `event_log`. |
| **Jobs (Oban)** | `Stacks.Workers.ArchivePartnerEventsJob` -- scheduled daily, archives past events. |
| **External Services** | None. |
| **dbt Models** | `stg_partner_events`, `int_partner_event_calendar`. |
| **Infrastructure** | Protobuf schema (`proto/stacks/partner/events.proto`). |
| **Dependencies** | US-9.1.1 (partner approved), US-9.6.2 (validation). |

---

#### US-9.3.2 -- Manage Events via Dashboard

| Dimension | Detail |
|-----------|--------|
| **Summary** | Non-technical partners create and manage events through a web form. |
| **Phase** | Phase 3 (Partner Integration) |

| Layer | Components |
|-------|------------|
| **Frontend (Elm)** | `Page.Partner.Events` -- event list (upcoming/past/cancelled). `Page.Partner.EventForm` -- date picker, location, ISBN autocomplete, description. |
| **Backend (Phoenix)** | Same context as US-9.3.1, different controller: `StacksWeb.PartnerDashboard.EventController`. |
| **Database** | Same as US-9.3.1. |
| **Jobs (Oban)** | Same as US-9.3.1. |
| **External Services** | None. |
| **dbt Models** | Same as US-9.3.1. |
| **Infrastructure** | None additional. |
| **Dependencies** | US-9.3.1 (same storage). |

---

#### US-9.4.1 -- Register a Third Space

| Dimension | Detail |
|-----------|--------|
| **Summary** | Partners register their venue as a reader-friendly third space. Owner approves on first submission. |
| **Phase** | Phase 3 (Partner Integration) |

| Layer | Components |
|-------|------------|
| **Frontend (Elm)** | Third Spaces cork board: `Components.PartnerSpaceCard` -- vintage postcard style, distinct from user-submitted. Shows name, type, distance, amenities, outbound links. |
| **Backend (Phoenix)** | `Stacks.Partners.Spaces` context -- `register/2`, `update/2`. `StacksWeb.PartnerAPI.SpaceController`. Schema validation via Protobuf (`Space`). Event emission: `space.registered`. Owner approval for first submission. |
| **Database** | **Write:** `partner_spaces` (name, type, address, amenities, opening_hours, links). **Write:** `event_log`. |
| **Jobs (Oban)** | None. |
| **External Services** | None. |
| **dbt Models** | `stg_partner_spaces`. |
| **Infrastructure** | Protobuf schema (`proto/stacks/partner/spaces.proto`). |
| **Dependencies** | US-9.1.1 (partner approved), US-9.6.2 (validation). |

---

#### US-9.4.2 -- User-Submitted Third Spaces

| Dimension | Detail |
|-----------|--------|
| **Summary** | Readers suggest third spaces they've discovered. Community-submitted, visually distinct from partner-verified. |
| **Phase** | Phase 3 (Partner Integration) |

| Layer | Components |
|-------|------------|
| **Frontend (Elm)** | Third Spaces cork board: "Pin a new space" button. `Page.ThirdSpaces.SuggestForm` -- postcard-style form (name, type, city, link). `Components.CommunitySpaceCard` -- handwritten style, "suggested by a reader" note. |
| **Backend (Phoenix)** | `Stacks.ThirdSpaces.suggest/2` -- creates a `third_spaces` record with `verified: false`, `discovered_via: 'user_submission'`. Owner approval required. |
| **Database** | **Write:** `third_spaces` (reuses existing table with `discovered_via = 'user_submission'`). **Write:** `audit_log`. |
| **Jobs (Oban)** | None. |
| **External Services** | None. |
| **dbt Models** | Reuses `stg_third_spaces`. |
| **Infrastructure** | None additional. |
| **Dependencies** | US-3.1.1 (Third Spaces cork board exists). |

---

#### US-9.5.1 -- View Partner Engagement Metrics

| Dimension | Detail |
|-----------|--------|
| **Summary** | Partners see aggregate, anonymised engagement data (impressions, clicks). Counts rounded to nearest 10. |
| **Phase** | Phase 3 (Partner Integration) |

| Layer | Components |
|-------|------------|
| **Frontend (Elm)** | `Page.Partner.Metrics` -- counters with 30-day sparklines. Inventory impressions, event views, space card views, outbound link clicks. |
| **Backend (Phoenix)** | `Stacks.Partners.Metrics` context -- aggregate queries on `event_log` filtered by partner. Counts rounded to nearest 10. `StacksWeb.PartnerAPI.MetricsController`. `StacksWeb.PartnerDashboard.MetricsController`. |
| **Database** | **Read:** `event_log` (filtered by aggregate_id matching partner's content). `partner_inventory`, `partner_events`, `partner_spaces`. |
| **Jobs (Oban)** | `Stacks.Workers.PartnerMetricsSnapshotJob` -- scheduled daily, pre-aggregates metrics for dashboard performance. |
| **External Services** | None. |
| **dbt Models** | `int_partner_impressions`, `int_partner_clicks`, `mart_partner_engagement`. |
| **Infrastructure** | None additional. |
| **Dependencies** | US-9.2.1, US-9.3.1, US-9.4.1 (content must exist). EDA (event_log for impression tracking). |

---

#### US-9.6.1 -- Platform Owner Reviews Partner Content

| Dimension | Detail |
|-----------|--------|
| **Summary** | Owner approves/declines partner registrations and can flag/suspend partner content. |
| **Phase** | Phase 3 (Partner Integration) |

| Layer | Components |
|-------|------------|
| **Frontend (Elm)** | `Page.Metrics.PartnerManagement` -- partner table (name, type, status, content count, last sync). Approval queue as index cards. Content moderation queue for flagged items. |
| **Backend (Phoenix)** | `Stacks.Partners.approve/1`, `decline/2`, `suspend/1`, `reinstate/1`. `Stacks.Partners.Content.flag/2`, `remove/2`. Suspension hides all content and rejects API calls. |
| **Database** | **Update:** `partners.status`. **Update:** `partner_events`, `partner_spaces` (flag/remove). **Write:** `audit_log`. |
| **Jobs (Oban)** | None (synchronous actions). |
| **External Services** | None. |
| **dbt Models** | `int_partner_moderation`. |
| **Infrastructure** | None additional. |
| **Dependencies** | US-9.1.1 (partners exist). US-5.1.1 (Metrics Dashboard as host page). |

---

#### US-9.6.2 -- Automated Partner Content Validation

| Dimension | Detail |
|-----------|--------|
| **Summary** | All partner payloads auto-validated before reaching the platform. Schema validation, ISBN checks, text blocklist, date validation. |
| **Phase** | Phase 3 (Partner Integration) |

| Layer | Components |
|-------|------------|
| **Frontend (Elm)** | None (API-level). Partner dashboard shows validation errors on CSV import. |
| **Backend (Phoenix)** | `StacksWeb.Plugs.SchemaValidation` -- validates request body against Protobuf-generated JSON schema. `Stacks.Partners.Validation` -- ISBN checksum, positive price, future date, text blocklist, URL domain check. Returns structured `ValidationError` list. |
| **Database** | **Read:** `partners` (status check). |
| **Jobs (Oban)** | None (synchronous validation). |
| **External Services** | None. |
| **dbt Models** | `int_partner_validation_errors` (tracking rejection patterns). |
| **Infrastructure** | Protobuf schemas (all partner `.proto` files). `buf lint` in CI. |
| **Dependencies** | Protobuf schema contracts. |

---

#### US-9.7.1 -- Partner Registration Status

| Dimension | Detail |
|-----------|--------|
| **Summary** | Partners check registration status via a link from their confirmation email. Shows Pending/Changes Requested/Approved/Declined with appropriate next steps. |
| **Phase** | Phase 3 (Partner Integration) |

| Layer | Components |
|-------|------------|
| **Frontend (Elm)** | `Page.Partner.Status` -- progress tracker (Applied → Under Review → Approved/Declined). `Components.OwnerNotes` callout for change requests. Editable resubmission form when changes requested. Welcome card on approval with dashboard/API setup CTAs. |
| **Backend (Phoenix)** | `Stacks.Partners.get_status/1` -- returns partner record with status + owner notes. `Stacks.Partners.resubmit/2` -- updates partner, resets status to pending. `StacksWeb.PartnerStatusController`. Token-based access (no login required — link from email). |
| **Database** | **Read:** `partners` (status, owner_notes). **Write:** `partners` (on resubmit). `audit_log`. |
| **Jobs (Oban)** | None (email sent by `PartnerApprovalNotificationJob` from US-9.1.1). |
| **External Services** | Resend / Postmark (confirmation email with status link). |
| **dbt Models** | `int_partner_onboarding_funnel`. |
| **Infrastructure** | Token-based URL for status checking (signed, time-limited). |
| **Dependencies** | US-9.1.1 (partner registration). |

---

#### US-9.7.2 -- Partner Profile Self-Service Update

| Dimension | Detail |
|-----------|--------|
| **Summary** | Partners update their business details from the dashboard. Non-sensitive changes take effect immediately; name/address changes require owner re-approval. |
| **Phase** | Phase 3 (Partner Integration) |

| Layer | Components |
|-------|------------|
| **Frontend (Elm)** | `Page.Partner.Profile` -- form with current values, live preview of partner card (as shown on Third Spaces and book detail). "Pending Approval" badge on fields requiring re-approval. |
| **Backend (Phoenix)** | `Stacks.Partners.update_profile/2` -- partitions fields into immediate-effect (description, hours, website, logo) and approval-required (name, address). Approval-required changes create a pending update visible to owner. `StacksWeb.PartnerDashboard.ProfileController`. |
| **Database** | **Write:** `partners` (immediate fields). `partners` pending fields stored separately (JSONB `pending_changes` column or separate table). `audit_log`. |
| **Jobs (Oban)** | None. |
| **External Services** | None. |
| **dbt Models** | None. |
| **Infrastructure** | None additional. |
| **Dependencies** | US-9.1.1 (partner exists), US-9.6.1 (owner approves name/address changes). |

---

#### US-9.8.1 -- Partner Availability on Book Detail

| Dimension | Detail |
|-----------|--------|
| **Summary** | Readers see which local partners stock a book. "Available at" section on book detail; green dot on spine in shelf views. |
| **Phase** | Phase 3 (Partner Integration) |

| Layer | Components |
|-------|------------|
| **Frontend (Elm)** | `Components.PartnerAvailability` on `Page.BookDetail` -- partner cards (logo, name, price, condition badge). `Components.Spine` -- green dot indicator when `partner_availability` is non-empty. Sort by proximity (if location set) or alphabetically. Section hidden when no partners stock the book. |
| **Backend (Phoenix)** | `Stacks.Partners.Inventory.available_for/1` -- queries `partner_inventory` by ISBN, joins `partners` for display data. Included in `Stacks.Books.get_book_detail/1` response. |
| **Database** | **Read:** `partner_inventory` (by ISBN), `partners` (name, logo, type). |
| **Jobs (Oban)** | None (data populated by US-9.2.1 ingest). |
| **External Services** | None. |
| **dbt Models** | `int_partner_availability` (reuses model from US-9.2.1). |
| **Infrastructure** | None additional. |
| **Dependencies** | US-9.2.1 (partner inventory exists), US-1.3.2 (book detail page). |

---

### Cross-cutting: Event-Driven Architecture

| Layer | Components |
|-------|------------|
| **Summary** | Oban-backed event bus. All significant state changes emit events to `event_log` table. Subscribers are registered at startup and notified via Oban jobs. |
| **Affects stories** | All stories benefit. Primary consumers: US-9.2.1 (inventory events), US-9.3.1 (event events), US-9.5.1 (metrics from events), US-1.5.1 (shelf movement events), US-2.1.1–2.4.1 (enrichment fan-out). |
| **Backend (Phoenix)** | `Stacks.Events` -- `emit/1`, `replay/3`. `Stacks.Events.Registry` -- subscriber mapping. `Stacks.Events.Upcaster` -- schema version migration. `Stacks.Events.SubscriberWorker` -- Oban worker that dispatches to subscriber modules. |
| **Database** | `event_log` table (event_type, aggregate_type, aggregate_id, schema_version, payload JSONB, metadata JSONB, occurred_at, published_at). Index on (event_type, aggregate_id, occurred_at DESC). |
| **dbt Models** | `stg_event_log`, `int_event_throughput`, `mart_event_bus_health`. |
| **Infrastructure** | Oban queue `:events` with concurrency tuned to subscriber count. |

### Cross-cutting: Schema Contracts (Protobuf)

| Layer | Components |
|-------|------------|
| **Summary** | `.proto` files as single source of truth for all structured data contracts. `buf` for linting and breaking change detection in CI. JSON on the wire. |
| **Affects stories** | All partner stories (US-9.x), internal event bus, service-to-service contracts. |
| **Proto files** | `proto/stacks/partner/` (inventory, events, spaces), `proto/stacks/internal/` (event_bus, enrichment), `proto/stacks/common/` (book, location). |
| **Code generation** | Elixir, Rust, Python: generated at build time, gitignored. Elm: generated JSON decoders checked in (no runtime codegen). |
| **CI** | `buf lint proto/` + `buf breaking proto/ --against '.git#branch=main'` in every PR. |
| **Event upcasting** | `Stacks.Events.Upcaster` -- pattern-matched version transforms for old events. Same pattern as Commanded (Elixir CQRS). |

---

## Quick Reference: Table-to-Story Mapping

Which user stories touch each database table:

| Table | Stories |
|-------|---------|
| `books` | US-1.1.1, US-1.1.2, US-1.1.4, US-1.1.5, US-1.1.6, US-1.2.1--4, US-1.3.1, US-1.3.2, US-1.4.1, US-1.5.1--4, US-2.1.1, US-2.2.1, US-2.3.1, US-2.4.1, US-4.1.1, US-7.1.1, US-7.2.1, US-8.1.1 |
| `authors` | US-1.1.1, US-1.2.1--4, US-1.3.2, US-1.4.1, US-2.3.1, US-2.4.1, US-6.1.1, US-8.1.1 |
| `shelves` | US-1.2.1--5, US-1.4.1, US-1.5.1, US-6.1.1, US-8.1.1 |
| `shelf_placements` | US-1.1.5, US-1.2.1--4, US-1.3.1, US-1.3.2, US-1.4.1, US-1.5.1--3, US-1.6.4, US-1.6.5, US-2.4.1, US-6.1.1, US-8.1.1 |
| `shelf_placement_history` | US-1.3.1, US-1.5.1--3, US-1.6.4, US-8.1.1 |
| `review_snapshots` | US-1.3.2, US-2.1.1 |
| `price_snapshots` | US-1.3.2, US-1.4.1, US-2.2.1 |
| `bookstores` | US-2.2.1, US-2.2.2, US-2.4.1 |
| `bookstore_events` | US-2.4.1 |
| `third_spaces` | US-3.1.1 |
| `third_space_events` | US-3.1.1 |
| `my_writing_links` | US-1.3.1, US-1.3.2, US-8.1.1 |
| `uploaded_images` | US-1.1.1, US-7.1.1, US-8.1.4 |
| `audit_log` | US-1.1.3, US-1.1.4, US-2.5.1, US-4.1.1, US-4.1.2, US-5.1.1, US-7.2.1, US-7.3.1, US-8.1.1, US-8.1.2, US-8.1.3, US-8.1.5 |
| `discovered_sources` | US-2.3.1, US-2.5.1 |
| `partners` | US-9.1.1, US-9.1.2, US-9.6.1, US-9.7.1, US-9.7.2, US-9.8.1 |
| `partner_inventory` | US-9.2.1, US-9.2.2, US-9.5.1, US-9.8.1 |
| `partner_events` | US-9.3.1, US-9.3.2, US-9.5.1, US-9.6.1 |
| `partner_spaces` | US-9.4.1, US-9.5.1, US-9.6.1 |
| `event_log` | US-9.2.1, US-9.3.1, US-9.4.1, US-9.5.1 (+ all stories via EDA) |
| `listings` | US-7.1.1, US-7.2.1 |
| `offers` | US-7.2.1 |
| `transactions` | US-7.2.1 |

---

## Quick Reference: Oban Job Inventory

| Job Worker | Triggered By | Schedule |
|------------|-------------|----------|
| `IdentifyBookJob` | US-1.1.1 (photo upload) | On-demand |
| `EnrichBookJob` | US-1.1.1 (after ISBN resolved) | On-demand |
| `RecalculateWearJob` | US-1.5.1, US-1.5.2, US-1.5.3 (shelf moves) | Event-driven |
| `FetchReviewsJob` | US-2.1.1 | Adaptive staleness (hours to days) |
| `TriggerPriceScrapeJob` | US-2.2.1 | Scheduled (daily) |
| `DiscoverAuthorSourcesJob` | US-2.3.1 | Scheduled (weekly) |
| `FetchAuthorRSSJob` | US-2.3.1 | Scheduled (hourly) |
| `DiscoverBookstoreEventsJob` | US-2.4.1 | Scheduled (daily) |
| `SourceDiscoveryJob` | US-2.5.1 | Scheduled (daily) |
| `ScoreSourceJob` | US-2.5.1 | On-demand (after discovery) |
| `DiscoverThirdSpacesJob` | US-3.1.1 | Scheduled (weekly) |
| `ModerationPipelineJob` | US-4.1.1 | On-demand (part of upload) |
| `KYCCallbackJob` | US-4.1.2, US-7.3.1 | Webhook-driven |
| `MetricsSnapshotJob` | US-5.1.1 | Scheduled (every 5 min) |
| `RegenerateFeedJob` | US-6.1.1 | Event-driven (shelf change) |
| `ListingExpiryJob` | US-7.1.1 | Scheduled (daily) |
| `PaymentCallbackJob` | US-7.2.1 | Webhook-driven |
| `ShipmentTrackingJob` | US-7.2.1 | Scheduled (hourly) |
| `DataExportJob` | US-8.1.1 | On-demand |
| `AccountDeletionJob` | US-8.1.2 | On-demand |
| `ConfirmDeletionJob` | US-8.1.2 | On-demand |
| `ImageRetentionJob` | US-8.1.4 | Scheduled (daily) |
| `PartnerApprovalNotificationJob` | US-9.1.1 | Event-driven (partner.approved/declined) |
| `PartnerISBNResolveJob` | US-9.2.1, US-9.2.2 | Event-driven (unknown ISBN in partner inventory) |
| `ArchivePartnerEventsJob` | US-9.3.1 | Scheduled (daily) |
| `PartnerMetricsSnapshotJob` | US-9.5.1 | Scheduled (daily) |
| `EventSubscriberWorker` | EDA (cross-cutting) | Event-driven (dispatches to subscriber modules) |

---

## Quick Reference: External API Usage

| API / Service | Stories | Purpose |
|---------------|---------|---------|
| Modal | US-1.1.1, US-1.1.3, US-4.1.1 | Vision model (book identification, classification via Qwen2.5-VL-7B) |
| Open Library | US-1.1.1, US-1.1.2, US-4.1.1 | ISBN resolution, book metadata |
| Google Books | US-1.1.1, US-1.1.2, US-4.1.1 | ISBN resolution fallback, metadata |
| Brave Search | US-2.3.1, US-2.4.1, US-2.5.1, US-3.1.1 | Source discovery, author search, event search |
| SearXNG (self-hosted) | US-2.4.1, US-2.5.1, US-3.1.1 | Meta-search for discovery |
| GoodReads | US-2.1.1 | Review aggregation |
| Reddit API | US-2.1.1 | Review aggregation |
| Storygraph | US-2.1.1 | Review aggregation |
| Smile Identity / Yoti / Sumsub | US-4.1.2, US-7.3.1 | KYC / age verification |
| Stitch Money | US-7.2.1 | Payment processing |
| Pargo | US-7.2.1 | Shipping / logistics |
| Resend / Postmark | US-8.1.2, US-9.1.1, US-9.7.1 | Transactional email (GDPR confirmation, partner notifications, status updates) |

---

## Quick Reference: dbt Model Inventory

| Model | Type | Fed By Stories | Consumed By Stories |
|-------|------|---------------|-------------------|
| `stg_books` | Staging | US-1.1.1 | Many |
| `stg_uploaded_images` | Staging | US-1.1.1 | US-8.1.4 |
| `stg_shelf_placements` | Staging | US-1.5.1--3 | US-1.2.1--4 |
| `stg_shelf_placement_history` | Staging | US-1.5.1--3 | US-1.3.1 |
| `stg_review_snapshots` | Staging | US-2.1.1 | US-1.3.2 |
| `stg_price_snapshots` | Staging | US-2.2.1 | US-1.3.2 |
| `stg_authors` | Staging | US-1.1.1 | US-2.3.1 |
| `stg_bookstore_events` | Staging | US-2.4.1 | US-2.4.1 |
| `stg_discovered_sources` | Staging | US-2.5.1 | US-2.5.1 |
| `stg_third_spaces` | Staging | US-3.1.1 | US-3.1.1 |
| `stg_audit_log` | Staging | US-8.1.5 | US-5.1.1 |
| `int_book_engagement` | Intermediate | US-1.3.1, US-1.5.1--3 | US-1.3.1 |
| `int_book_detail_view` | Intermediate | Multiple | US-1.3.2 |
| `int_upload_rejection_rate` | Intermediate | US-1.1.2, US-1.1.3 | US-5.1.1 |
| `int_rejection_categories` | Intermediate | US-1.1.3 | US-5.1.1 |
| `int_content_classification` | Intermediate | US-1.1.4 | US-5.1.1 |
| `int_shelf_composition` | Intermediate | US-1.2.1--4 | US-5.1.1 |
| `int_book_journey` | Intermediate | US-1.5.1 | US-5.1.1 |
| `int_abandonment_rate` | Intermediate | US-1.5.2 | US-5.1.1 |
| `int_format_distribution` | Intermediate | US-1.5.4 | US-5.1.1 |
| `int_review_sentiment` | Intermediate | US-2.1.1 | US-2.1.1 |
| `int_price_trends` | Intermediate | US-2.2.1 | US-2.2.1 |
| `int_author_activity` | Intermediate | US-2.3.1 | US-2.3.1 |
| `int_event_matches` | Intermediate | US-2.4.1 | US-2.4.1 |
| `int_source_approval_rate` | Intermediate | US-2.5.1 | US-5.1.1 |
| `int_moderation_outcomes` | Intermediate | US-4.1.1 | US-5.1.1 |
| `int_seller_verification_funnel` | Intermediate | US-7.3.1 | US-5.1.1 |
| `mart_book_reviews` | Mart | US-2.1.1 | US-1.3.2 |
| `mart_book_prices` | Mart | US-2.2.1 | US-1.3.2 |
| `mart_system_health` | Mart | Multiple | US-5.1.1 |
| `mart_job_stats` | Mart | Multiple | US-5.1.1 |
| `mart_data_freshness` | Mart | Multiple | US-5.1.1 |
| `mart_cost_tracking` | Mart | Multiple | US-5.1.1 |
| `mart_gdpr_compliance` | Mart | US-8.1.1--5 | US-5.1.1 |
| `mart_gdpr_deletions` | Mart | US-8.1.2 | US-5.1.1 |
| `mart_consent_status` | Mart | US-8.1.3 | US-5.1.1 |
| `mart_image_retention_stats` | Mart | US-8.1.4 | US-5.1.1 |
| `mart_audit_summary` | Mart | US-8.1.5 | US-5.1.1 |
| `mart_marketplace_activity` | Mart | US-7.1.1 | US-5.1.1 |
| `mart_transaction_volume` | Mart | US-7.2.1 | US-5.1.1 |
| `mart_marketplace_revenue` | Mart | US-7.2.1 | US-5.1.1 |
| `stg_partners` | Staging | US-9.1.1 | US-9.5.1, US-9.6.1 |
| `stg_partner_inventory` | Staging | US-9.2.1, US-9.2.2 | US-9.5.1 |
| `stg_partner_events` | Staging | US-9.3.1, US-9.3.2 | US-9.5.1 |
| `stg_partner_spaces` | Staging | US-9.4.1 | US-9.5.1 |
| `stg_event_log` | Staging | EDA (cross-cutting) | US-9.5.1, US-5.1.1 |
| `int_partner_availability` | Intermediate | US-9.2.1 | US-1.3.2 (book detail sidebar) |
| `int_partner_approval_rate` | Intermediate | US-9.1.1 | US-5.1.1 |
| `int_partner_event_calendar` | Intermediate | US-9.3.1 | US-3.1.1 (cork board) |
| `int_partner_impressions` | Intermediate | US-9.5.1 | US-9.5.1 |
| `int_partner_clicks` | Intermediate | US-9.5.1 | US-9.5.1 |
| `int_partner_validation_errors` | Intermediate | US-9.6.2 | US-5.1.1 |
| `int_partner_moderation` | Intermediate | US-9.6.1 | US-5.1.1 |
| `int_event_throughput` | Intermediate | EDA (cross-cutting) | US-5.1.1 |
| `mart_partner_engagement` | Mart | US-9.5.1 | US-9.5.1 |
| `mart_partner_stock_coverage` | Mart | US-9.2.1 | US-5.1.1 |
| `mart_event_bus_health` | Mart | EDA (cross-cutting) | US-5.1.1 |
| `stg_users` | Staging | US-10.1.1, US-11.1.1 | US-10.x, US-11.x |
| `stg_user_blocks` | Staging | US-11.2.1 | US-10.x, US-11.x |
| `stg_groups` | Staging | US-11.1.1 | US-11.1.x |
| `stg_group_members` | Staging | US-11.1.2 | US-11.1.x |
| `stg_bookshelves` | Staging | US-10.1.1 | US-10.x |
| `stg_blog_posts` | Staging | US-12.1.1 | US-12.x, US-13.x |
| `stg_comments` | Staging | US-13.1.1 | US-13.x |
| `stg_offer_threads` | Staging | US-7.1.1, US-13.2.2 | US-7.x |
| `stg_post_book_associations` | Staging | US-12.2.1 | US-12.2.1 |
| `int_visibility_resolution` | Intermediate | US-10.1.1--5 | US-10.x, US-12.x, US-13.x |
| `int_comment_threads` | Intermediate | US-13.1.1 | US-13.1.1 |
| `int_offer_activity` | Intermediate | US-7.1.1, US-13.2.2 | US-5.1.1 |
| `int_blog_engagement` | Intermediate | US-12.1.1 | US-5.1.1 |
| `int_group_activity` | Intermediate | US-11.1.1 | US-5.1.1 |
| `mart_social_graph_health` | Mart | US-11.x | US-5.1.1 |
| `mart_blog_activity` | Mart | US-12.x | US-5.1.1 |
| `mart_marketplace_offers` | Mart | US-7.1.1, US-13.2.2 | US-5.1.1 |
