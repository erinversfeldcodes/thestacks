# The Stacks -- Implementation Mapping

> **Purpose:** Map every user story to the specific technical components required to implement it. This document is the bridge between _what the user experiences_ and _how the system delivers it_.
>
> **Last updated:** 2026-03-17
>
> **Note on story numbering:** This document uses a sub-numbered scheme (e.g., US-1.3.2 for Book Detail, US-1.4.1 for Search, US-1.5.x for shelf movements, US-8.1.x for GDPR) that was established before the user stories document (`docs/user-stories.md`) was reorganised. The user stories doc now uses US-1.4.1 for Book Detail, US-1.5.x for Search, US-1.6.x for the reading journey, and US-8.x (without the `.1` sub-level) for GDPR. Both documents refer to the same features; the mapping here is authoritative for implementation details.
>
> **Data model note (v1.5):** As of 2026-03-17, the `books` table represents **works** (logical books), not editions. A new `book_editions` table holds ISBNs, formats, and edition-specific metadata. The ISBN hard gate is enforced at `book_editions.isbn`. Shelf placements, reviews, and blog associations reference works; price snapshots and partner inventory reference editions. See `docs/technical-architecture.md` section 7 for the full schema.

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
   - [7. Marketplace (Classifieds)](#7-marketplace-classifieds)
   - [8. GDPR & Privacy](#8-gdpr--privacy)
   - [9. Partner Integration](#9-partner-integration)
   - [10. Visibility & Privacy](#10-visibility--privacy)
   - [11. Groups](#11-groups)
   - [12. Blog & Writing](#12-blog--writing)
   - [13. Comments & Offers](#13-comments--offers)
   - [14. Authentication](#14-authentication)
   - [15. Home & Navigation](#15-home--navigation)
   - [16. Error Handling](#16-error-handling)
   - [17. Settings](#17-settings)
   - [18. Looking for a Home Shelf](#18-looking-for-a-home-shelf)
   - [19. Accessibility](#19-accessibility)

---

## Implementation Phases

| Phase | Name | Stories | Rationale |
|-------|------|---------|-----------|
| **Phase 1** | MVP | US-1.1.1, US-1.1.2, US-1.1.3, US-1.1.5, US-1.1.6, US-1.1.7, US-1.1.8, US-1.2.1, US-1.2.2, US-1.2.3, US-1.2.4, US-1.2.5, US-1.3.1, US-1.3.2, US-1.4.1, US-1.5.1, US-1.5.2, US-1.5.3, US-1.5.4, US-1.6.1, US-1.6.2, US-1.6.3, US-1.6.4, US-1.6.5, US-1.6.6, US-1.7.1, US-1.1.9, US-1.5.5 | The core loop: upload photo(s), identify book(s), verify ("We think this is…"), place on shelf, browse and manage. Includes multi-format merge (US-1.1.8), importing an existing Goodreads library through the ISBN gate (US-1.1.9), and browsing the full catalogue (US-1.5.5). Everything a single user needs to start using The Stacks. |
| **Phase 2** | Enrichment | US-2.1.1, US-2.2.1, US-2.2.2, US-2.3.1, US-2.4.1, US-2.5.1, US-2.5.2, US-2.5.3, US-2.6.1 | Layer intelligence on top of the book graph: reviews, prices, author info, events, source discovery, geographic sweep (US-2.5.2), automatic edition discovery (US-2.6.1), and business opt-out (US-2.5.3). |
| **Phase 3** | Partner Integration | US-9.1.1, US-9.1.2, US-9.2.1, US-9.2.2, US-9.3.1, US-9.3.2, US-9.4.1, US-9.4.2, US-9.5.1, US-9.6.1, US-9.6.2, US-9.7.1, US-9.7.2, US-9.8.1 | Inbound partner API, dashboard, CSV import. Depends on Third Spaces cork board and ISBN resolution from Phases 1–2. EDA and Protobuf land here as cross-cutting infrastructure. |
| **Phase 4** | Polish | US-3.1.1, ~~US-5.1.1~~, US-6.1.1 | Community features (Third Spaces scraping), operational visibility (~~in-app Metrics dashboard — **superseded by Grafana, #267**~~; ops-metrics surface is now the Grafana observability stack, ADR-021/#236–240), and sharing (RSS/OPDS). |
| **Phase 5** | Marketplace (Classifieds) | US-7.1, US-7.2, US-7.3, US-13.2.1, US-13.2.2 | Classifieds board (see [ADR 013](decisions/013-marketplace-classifieds-first.md)). US-7.1.1 (listings + state machine + expiry) is implemented. Payments (#054b), shipping (#054c), offer threads, and seller KYC are deferred. |
| **Phase 6** | Social Graph & Visibility | US-10.1.1, US-10.1.2, US-10.2.1, US-10.2.2, US-10.2.3, US-10.3.1, US-10.4.1, US-10.5.1, US-10.5.2, US-10.5.3, US-10.5.4, US-11.1.1, US-11.1.2, US-11.1.3, US-11.1.4, US-11.1.5 | Profile visibility, shelf/placement/post visibility, ceiling rule enforcement, view-as mode, user blocks, public handles/profiles (US-10.5.x), groups, and group content feeds (US-11.1.5). Requires `resolve_visibility/2` context and `ViewAsPlug`. |
| **Phase 7** | Blog & Comments | US-12.1.1, US-12.1.2, US-12.1.3, US-12.2.1, US-12.2.2, US-13.1.1, US-13.1.2, US-6.2.1 | Native blog posts, LLM book associations via `PostBookAssociationWorker`, the writing assistant (US-12.2.x), threaded comments with block filtering, and POSSE syndication of posts to Substack (US-6.2.1). Requires Phase 6 visibility infrastructure. |
| **Phase 1 (extended)** | Auth, Navigation, Errors, Settings | US-14.1.1, US-14.1.2, US-14.1.3, US-14.2.1, US-14.3.1, US-14.3.2, US-14.3.3, US-14.4.1, US-14.4.2, US-15.1.1, US-15.2.1, US-15.2.2, US-15.3.1, US-15.4.1, US-15.5.1, US-16.1.1, US-16.2.1, US-16.3.1, US-17.1.1, US-17.2.1, US-17.2.2, US-17.2.3, US-17.3.1, US-18.1.1, US-19.1.1, US-19.1.2, US-19.2.1 | Authentication (including onboarding US-14.1.2), home page, global navigation with user menu dropdown (US-14.3.3), error handling, settings hub (US-17.1.1) with profile (US-17.2.1), location (US-17.2.2), password (US-17.2.3), notifications (US-17.3.1), the fifth bookshelf with community wear (US-18.1.1), invite-only registration for the closed beta (US-14.1.3), password reset (US-14.4.1/US-14.4.2), a platform FAQ (US-15.4.1) and beta feedback channel (US-15.5.1), and accessibility (US-19.x). |
| **Cross-cutting** | GDPR, Moderation, Age, EDA | US-4.1, US-4.2, US-8.1, US-8.2, US-8.3, US-8.4, US-8.5, US-8.6, US-14.5.1, US-20.1.1, US-20.2.1 | Built incrementally across all phases. Moderation pipeline ships with Phase 1; GDPR primitives land in Phase 1 and mature through Phase 3. Event bus (Oban) and Protobuf schema contracts land in Phase 3. Phases 6–7 add new GDPR-covered entities: `blog_posts`, `comments`, `listings`, `groups`, `user_blocks`. `offer_threads` and `offer_messages` tables exist but are unused (see [ADR 013](decisions/013-marketplace-classifieds-first.md)). Also spans data insights/transparency (US-8.6), 24-hour erasure of unconfirmed accounts (US-14.5.1), and the admin/owner surfaces — MFA-gated admin access (US-20.1.1) and owner-only data corrections such as edition un-merge (US-20.2.1). |

### Additional Features Under Consideration (per phase)

> Forward-looking product-design directions being weighed for each phase — not yet
> committed scope. Detailed working notes are maintainer-local (`notes/`, gitignored);
> committed design docs are linked where they exist. Each should get a short design
> pass / ADR before it enters a phase's scope.

**Phase 2 (Enrichment).** Semantic retrieval / RAG over the book graph (pgvector — the
embeddings foundation is landing now) for "similar books / what to read next" and review
aggregation; an LLM-output **eval + faithfulness** harness (the panel already specced in
[`data-quality.md`](data-quality.md)) as the gate for every AI-shaped feature downstream;
the data-engineering **training-corpus** foundation (per-record provenance/lineage,
versioned + consent-gated dataset snapshots — see [`data-licensing-program.md`](data-licensing-program.md));
and **anti-scraping** protection for public content. Detail: `notes/product-ideas.md`.

**Phase 3 (Partner Integration).** Proto-generated **client SDKs** (the partner SDK is the
natural first one — codegen, not hand-written); a **public MCP server** for third-party
integration layered on the event bus (writes flow through `Events.emit`; events → MCP
subscriptions); and a partner dashboard as a distinct frontend surface. Detail:
`notes/product-ideas.md`.

**Phase 4 (Polish).** Distributed-tracing **observability** (OpenTelemetry across
Elixir ↔ scraper ↔ external) extending the Metrics work; **A/B testing / feature-flag**
infrastructure (also a safe-rollout mechanism, complementing the deploy rollback work);
and native integrations with external analytics/sharing tools. Detail: `notes/product-ideas.md`.

**Phase 5 (Marketplace).** Deeper **billing / metering / revenue-reporting** as
first-class systems (also the spine for the data-licensing revenue-share); **fraud / abuse
detection** on listings; and the currently-deferred payments, shipping, and seller KYC
(#054b / #054c / #069). Detail: `notes/product-ideas.md`.

**Phase 6 (Social Graph & Visibility).** **Real-time collaborative editing** for blog
co-authoring (CRDT/OT over Phoenix Channels — including the editor-vs-co-author role
distinction); privacy engineered structurally (the visibility ceiling + RLS + the
`gdpr-review` gate); and an **anti-scraping / consent policy** for public user content
(per-user, per-visibility — honors opt-in indexing, tarpits bad actors). Detail:
`notes/product-ideas.md`.

**Phase 7 (Blog & Comments).** The writing assistant's **custom training on a private
expert corpus** (RAG for content + light LoRA adaptation on derived data, under a hard
no-leak / revocable-consent constraint — see [`writing-assistant-design.md`](writing-assistant-design.md)
and `notes/product-ideas.md`); **streaming LLM UX** (token streaming, citations,
confidence); **LLM guardrails / red-teaming** on generated content and comments; **POSSE**
cross-post syndication of blog posts; and the **non-ISBN / Readable generalization**
(papers, articles, video as first-class knowledge sources — warrants its own ADR, as it
touches the ISBN hard gate). Detail: `notes/product-ideas.md`.

**Cross-cutting (all phases).** A **mobile** story (genuinely responsive web + eventual
native iOS/Android, anchored on the camera capture loop); reusable SDKs; and continued
**correctness / deterministic-simulation testing** of the risky lifecycles (auth, events,
deploy). Detail: `notes/product-ideas.md`.

### Deliberate exclusions — features we decided NOT to build

Absence in a roadmap reads as oversight unless someone writes down that it was a
choice. These are choices. Each names the ruling that made it, so a future reader
can reopen the decision rather than rediscover the gap.

| Not built | Ruling | Why, and what stands instead |
|---|---|---|
| **Cancel-deletion grace period** — a window after "delete my account" in which the user can change their mind | Owner, 2026-07-30 (Wave 7 of `plans/staff-campaign-2026-07-30.md`; recorded by #376) | **Immediate erasure stays.** A grace period means the data still exists after the person asked for it to be gone, which is the opposite of what they asked for, and it turns a one-shot operation into a scheduled state that has to be defended against every other write path for the length of the window. The confirmation flow is where doubt belongs: the delete flow on `Page.Settings.Privacy` already requires a typed confirmation phrase, and `ConfirmDeletionJob` sends a verification email before anything executes. Two deliberate gates in front, none behind. See US-8.1.2. |
| **User-facing "delete this photo"** — a public control for removing an uploaded image before its retention window expires | Owner, 2026-07-30 (same ruling) | **Excluded publicly**, not excluded outright. Automatic deletion at 30 days (US-8.1.4, `ImageRetentionJob`) is the guarantee we make, and a manual button is a second, weaker path to the same outcome that would need its own authorisation, its own audit, and its own R2 reconciliation. What the ruling *does* require is a follow-up that **verifies the automatic path actually works** — an unverified auto-delete is worse than no button, because it is a promise. That verification is folded into the deferred GDPR revisit; until it is done, US-8.1.4's guarantee is asserted rather than proven. See US-8.1.4. |

Wave 7's other two recovery legs were **not** excluded and are built: undo-remove
(#375, a "Removed — Undo" toast) and un-merge (#376, owner-side — see US-1.1.8).

---

## Service Interaction Matrix

Each cell indicates the role: **R** = Read, **W** = Write, **RW** = Read/Write, **--** = not involved.

| Story | Elm | Phoenix | Vision Service | Rust Scraper | PostgreSQL | dbt | External APIs |
|-------|-----|---------|----------------|--------------|------------|-----|---------------|
| US-1.1.1 | W (upload form, verify, shelf picker) | RW (two-step: identify then confirm) | RW (vision) | -- | W (books, book_editions, images) | -- | Modal vision service, Open Library, Google Books |
| US-1.1.2 | R (error display) | R (validation) | -- | -- | R (books) | -- | Open Library, Google Books |
| US-1.1.3 | R (error display) | R (validation) | R (classification) | -- | W (audit_log) | -- | Modal (Qwen2.5-VL-7B-Instruct) |
| US-1.1.7 | RW (bulk drop zone, review screen, shelf selector) | RW (batch intake, pre-process, grouping, batch jobs) | RW (classify + extract per image) | -- | W (books, images, batch_id, group_id) | -- | Modal vision service, Open Library, Google Books |
| US-1.1.4 | R (gate UI) | RW (flag + gate) | -- | -- | RW (books, audit_log) | R (BISAC view) | -- |
| US-1.1.5 | RW (ISBN form) | RW (validate + create) | -- | -- | W (books, bookshelf_placements) | -- | Open Library, Google Books |
| US-1.1.6 | RW (duplicate UI + merge prompt) | R (dedup check + fuzzy match) | -- | -- | R (books, book_editions) | -- | -- |
| US-1.1.8 | RW (merge confirmation) | RW (create edition under existing work) | -- | -- | RW (book_editions) | -- | -- |
| US-1.2.1 | RW (shelf view) | R (shelf data) | -- | -- | R (bookshelves, bookshelf_placements, books) | -- | -- |
| US-1.2.2 | RW (shelf view) | R (shelf data) | -- | -- | R (bookshelves, bookshelf_placements, books) | -- | -- |
| US-1.2.3 | RW (shelf view) | R (shelf data) | -- | -- | R (bookshelves, bookshelf_placements, books) | -- | -- |
| US-1.2.4 | RW (pile view) | R (shelf data) | -- | -- | R (bookshelves, bookshelf_placements, books) | -- | -- |
| US-1.2.5 | RW (navigation) | -- | -- | -- | -- | -- | -- |
| US-1.3.1 | RW (spine render) | R (book data) | -- | -- | R (books, bookshelf_placements) | -- | -- |
| US-1.3.2 | RW (detail overlay) | R (book + editions + related) | -- | -- | R (books, book_editions, authors, review_snapshots, price_snapshots) | R (community_read_count) | -- |
| US-1.4.1 | RW (search UI) | R (search query) | -- | -- | R (books, authors, bookshelves) | -- | -- |
| US-1.5.1 | RW (move action) | RW (placement) | -- | -- | RW (bookshelf_placements, bookshelf_placement_history) | -- | -- |
| US-1.5.2 | RW (abandon action) | RW (placement) | -- | -- | RW (bookshelf_placements, bookshelf_placement_history) | -- | -- |
| US-1.6.3 | RW (re-read action) | RW (placement) | -- | -- | RW (bookshelf_placements, bookshelf_placement_history, books) | -- | -- |
| US-1.5.4 | RW (format picker) | RW (edition creation) | -- | -- | RW (book_editions) | -- | Open Library, Google Books (resolve new ISBN) |
| US-1.6.4 | RW (remove action) | RW (soft delete) | -- | -- | RW (bookshelf_placements, bookshelf_placement_history) | -- | -- |
| US-1.6.5 | R (empty states) | R (shelf data) | -- | -- | R (bookshelves, bookshelf_placements) | -- | -- |
| US-2.1.1 | R (review display) | RW (aggregation) | -- | -- | RW (review_snapshots) | R (sentiment view) | GoodReads, Reddit, Storygraph |
| US-2.2.1 | R (price display) | R (price data) | -- | RW (scrape) | RW (price_snapshots, bookstores) | R (price history view) | -- |
| US-2.2.2 | -- | RW (config mgmt) | -- | R (config) | RW (bookstores) | -- | -- |
| US-2.3.1 | R (author panel) | RW (author intel) | -- | -- | RW (authors, discovered_sources) | R (author view) | Brave Search, RSS feeds |
| US-2.4.1 | R (events display) | RW (event matching) | -- | -- | RW (bookstore_events, bookstores) | R (event view) | Brave Search, SearXNG |
| US-2.5.1 | R (approval UI) | RW (discovery + approval) | -- | -- | RW (discovered_sources, audit_log) | -- | Brave Search, SearXNG |
| US-2.5.2 | R (Third Spaces loading) | RW (geographic sweep) | -- | -- | RW (discovered_sources, third_spaces) | -- | Brave Search, SearXNG |
| US-2.5.3 | RW (opt-out form) | RW (exclusion) | -- | -- | RW (discovered_sources, third_spaces) | -- | Resend / Postmark (confirmation email) |
| US-3.1.1 | RW (cork board) | RW (spaces) | -- | -- | RW (third_spaces, third_space_events) | -- | Brave Search, SearXNG |
| US-4.1.1 | R (status display) | RW (pipeline) | RW (classification) | -- | RW (books, audit_log) | -- | Modal vision service, Open Library, Google Books |
| US-4.1.2 | RW (verification) | RW (KYC flow) | -- | -- | RW (audit_log) | -- | Smile Identity / Yoti / Sumsub |
| US-5.1.1 _(in-app dashboard superseded by Grafana, #267)_ | -- (Grafana) | R (metrics) | -- | -- | R (all schemas) | RW (metric models) | -- |
| US-6.1.1 | -- | RW (feed gen) | -- | -- | R (bookshelves, bookshelf_placements, books) | -- | -- |
| US-7.1 | RW (listing form) | RW (listing) | -- | -- | RW (listings, bookshelf_placements, uploaded_images) | -- | -- |
| US-7.2 | -- | -- | -- | -- | -- | -- | **DEFERRED** (ADR 013) |
| US-7.3 | -- | -- | -- | -- | -- | -- | **DEFERRED** (ADR 013) |
| US-10.1.1 | RW (privacy settings) | RW (profile visibility) | -- | -- | RW (users) | -- | -- |
| US-10.1.2 | RW (block UI) | RW (block) | -- | -- | RW (user_blocks) | -- | -- |
| US-10.2.1 | RW (shelf settings) | RW (shelf visibility) | -- | -- | RW (bookshelves, groups) | -- | -- |
| US-10.2.2 | RW (placement menu) | RW (placement visibility) | -- | -- | RW (bookshelf_placements, visibility_grants) | -- | -- |
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
| US-13.2.2 | -- | -- | -- | -- | -- | -- | **DEFERRED** (ADR 013) |
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
| US-9.8.1 | R (availability display) | R (partner inventory) | -- | -- | R (partner_inventory, book_editions) | -- | -- |
| US-11.1.5 | R (group feed) | R (aggregated content) | -- | -- | R (blog_posts, bookshelf_placements, groups, group_members, user_blocks) | -- | -- |
| US-14.1.1 | RW (registration form) | RW (account creation) | -- | -- | W (users, audit_log) | -- | -- |
| US-14.1.2 | RW (data-driven onboarding overlay: Welcome/Upload/Consent/Done) | RW (upload + confirm + consent + onboarding steps) | RW (vision) | -- | RW (users incl. consent flags/timestamps, books, book_editions, bookshelf_placements) | -- | Modal, Open Library, Google Books |
| US-14.2.1 | RW (login form) | RW (authentication) | -- | -- | R (users), W (audit_log) | -- | -- |
| US-14.3.1 | R (nav state) | R (current user) | -- | -- | R (users) | -- | -- |
| US-14.3.2 | R (token refresh) | RW (token lifecycle) | -- | -- | R (users) | -- | -- |
| US-14.3.3 | RW (dropdown menu + sign out) | RW (token revocation) | -- | -- | W (audit_log) | -- | -- |
| US-15.1.1 | R (landing / collection-routing home) | R (auth check + shelf preview) | -- | -- | R (bookshelves, bookshelf_placements when authed) | -- | -- |
| US-15.2.1 | RW (navigation + user dropdown) | -- | -- | -- | -- | -- | -- |
| US-15.2.2 | RW (swipe nav) | -- | -- | -- | -- | -- | -- |
| US-15.3.1 | R (footer) | -- | -- | -- | -- | -- | -- |
| US-16.1.1 | R (404 page) | R (error response) | -- | -- | -- | -- | -- |
| US-16.2.1 | R (error display) | R (error responses) | -- | -- | -- | -- | -- |
| US-16.3.1 | R (auth redirect) | R (401 response) | -- | -- | -- | -- | -- |
| US-17.1.1 | RW (settings hub + sidebar) | R (user data) | -- | -- | R (users) | -- | -- |
| US-17.2.1 | RW (profile form) | RW (profile update) | -- | -- | RW (users) | -- | -- |
| US-17.2.2 | RW (location form) | RW (location + trigger sweep) | -- | -- | RW (users) | -- | Brave Search, SearXNG (via geographic sweep) |
| US-17.2.3 | RW (password form) | RW (password change) | -- | -- | RW (users, audit_log) | -- | -- |
| US-17.3.1 | RW (notification toggles) | RW (preferences) | -- | -- | RW (users) | -- | -- |
| US-18.1.1 | RW (shelf view) | R (shelf data + community stats) | -- | -- | R (bookshelves, bookshelf_placements, books) | R (mart_community_read_count) | -- |
| US-19.1.1 | RW (ARIA labels) | R (spine + shelf metadata) | -- | -- | R (books, book_editions, bookshelves) | -- | -- |
| US-19.1.2 | RW (keyboard handlers) | -- | -- | -- | -- | -- | -- |
| US-19.2.1 | RW (list/spine toggle) | R (shelf data) | -- | -- | R (bookshelves, bookshelf_placements, books, book_editions) | -- | -- |

---

## Dependency Graph

```
Legend:  A --> B  means "A must be built before B"

US-1.1.1 (Upload + Verify + Shelve — two-step: identify then confirm)
  |
  +--> US-1.1.2 (ISBN Hard Gate)           -- validation within upload
  |      |
  |      +--> US-1.1.5 (Manual ISBN Entry) -- fallback when vision fails
  +--> US-1.1.3 (Non-Book Rejection)       -- classification within upload
  +--> US-1.1.6 (Duplicate Detection)      -- dedup check within upload
  |      |
  |      +--> US-1.1.8 (Multi-Format Merge) -- triggered when ISBN matches different edition of existing work
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
              |
              +--> US-2.5.2 (Geographic Discovery Sweep) -- location-triggered, same infra
              +--> US-2.5.3 (Business Opt-Out) -- exclusion list for discovered sources

--- Phase 3 branches independently ---

  US-2.5.1 --> US-3.1.1 (Third Spaces) -- uses same discovery infra
  US-17.2.2 --> US-2.5.2 (Location set triggers geographic sweep)
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

  US-1.3.2 --> US-7.1.1 (List for Sale — from any shelf)
  US-7.1.1 --> US-7.2.1 (Buy a Book + post-sale lifecycle)
  US-4.1.2 --> US-7.3.1 (Seller Verification)
  US-7.3.1 --> US-7.1.1 (must be verified to list)

--- Phase 6 additions ---

  US-11.1.1 --> US-11.1.5 (Group Content Feed — aggregated blog + shelf activity)

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
3. **US-1.1.1** Upload Photos to Add a Book (two-step: identify then confirm, default WishList)
4. **US-1.1.2** ISBN Hard Gate (part of upload)
5. **US-1.1.3** Non-Book Image Rejection (part of upload)
6. **US-4.1.1** Content Moderation Pipeline (part of upload)
7. **US-8.1.4** Image Retention (cleanup job for uploads)
8. **US-1.2.1 -- US-1.2.4** All four shelves
9. **US-1.6.5** Empty Shelf States (ships with shelves)
10. **US-1.2.5** Shelf navigation
11. **US-1.3.1** Spine rendering
12. **US-1.3.2** Book detail overlay (not a route — overlay on top of current page)
13. **US-1.4.1** Search and sort
13a. **US-1.5.3** Platform-wide discovery search (after basic search works)
14. **US-1.5.1 -- US-1.5.3** Shelf movement (all 5 shelves as valid targets), abandon, re-read
15. **US-1.5.4** Format tracking (now creates `book_editions` rows, not a TEXT[])
15a. **US-1.1.8** Multi-Format Book Merging (after format tracking)
16. **US-1.6.4** Remove a Book from Collection
17. **US-1.1.5** Manual ISBN Entry (fallback for failed vision)
18. **US-1.1.6** Duplicate Book Detection (includes multi-format merge prompt)
19. **US-1.1.4** Age-gated content
20. **US-4.1.2** Age verification
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
49. **US-7.2.1** Buy a Book (+ post-sale buyer prompt)

**Phase 1 (extended) — new stories:**
50. **US-14.1.2** First-Time Onboarding Flow (after registration)
51. **US-14.3.3** Log Out (display name dropdown with Settings + Sign Out)
52. **US-17.1.1** Settings Index Page (hub with sidebar navigation)
53. **US-17.2.1** Profile Management (display name, email, website)
54. **US-17.2.2** Location Settings (city/country, triggers geographic sweep)
55. **US-17.2.3** Change Password
56. **US-17.3.1** Email Notification Preferences
57. **US-19.1.1** ARIA Labels for Visual Elements
58. **US-19.1.2** Keyboard Navigation
59. **US-19.2.1** List View Toggle

**Phase 2 — new stories:**
60. **US-2.5.2** Geographic Discovery Sweep (after US-17.2.2 and US-2.5.1)
61. **US-2.5.3** Business Opt-Out (after US-2.5.1)

**Phase 6 — new stories:**
62. **US-11.1.5** Group Content Feed (after groups infrastructure)

---

## Story-by-Story Mapping

### 1. Core Book Management

---

#### US-1.1.1 -- Upload Photos to Add a Book

| Dimension | Detail |
|-----------|--------|
| **Summary** | Two-step flow: (1) upload image → system identifies candidate → returns for user verification ("We think this is…"); (2) user confirms + chooses shelf (default WishList) → book created. Works/editions model: creates a `books` work + `book_editions` edition. |
| **Phase** | Phase 1 (MVP) |

| Layer | Components |
|-------|------------|
| **Frontend (Elm)** | `Page.Upload` module — multi-step state machine: `Uploading` → `Verifying IdentifiedBook` → `ChoosingShelf IdentifiedBook` → `Complete`. Drag-and-drop / file picker. Verification step shows uploaded image alongside identified book ("We think this is…"). Shelf picker defaults to WishList. Post-success: "Add another" / "View on shelf". Types: `UploadStep`, `IdentifiedBook`, `ShelfPicker`. Ports for file-input interop. |
| **Backend (Phoenix)** | **Step 1:** `StacksWeb.UploadController.identify/2` (`POST /api/upload/identify`) — reads Plug temp file, base64-encodes, inserts `uploaded_images` record, enqueues `IdentifyBookJob`, returns candidate(s) to frontend. **Step 2:** `StacksWeb.BookController.confirm/2` (`POST /api/books/confirm`) — receives confirmed ISBN + target shelf. Checks `book_editions` for existing ISBN → if found, checks for same-work merge (US-1.1.8). If new, creates `books` work + `book_editions` edition + `bookshelf_placements`. `Stacks.Books` context — `Books.create_work_with_edition/2`, `Books.find_or_create_author/1`. |
| **Database** | **Write:** `op.books` (work), `op.book_editions` (edition with ISBN, format, cover), `op.authors`, `op.uploaded_images`, `op.bookshelf_placements`, `op.audit_log`. **Read:** `op.book_editions` (dedup check by ISBN), `op.books` (fuzzy match for multi-format merge). |
| **Jobs (Oban)** | `Stacks.Workers.IdentifyBookJob` — sends base64 image to Modal vision service over HMAC-authenticated HTTPS. Returns candidates to caller. `Stacks.Workers.EnrichBookJob` — fetch metadata from Open Library / Google Books after ISBN resolved. |
| **External Services** | **Modal** (Qwen2.5-VL-7B-Instruct on A10G GPU) for image classification and book extraction. Open Library API for ISBN lookup + work/edition metadata. Google Books API as fallback. |
| **dbt Models** | None directly; feeds `stg_books`, `stg_book_editions`, `stg_uploaded_images` staging models. |
| **Infrastructure** | Modal hosts the Python vision service (separate from Fly.io). No object storage for uploads — image bytes live in Oban job args (Postgres) for the duration of processing. |
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
| **Summary** | The person adding a book can mark it "adults only" (raise-only); the platform owner can override either way. Only 18+ verified users can view gated books. No automatic subject/BISAC classification — that classifier was removed as unreliable. |
| **Phase** | Phase 1 (late) / Cross-cutting |

| Layer | Components |
|-------|------------|
| **Frontend (Elm)** | "Adults only" checkbox at the verify step (raises the gate). `Page.BookDetail` checks `visibility_tier` before rendering; owner override on an owner-only admin surface (follow-up). |
| **Backend (Phoenix)** | `Stacks.Books.set_visibility_tier/3` (human-set; user path raise-only, owner either-way) called by `BookController.set_age_gate/2` (`PUT /api/books/:id/age-gate`). `Stacks.Accounts` -- `age_verified?/1` check. Plug `StacksWeb.Plugs.AgeGate` on relevant routes. |
| **Database** | **Read:** `op.books` (visibility_tier). **Write:** `op.books` (set visibility_tier when a human raises/overrides the gate). |
| **Jobs (Oban)** | None — age-gating is a synchronous human action, not a pipeline step. |
| **External Services** | None. |
| **dbt Models** | `stg_books` (`visibility_tier`). |
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
| **Database** | Same as US-1.1.1 (books, bookshelf_placements, audit_log). |
| **Jobs (Oban)** | `EnrichBookJob` -- same as US-1.1.1. |
| **External Services** | Open Library, Google Books (ISBN resolution). |
| **dbt Models** | `int_upload_method` (track manual vs. vision entry rates). |
| **Infrastructure** | None additional. |
| **Dependencies** | US-1.1.2 (ISBN Hard Gate — same validation applies). |

---

#### US-1.1.6 -- Duplicate Book Detection

| Dimension | Detail |
|-----------|--------|
| **Summary** | When a resolved ISBN already exists in the user's collection, show the existing book with options: view it, move it to another shelf, or close. When the ISBN is different but the title+author match an existing work, offer multi-format merge (US-1.1.8). |
| **Phase** | Phase 1 (MVP) |

| Layer | Components |
|-------|------------|
| **Frontend (Elm)** | `Components.DuplicateDetected` — shows existing book cover + current shelf, with "View Book", "Move to Shelf", and "Close" actions. For multi-format: shows both editions side-by-side with "Yes, same book" (merge) and "No, it's different" (create new). |
| **Backend (Phoenix)** | `Stacks.Books.find_existing/1` — ISBN dedup check against `book_editions.isbn`. `Stacks.Books.find_same_work/2` — fuzzy match on title+author (Jaro-Winkler > 0.8) against existing `books` works. Returns existing book data or merge candidate. |
| **Database** | **Read:** `op.book_editions` (ISBN lookup), `op.books` (fuzzy title+author match), `op.bookshelf_placements` (current shelf). |
| **Jobs (Oban)** | None. |
| **External Services** | None. |
| **dbt Models** | `int_duplicate_detection_rate`. |
| **Infrastructure** | None additional. |
| **Dependencies** | US-1.1.1 (part of upload flow). |

---

#### US-1.1.8 -- Multi-Format Book Merging

| Dimension | Detail |
|-----------|--------|
| **Summary** | When a user adds a different format of a book they already own (e.g., Kindle edition of existing hardcover), the system offers to merge it as a new edition under the same work rather than creating a duplicate. |
| **Phase** | Phase 1 (MVP) |

| Layer | Components |
|-------|------------|
| **Frontend (Elm)** | `Components.FormatMerge` — side-by-side view of existing and new edition covers. "You own [Title] as a [format]. Add the [new format] edition?" with merge/decline buttons. Reuses warm blue state from duplicate detection. |
| **Backend (Phoenix)** | `Stacks.Books.merge_edition/2` — creates a new `book_editions` row under the existing `books` work. Links the new ISBN. Sets `is_primary = false` (existing edition remains primary). No new shelf placement created. `StacksWeb.BookController.merge_format/2` (`POST /api/books/:id/merge-format`). **Un-merge (#376)** is owner-side, not public UI (owner ruling 2026-07-30): `Stacks.DataCorrection.UnmergeEdition`, a `Stacks.DataCorrection.Targeted` correction reached by `POST /api/admin/data_corrections/unmerge_edition/target` behind `[:api, :admin, :require_owner, :rate_limit_admin]`. Splits the edition onto a newly minted work, promotes it to that work's primary, and inherits `visibility_tier` so a repair cannot un-gate content. **Placements are deliberately not moved** — `Shelving.place_book/3` always points a placement at its work's *primary* edition and a merged edition is never primary, so no placement has ever named the split-out edition and which readers acquired it is unrecorded; the plan reports the retained count instead of guessing. See [`runbooks/data-correction.md`](runbooks/data-correction.md). |
| **Database** | **Write:** `op.book_editions` (new edition row). **Read:** `op.books` (existing work), `op.book_editions` (existing editions). |
| **Jobs (Oban)** | `EnrichBookJob` — fetch edition-specific metadata (page count, cover) for the new edition. `TriggerPriceScrapeJob` — scrape prices for the new ISBN. |
| **External Services** | Open Library, Google Books (edition-specific metadata). |
| **dbt Models** | `stg_book_editions`, `int_format_distribution`. |
| **Infrastructure** | None additional. |
| **Dependencies** | US-1.1.6 (triggered during duplicate detection). |

---

#### US-1.1.7 -- Bulk Image Upload with Grouping and Review

| Dimension | Detail |
|-----------|--------|
| **Summary** | User drops N images; system classifies, extracts, and groups related images (same book → same group); user reviews a confirmation screen with one card per detected book; shelf is chosen per card; confirmed books go through standard ISBN pipeline. Multi-book images (shelfie, screenshot of reading list) produce multiple cards from a single image. |
| **Phase** | Phase 1 (MVP) |

| Layer | Components |
|-------|------------|
| **Frontend (Elm)** | `Page.Upload` is the only module (no `Page.Upload.Review`, `Components.BookReviewCard`, or `Components.BulkProgress` exist). As built it is a **single-image** flow: one `file`, a drop zone (`upload-drop-zone` / `viewDropPrompt`), a presigned-URL upload + SSE stream, and a `UploadStep` state machine (`Uploading` → `Verifying` → `ChoosingShelf` → `Complete`). The `UploadResult` type carries the per-image outcomes (`Identified`, `NotABook`, `ManualISBNEntry`, `DuplicateDetected`, `SameWorkFound`, `EditionMerged`). The multi-image drop / grouping / review-card-grid described here is **not built** — bulk intake and per-book review buckets remain aspirational. |
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
| **Frontend (Elm)** | Unified `Page.Bookshelf` module (config-driven for Library/AntiLibrary/WishList — see 2026-03-16 refactor). Library variant theme: `{ wood: DarkWalnut, backdrop: GreenDamask }`. Renders list of spines via `Components.Spine`. |
| **Backend (Phoenix)** | `Stacks.Shelving` context -- `Shelving.get_bookshelf_books/2` with bookshelf_name `:library`. `StacksWeb.BookshelfController.show/2`. |
| **Database** | **Read:** `op.bookshelves`, `op.bookshelf_placements`, `op.books`, `op.authors`. |
| **Jobs (Oban)** | None. |
| **External Services** | None. |
| **dbt Models** | `stg_bookshelf_placements`, `int_shelf_composition`. |
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
| **Frontend (Elm)** | Unified `Page.Bookshelf` module (config-driven). AntiLibrary variant theme: `{ wood: LightOak, backdrop: BotanicalPrints }`. Same view code path as Library. |
| **Backend (Phoenix)** | Same `Stacks.Shelving` context, bookshelf_name `:antilibrary`. |
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
| **Frontend (Elm)** | Unified `Page.Bookshelf` module (config-driven). WishList variant theme: `{ wood: BlueGrey, backdrop: WatercolourFlorals }`. |
| **Backend (Phoenix)** | Same `Stacks.Shelving` context, bookshelf_name `:wishlist`. |
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
| **Frontend (Elm)** | `Page.Bookshelf.ReadingPile` module. Different layout from shelves -- vertical stack / pile metaphor rather than horizontal shelf. `PileView` component with armchair background. |
| **Backend (Phoenix)** | Same `Stacks.Shelving` context, bookshelf_name `:reading_pile`. May include reading progress data. |
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
| **Backend (Phoenix)** | `Stacks.Shelving.spine_data/1` -- computes wear level from bookshelf_placement_history (number of reads, time on shelves). Returns precomputed spine metadata. |
| **Database** | **Read:** `op.books` (page_count), `op.bookshelf_placement_history` (engagement calc). |
| **Jobs (Oban)** | `Stacks.Workers.RecalculateWearJob` -- periodic recalculation of wear levels (or on shelf-move events). |
| **External Services** | None. |
| **dbt Models** | `int_book_engagement` (materialized view for wear calculation). |
| **Infrastructure** | None additional. |
| **Dependencies** | US-1.2.1 -- US-1.2.4 (shelves to render spines on). |

---

#### US-1.3.2 -- Book Detail Overlay

| Dimension | Detail |
|-----------|--------|
| **Summary** | Click spine to open an **overlay** (not a route) showing: cover image, editions, metadata, reviews, prices per edition, author info, writing links, move-to-shelf action, search-surfaced enrichment. Dismissable via X, click-outside, or Escape. URL does not change. |
| **Phase** | Phase 1 (MVP) |

| Layer | Components |
|-------|------------|
| **Frontend (Elm)** | `BookDetailOverlay` type in model (`Maybe BookDetailOverlay`). Not a route — the overlay is UI state managed in the parent page's model. Sub-components that exist under `frontend/src/Components/`: `Components.PriceInfo` (grouped by edition), `Components.AuthorCard`, `Components.ShelfMover` (all 5 shelves). Cover image, book metadata, edition list, review summary, and writing links are rendered inline within the page/overlay view — there are **no** `Components.CoverImage`, `Components.BookMeta`, `Components.EditionList`, `Components.ReviewSummary`, or `Components.WritingLinks` modules. `Components.PartnerAvailability` is a Phase 3+ addition, not yet built. Messages: `OpenBookDetail BookId`, `CloseBookDetail`, `MoveToShelf ShelfType`, `OpenExternalLink Url`. Focus trapping within overlay for accessibility (US-19.1.1). |
| **Backend (Phoenix)** | `Stacks.Books.get_book_detail/1` — aggregates work + editions + author + reviews + prices (per edition) + writing links + partner availability (Phase 3+) + community read count (for Looking for a Home). `StacksWeb.BookController.show/2`. |
| **Database** | **Read:** `op.books` (work), `op.book_editions` (all editions), `op.authors`, `op.review_snapshots` (per work), `op.price_snapshots` (per edition), `op.bookshelf_placements`. Phase 3+: `op.partner_inventory` (per edition via ISBN), `op.partner_events` (ISBN-linked), `op.blog_posts`, `op.post_book_associations`. `wh.mart_community_read_count` (for community wear on Looking for a Home). |
| **Jobs (Oban)** | None directly (data populated by enrichment jobs). |
| **External Services** | None at render time. |
| **dbt Models** | `int_book_detail_view` (pre-joined view for performance), `mart_community_read_count`. |
| **Infrastructure** | SSR rendering for public book pages (Phoenix templates) remains at `/public/book/:isbn`. The Elm overlay is the interactive path. |
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
| **Database** | **Read:** `op.books` (with GIN index on title/author tsvector), `op.authors`, `op.bookshelves`, `op.bookshelf_placements`, `op.price_snapshots` (for price filter). |
| **Jobs (Oban)** | None. |
| **External Services** | None. |
| **dbt Models** | None directly. |
| **Infrastructure** | PostgreSQL GIN / GiST indexes for full-text search. |
| **Dependencies** | US-1.1.1, US-1.2.1 -- US-1.2.4. |

---

#### US-1.5.3 (new) -- Platform-Wide Discovery Search

| Dimension | Detail |
|-----------|--------|
| **Summary** | Searches beyond the user's own collection: other users' public shelves, marketplace listings, partner inventory, and Third Spaces events. Results surfaced in the search dropdown and enriched within the book detail overlay. |
| **Phase** | Phase 1 (late MVP) / Phase 3 (partner results) |

| Layer | Components |
|-------|------------|
| **Frontend (Elm)** | `SearchScope` type gains `WholePlatform` variant. Search dropdown splits into "Your Collection" (instant local) and "On the Platform" (async API). External results show contextual labels ("Listed by [user] for R120", "In stock at [partner]", "On [user]'s shelf"). Shimmer placeholders while loading. |
| **Backend (Phoenix)** | `Stacks.Books.search_platform/2` (`GET /api/search/platform`) — queries across `bookshelf_placements` (public visibility), `listings` (active), `partner_inventory` (approved partners), `partner_events` (related ISBNs). Applies `resolve_visibility/2` filtering and block filtering. Results grouped by type. |
| **Database** | **Read:** `op.books`, `op.book_editions`, `op.bookshelf_placements` (where visibility = 'platform'), `op.listings`, `op.partner_inventory`, `op.partner_events`, `op.user_blocks`. |
| **Jobs (Oban)** | None. |
| **External Services** | None. |
| **dbt Models** | None directly. |
| **Infrastructure** | PostgreSQL full-text indexes on `books.title`, `authors.name`. Rate limit: 30/min. |
| **Dependencies** | US-1.4.1 (basic search), US-10.1.1 (visibility model for filtering). |

---

#### US-1.5.1 -- Move Books Between Shelves

| Dimension | Detail |
|-----------|--------|
| **Summary** | Standard flow: WishList -> AntiLibrary -> Reading Pile -> Library. History of all movements preserved. |
| **Phase** | Phase 1 (MVP) |

| Layer | Components |
|-------|------------|
| **Frontend (Elm)** | `Components.ShelfMover` -- dropdown or contextual menu showing valid target shelves. Animation of book sliding to new shelf. Confirmation toast. |
| **Backend (Phoenix)** | `Stacks.Shelving.move_book/3` -- validates transition, updates placement, writes history. `StacksWeb.BookshelfPlacementController.move/2` (`PUT /api/placements/:id/move`). |
| **Database** | **Write:** `op.bookshelf_placements` (update shelf_id), `op.bookshelf_placement_history` (insert movement record). **Read:** `op.bookshelf_placements` (current location). |
| **Jobs (Oban)** | `Stacks.Workers.RecalculateWearJob` triggered on move (wear may change). |
| **External Services** | None. |
| **dbt Models** | `stg_bookshelf_placement_history`, `int_book_journey`. |
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
| **Database** | **Write:** `op.bookshelf_placements`, `op.bookshelf_placement_history` (with note field). |
| **Jobs (Oban)** | Wear recalculation. |
| **External Services** | None. |
| **dbt Models** | `int_abandonment_rate` (metrics). |
| **Infrastructure** | None additional. |
| **Dependencies** | US-1.5.1, US-1.2.4 (Reading Pile). |

---

#### US-1.5.4 -- Format Tracking

| Dimension | Detail |
|-----------|--------|
| **Summary** | Track which formats the user owns per book. Formats are now derived from `book_editions` — each owned format is a row in `book_editions` under the same work. Adding a format means creating a new edition (with its own ISBN) or toggling `is_primary`. |
| **Phase** | Phase 1 (MVP) |

| Layer | Components |
|-------|------------|
| **Frontend (Elm)** | `Components.FormatPicker` on Book Detail overlay. Shows all known editions as filled icons (owned) plus outlined icons for formats not yet owned. Clicking an un-owned format prompts: "Enter the ISBN for the [format] edition" (inline ISBN input), which triggers the multi-format merge flow (US-1.1.8). |
| **Backend (Phoenix)** | `Stacks.Books.merge_edition/2` — creates a new `book_editions` row. No `update_placement_formats` — formats are no longer a column on placements. |
| **Database** | **Write:** `op.book_editions` (new edition row). **Read:** `op.book_editions` (existing editions for the work). |
| **Jobs (Oban)** | `EnrichBookJob` (fetch edition-specific metadata). |
| **External Services** | Open Library, Google Books (ISBN resolution for new format). |
| **dbt Models** | `stg_book_editions`, `int_format_distribution`. |
| **Infrastructure** | None additional. |
| **Dependencies** | US-1.3.2 (format picker lives on detail overlay), US-1.1.8 (merge flow). |

---

#### US-1.6.4 -- Remove a Book from Collection

| Dimension | Detail |
|-----------|--------|
| **Summary** | Soft delete via `bookshelf_placements.removed_at`. Book row preserved. Reading history preserved. Confirmation dialog warns this removes from all shelves. |
| **Phase** | Phase 1 (MVP) |

| Layer | Components |
|-------|------------|
| **Frontend (Elm)** | `Components.RemoveBookModal` -- confirmation with book title, warning text ("This removes [title] from your collection. Your reading history is preserved."), confirm/cancel. Triggered from Book Detail page. |
| **Backend (Phoenix)** | `Stacks.Shelving.remove_book/1` -- sets `removed_at` on all `bookshelf_placements` for the book. Does NOT delete the `books` row. Writes history record. |
| **Database** | **Write:** `op.bookshelf_placements` (set removed_at), `op.bookshelf_placement_history` (removal record). **Read:** `op.bookshelf_placements` (current placements). |
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
| **Frontend (Elm)** | `Components.EmptyShelf` -- per-shelf variant with themed illustration and message. Rendered when `bookshelf_placements` count is 0 for a shelf. Includes CTA button ("Add a book" → upload). |
| **Backend (Phoenix)** | None additional (empty state is client-side based on empty shelf data). |
| **Database** | **Read:** `op.bookshelves`, `op.bookshelf_placements` (count check). |
| **Jobs (Oban)** | None. |
| **External Services** | None. |
| **dbt Models** | None. |
| **Infrastructure** | None additional. |
| **Dependencies** | US-1.2.1 -- US-1.2.4 (shelves must exist). |

---

#### US-1.6.1 -- Move a Book Between Bookshelves

| Dimension | Detail |
|-----------|--------|
| **Summary** | Move a placed book from one bookshelf to another (e.g. WishList → Library), recording the transition in placement history. Canonical refresh of the older US-1.5.1 entry. |
| **Phase** | Phase 1 (MVP) |
| **Status** | Built |
| **Implementation** | `PUT /api/placements/:id/move` → `StacksWeb.BookshelfPlacementController.move` → `Stacks.Shelving.move_book/3`; history in `op.bookshelf_placement_history`. Frontend `Page.BookDetail`. Event fan-out via `Stacks.Feeds.Handlers.PlacementHandler`. |

---

#### US-1.6.2 -- Abandon a Book Back to AntiLibrary

| Dimension | Detail |
|-----------|--------|
| **Summary** | Abandon a book currently being read, returning it to the AntiLibrary. Same move machinery, distinct intent. Canonical refresh of the older US-1.5.2 entry. |
| **Phase** | Phase 1 (MVP) |
| **Status** | Built |
| **Implementation** | `PUT /api/placements/:id/move` (target `antilibrary`) → `Stacks.Shelving.move_book/3`. Frontend `Page.BookDetail`. |

---

#### US-1.6.3 -- Record Multiple Reads

| Dimension | Detail |
|-----------|--------|
| **Summary** | Record that a book has been read again (re-read), incrementing its read count. Canonical refresh of the older US-1.5.3 entry. |
| **Phase** | Phase 1 (MVP) |
| **Status** | Built |
| **Implementation** | `Stacks.Shelving.reread_book/2` (context; a re-read is recorded when a completed book is moved back to the Reading Pile). Frontend `Page.BookDetail`. Registered event via `Stacks.Events.Registry`. |

---

#### US-1.6.6 -- Track Reading Progress

| Dimension | Detail |
|-----------|--------|
| **Summary** | Record how far through a book the reader is (page / percent) on a Reading-Pile placement. |
| **Phase** | Phase 1 (MVP) |
| **Status** | Built |
| **Implementation** | `PUT /api/placements/:id/progress` → `StacksWeb.BookshelfPlacementController.update_progress` → `Stacks.Shelving.update_reading_progress/3`. Frontend `Page.BookDetail`, `Page.Bookshelf.ReadingPile`. |

---

#### US-1.7.1 -- Organize Books into Shelves

| Dimension | Detail |
|-----------|--------|
| **Summary** | Create, delete, and reorder the physical shelf rows within a bookshelf's bookcase (`op.shelves`), and move placements between them. |
| **Phase** | Phase 1 (MVP) |
| **Status** | Built |
| **Implementation** | `GET/POST /api/bookshelves/:bookshelf_name/shelves`, `DELETE /api/shelves/:id`, `PUT /api/bookshelves/:bookshelf_name/shelves/reorder` → `StacksWeb.ShelfController`; `PUT /api/placements/:id/shelf` → `.move_to_shelf`. Two-phase reorder in `Stacks.Shelving` (`shelving.ex:778`). Frontend `Page.Bookshelf`. |

---

#### US-1.1.9 -- Import a Goodreads Library Export

| Dimension | Detail |
|-----------|--------|
| **Summary** | Bulk-import a Goodreads CSV export: each row resolved through the ISBN hard gate and placed on a bookshelf, with a per-row import status view. |
| **Phase** | Phase 1 (MVP) |
| **Status** | Not built — spec only (`Page.Import`, `POST /api/imports/goodreads`, `GET /api/imports/:id/rows` are specified but absent). Reuses the shipped `Stacks.Books.ISBNResolver` and `POST /api/bookshelves/:bookshelf_name/placements`. |
| **Implementation** | Planned: `Page.Import`, `StacksWeb.ImportController`; row resolution via `Stacks.Books.ISBNResolver.resolve/1`. |

---

#### US-1.5.5 -- Browse the Whole Catalogue and Shelve What You Find

| Dimension | Detail |
|-----------|--------|
| **Summary** | Browse the platform-wide book catalogue and add any catalogue book directly to a bookshelf. Retro-story of record for the already-shipped `/catalogue` surface. |
| **Phase** | Phase 1 (MVP) |
| **Status** | Built (shipped early, no prior story file) |
| **Implementation** | `GET /api/catalogue` → `StacksWeb.CatalogueController.index` (`StacksWeb.ProtoJSON.catalogue`); `GET /api/placements/mine` → `BookshelfPlacementController.mine`; add via `POST /api/bookshelves/library/placements`. Frontend `Page.Catalogue`. Catalogue metadata only — no user PII. |

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
| **Frontend (Elm)** | Planned (Phase 2, not yet built): a review-summary component — sentiment bar (positive/mixed/negative), source cards with rating + link, expandable detail. No `Components.ReviewSummary` module exists today. |
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
| **Database** | **Write:** `op.bookstore_events`. **Read:** `op.bookstores`, `op.books`, `op.authors`, `op.bookshelf_placements`. |
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

#### US-2.5.2 (new) -- Geographic Discovery Sweep

| Dimension | Detail |
|-----------|--------|
| **Summary** | Location-triggered discovery of local bookshops, reading groups, cafes, and literary events. Fires when user sets location (US-17.2.2) and on a quarterly cron. Populates Third Spaces independently of book-specific triggers. |
| **Phase** | Phase 2 (Enrichment) |

| Layer | Components |
|-------|------------|
| **Frontend (Elm)** | Third Spaces page shows "Discovering spaces near [City]…" loading state after location set. Results appear as cards on the cork board. |
| **Backend (Phoenix)** | `Stacks.Discovery.GeographicSweep` — generates location-based search queries (`"bookshop {city}"`, `"reading group {city}"`, etc.), evaluates results with LLM scoring, checks exclusion list before suggesting. `Discovery.geographic_sweep/2` accepts `{city, country_code}`. |
| **Database** | **Write:** `op.discovered_sources` (with `discovered_via = 'geographic_sweep'`), `op.third_spaces`. **Read:** `op.discovered_sources` (exclusion list — `status = 'excluded'`), `op.users` (location). |
| **Jobs (Oban)** | `Stacks.Workers.GeographicDiscoveryJob` — triggered by `user.location_updated` event and by quarterly Oban.Cron schedule. Queue: `geographic_discovery`, concurrency: 2. |
| **External Services** | Brave Search API, SearXNG. |
| **dbt Models** | Reuses `stg_discovered_sources`, `stg_third_spaces`. |
| **Infrastructure** | None additional (reuses discovery infrastructure). |
| **Dependencies** | US-2.5.1 (same scoring infrastructure), US-17.2.2 (location must be set). |

---

#### US-2.5.3 (new) -- Business Opt-Out from Platform Listings

| Dimension | Detail |
|-----------|--------|
| **Summary** | Businesses discovered and listed without their consent can request removal. "Is this your business?" link on every discovered listing. Exclusion list prevents re-discovery. |
| **Phase** | Phase 2 (Enrichment) |

| Layer | Components |
|-------|------------|
| **Frontend (Elm)** | Subtle "Is this your business?" link on `Components.SpaceCard` and `Components.PriceInfo` for discovered (non-partner) sources. Links to a simple form: business name, contact email, choice between "Remove my listing" and "Become a partner". |
| **Backend (Phoenix)** | `StacksWeb.OptOutController.create/2` (`POST /api/opt-out`) — unauthenticated endpoint. Creates an opt-out request. Platform owner is notified. For removal: sets `discovered_sources.status = 'excluded'` and/or `third_spaces.opted_out = true`. For partnership interest: routes to US-9.1.1 flow. `Stacks.Discovery.OptOut` context — `request_removal/1`, `process_removal/1`, `add_to_exclusion_list/1`. |
| **Database** | **Write:** `op.discovered_sources` (status = 'excluded', excluded_at, exclusion_email). `op.third_spaces` (opted_out = true, opted_out_at). `op.audit_log`. |
| **Jobs (Oban)** | `Stacks.Workers.OptOutConfirmationJob` — sends confirmation email to the business. |
| **External Services** | Resend / Postmark (confirmation email). |
| **dbt Models** | `int_opt_out_rate`. |
| **Infrastructure** | Rate limit: 5/min on `/api/opt-out` (unauthenticated). |
| **Dependencies** | US-2.5.1 or US-2.5.2 (discovered sources must exist). |

---

#### US-2.6.1 -- The Other Editions of a Book Find Themselves

| Dimension | Detail |
|-----------|--------|
| **Summary** | When a work enters the catalogue, its other editions (ISBNs/formats) are discovered and attached automatically. Retro-story of record for the shipped `DiscoverEditionsJob`. New US-2.6.x family within Phase 2 Enrichment. |
| **Phase** | Phase 2 (Enrichment) |
| **Status** | Built (shipped as campaign ROOT-H remediation, no prior story file) |
| **Implementation** | `Stacks.Workers.DiscoverEditionsJob`, enqueued by `Stacks.Enrichment.Handlers.BookCreatedHandler`; editions resolved via `Stacks.Books.ISBNResolver.editions_for_work/1`; cache invalidated by `Stacks.Books.Handlers.CacheInvalidationHandler`. Surfaced on `Page.BookDetail` (`GET /api/books/:id`). |

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
| **Summary** | 4-step pipeline: (1) book check via vision, (2) ISBN resolution, (3) metadata lookup, (4) store book as `public`. Age-gating is NOT decided here — it is human-set afterward (see US-1.1.4). |
| **Phase** | Phase 1 (MVP) / Cross-cutting |

| Layer | Components |
|-------|------------|
| **Frontend (Elm)** | Status indicators on upload flow -- progress through pipeline steps. Error states per step. |
| **Backend (Phoenix)** | `Stacks.Moderation` context. `Moderation.run_pipeline/1` -- orchestrates the steps: classify image -> resolve ISBN -> metadata lookup -> `Books.create/1` with `visibility_tier: "public"`. No subject-classification/tiering step. |
| **Database** | **Write:** `op.books` (created `public`). **Read:** `op.books` (dedup). |
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
| **Frontend (Elm)** | Not built. ADR-020 §2 removed the self-declaration affordance and there is no `Page.Settings.AgeVerification` page or `Components.KYCWidget`; the provider-sourced KYC flow (iframe / redirect) is tracked under #069. Age-gating ships dark behind `AGE_GATING_ENABLED`. |
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

> **SUPERSEDED (Issue #267):** The in-app `/admin/metrics` operational-metrics
> dashboard is superseded by the Grafana observability stack (ADR-021, #231/#236–240).
> The operational-metrics surface is Grafana (`apps/core/priv/grafana/*`, E2E:
> `e2e/tests/dashboards.spec.ts`), **not** an in-app page. The `Page.Admin.Metrics`
> module, `Stacks.Admin.Metrics` context, `StacksWeb.MetricsController`, and the
> `/api/metrics*` routes were removed in #267. The scraper-health slice survives as
> `Stacks.Monitoring.list_source_health/0` → `GET /api/admin/source-health`, consumed
> by the retained `Page.Admin.ScraperConfig` page. Host-page dependents that assumed
> this dashboard — the partner-request cards (US-9.1.1) and partner engagement metrics
> (US-9.5.1) — will need a new home when built.

| Dimension | Detail |
|-----------|--------|
| **Summary** | System health, job status, data freshness, source discovery stats, costs, GDPR compliance. Curator's desk aesthetic. NOT user reading analytics. |
| **Phase** | Phase 4 (Polish) — **SUPERSEDED by Grafana (#267)** |

| Layer | Components |
|-------|------------|
| **Frontend (Elm)** | ~~`Page.Admin.Metrics` module~~ removed (#267). Ops-metrics surface is Grafana. |
| **Backend (Phoenix)** | ~~`Stacks.Admin.Metrics` context / `StacksWeb.MetricsController`~~ removed (#267). Source-health survives as `Stacks.Monitoring.list_source_health/0` for the scraper-health page. |
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
| **Database** | **Read:** `op.bookshelves`, `op.bookshelf_placements`, `op.books`, `op.authors`. |
| **Jobs (Oban)** | `Stacks.Workers.RegenerateFeedJob` -- regenerate cached feed when shelf changes (event-driven). |
| **External Services** | None. |
| **dbt Models** | None. |
| **Infrastructure** | CDN caching for feed XML. |
| **Dependencies** | US-1.2.1 -- US-1.2.4 (shelves must exist). |

---

#### US-6.2.1 -- POSSE: Syndicate a Post to Substack

| Dimension | Detail |
|-----------|--------|
| **Summary** | Publish Own Site, Syndicate Elsewhere: syndicate a native blog post to Substack (and record the syndication link), with the canonical URL remaining `/blog/:id`. Depends on the blog (Phase 7). |
| **Phase** | Phase 7 (Blog) |
| **Status** | Not built — spec only (no syndication modules in `apps/core`). Email-to-Substack leg deliberately deferred; canonical URL stays the post UUID (`/blog/:id`) — slugs deferred with the reasoning recorded in the story. |
| **Implementation** | Planned: `POST/PUT /api/blog/posts/:id/syndications`, `GET /api/blog/posts/:id/syndication` → `StacksWeb.BlogController`; `Page.Blog.Editor` / `Page.Blog.Post`; visibility gated by `Stacks.Visibility`. Existing per-handle blog feed: `GET /api/feeds/u/:handle/blog`. |

---

### 7. Marketplace (Classifieds)

See [ADR 013](decisions/013-marketplace-classifieds-first.md) for the decision to ship as a classifieds board rather than a full e-commerce platform.

---

#### US-7.1.1 -- List a Book for Sale

| Dimension | Detail |
|-----------|--------|
| **Summary** | Classifieds listing: photos, condition grading (new / like_new / good / fair / poor), pricing, and seller contact info for off-platform communication. No on-platform payments or messaging. |
| **Phase** | Phase 5 (Marketplace) — **Implemented** |

| Layer | Components |
|-------|------------|
| **Frontend (Elm)** | `Page.Marketplace.CreateListing` -- photo upload (reuse upload components), condition selector (enum), pricing mode toggle (fixed / offer), minimum price input, contact info field. `Components.ConditionGrader`. |
| **Backend (Phoenix)** | `Stacks.Marketplace` context. `Marketplace.create_listing/1`. `StacksWeb.ListingController`. Listing state machine: `draft -> active -> sold -> removed -> expired`. Denormalises `listing_status` to `bookshelf_placements`. |
| **Database** | **Write:** `op.listings` (including `contact_info`), `op.uploaded_images` (listing photos), `op.bookshelf_placements` (`listing_status` denorm). **Read:** `op.books`. |
| **Jobs (Oban)** | `Stacks.Workers.ListingExpiryJob` -- auto-expire listings past 30-day TTL. |
| **External Services** | None. |
| **dbt Models** | `stg_listings`, `mart_marketplace_activity`. |
| **Infrastructure** | Image storage for listing photos. |
| **Dependencies** | US-1.1.1 (book must exist). |

---

#### US-7.2.1 -- Buy a Book — DEFERRED

| Dimension | Detail |
|-----------|--------|
| **Summary** | **Deferred per [ADR 013](decisions/013-marketplace-classifieds-first.md).** On-platform payments (Stitch Money, #054b) and shipping (Pargo, #054c) are deferred indefinitely. Buyers contact sellers directly using the contact info on the listing. The `transactions`, `offer_threads`, and `offer_messages` tables exist in DB but are unused. |
| **Phase** | Future (was Phase 5) |

---

#### US-7.3.1 -- Seller Verification — DEFERRED

| Dimension | Detail |
|-----------|--------|
| **Summary** | **Deferred per [ADR 013](decisions/013-marketplace-classifieds-first.md).** Seller KYC becomes relevant when the platform facilitates financial transactions. Not needed for classifieds model. |
| **Phase** | Future (was Phase 5) |

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
| **Frontend (Elm)** | No dedicated page. The export affordance lives on `Page.Settings.Privacy` (`UserClicksExport` → `Api.requestExport` → `POST /api/gdpr/export`), with `exporting : RemoteData` driving the button/progress state. There is no `Page.Settings.DataExport` module. |
| **Backend (Phoenix)** | `Stacks.GDPR.Export` -- `export_user_data/2`. Collects from all user-related tables. Serialisers for JSON, CSV, OPDS. `StacksWeb.GDPRController.export/2`. |
| **Database** | **Read:** All tables with user data: `op.books`, `op.bookshelves`, `op.bookshelf_placements`, `op.bookshelf_placement_history`, `op.blog_posts`, `op.audit_log` (user's entries). |
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
| **Frontend (Elm)** | No dedicated page. The delete flow lives on `Page.Settings.Privacy` — a typed confirmation phrase (`"DELETE"`, `deleteConfirmed`) gates `UserClicksDeleteAccount` → `Api.deleteAccount` → `DELETE /api/gdpr/account`, emitting the `AccountDeleted` out-message. There is no `Page.Settings.DeleteAccount` module. |
| **Backend (Phoenix)** | `Stacks.GDPR.Deletion` -- `delete_user_data/1`. Ecto.Multi transaction for cascade delete across op schema. Separate call to anonymise `wh` schema records. `StacksWeb.GDPRController.delete/2`. |
| **Database** | **Delete:** All user rows in `op.*`. **Update:** `wh.*` (anonymise user_id, hash PII). |
| **Jobs (Oban)** | `Stacks.Workers.AccountDeletionJob` -- async cascade + warehouse anonymisation. `Stacks.Workers.ConfirmDeletionJob` -- verification email before execution. |
| **External Services** | None. |
| **dbt Models** | `mart_gdpr_deletions` (tracking). |
| **Infrastructure** | None additional. |
| **Dependencies** | US-8.1.3 (consent), US-8.1.5 (audit log records deletion event). |
| **Deliberately excluded** | **A cancel-deletion grace period** (owner ruling 2026-07-30, recorded by #376). Immediate erasure stays: a grace window means the data still exists after the person asked for it to be gone, and it turns a one-shot operation into a scheduled state every other write path must then respect. Doubt belongs in front of the operation — the typed confirmation phrase and `ConfirmDeletionJob`'s verification email — not behind it. See [Deliberate exclusions](#deliberate-exclusions--features-we-decided-not-to-build). |

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
| **External Services** | Object storage (Cloudflare R2) -- delete original files. |
| **dbt Models** | `mart_image_retention_stats`. |
| **Infrastructure** | Object storage lifecycle policies as backup. |
| **Dependencies** | US-1.1.1 (images must be uploaded). |
| **Deliberately excluded** | **A user-facing "delete this photo" control** (owner ruling 2026-07-30, recorded by #376). Excluded *publicly*, not outright: the automatic 30-day deletion above is the guarantee, and a manual button is a second, weaker path to it needing its own authorisation, audit and R2 reconciliation. ⚠️ The same ruling requires a follow-up **verifying the automatic path actually works** — folded into the deferred GDPR revisit. Until that lands, this row's guarantee is asserted rather than proven. See [Deliberate exclusions](#deliberate-exclusions--features-we-decided-not-to-build). |

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

#### US-8.6 -- See What Your Own Data Reveals About You

| Dimension | Detail |
|-----------|--------|
| **Summary** | A radical-transparency surface (ADR-019 §3a): show a user the inferences the platform can draw from their own reading data. Retro-story of record for the shipped Insights surface. |
| **Phase** | Cross-cutting (GDPR / transparency, ADR-019 §3a) |
| **Status** | Built (shipped in #242, no prior story file) |
| **Implementation** | `Stacks.Insights`; `GET /api/me/inferences` → `StacksWeb.MeInferenceController.index`. Frontend `Page.Insights` (and `Page.CostTransparency`). Reads own `Shelving.Placement`/`PlacementHistory`/`Bookshelf`. Owner-only linked-accounts de-anonymisation view is explicitly NOT built. |

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
| **Backend (Phoenix)** | `Stacks.Partners` context -- `register/1`, `approve/1`, `decline/1`, `suspend/1`. `StacksWeb.PartnerRegistrationController.create/2` (`POST /api/partners/register`); approval/decline/suspend live on `StacksWeb.PartnerController`. API key generation on approval (32-byte random hex, Argon2 hash stored). Event emission: `partner.registered`, `partner.approved`. |
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
| **Backend (Phoenix)** | `Stacks.Partners.Inventory` context -- `sync/2` (upsert/remove). `StacksWeb.PartnerInventoryController`. Schema validation via Protobuf-generated JSON schema (`InventorySyncRequest`). Event emission: `inventory.updated`. ISBN resolution via existing `Stacks.Books.ISBNResolver` for unknown ISBNs. |
| **Database** | **Write:** `partner_inventory` (isbn, price_cents, currency, condition, quantity). **Read:** `books` (ISBN lookup). **Write:** `event_log`. |
| **Jobs (Oban)** | `Stacks.Workers.PartnerISBNResolveJob` -- resolve unknown ISBNs from partner inventory. Reuses existing ISBN pipeline. |
| **External Services** | Open Library, Google Books (for unknown ISBN resolution). |
| **dbt Models** | `stg_partner_inventory`, `int_partner_availability`, `mart_partner_stock_coverage`. |
| **Infrastructure** | Protobuf schema (`proto/stacks/internal/v1/partner.proto`). |
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
| **Backend (Phoenix)** | `Stacks.Partners.Inventory.CSVImport` -- parse, validate per-row, generate preview, then delegate to `sync/2` on confirmation. `StacksWeb.PartnerInventoryController.import/2` (dashboard action on the same controller). |
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
| **Backend (Phoenix)** | `Stacks.Partners.Events` context -- `create/2`, `update/2`, `cancel/1`. `StacksWeb.PartnerEventController`. Schema validation via Protobuf (`PartnerEvent`). Event emission: `event.created`. Auto-archive past events via scheduled job. |
| **Database** | **Write:** `partner_events` (title, event_type, event_date, location, related_isbns). **Write:** `event_log`. |
| **Jobs (Oban)** | `Stacks.Workers.ArchivePartnerEventsJob` -- scheduled daily, archives past events. |
| **External Services** | None. |
| **dbt Models** | `stg_partner_events`, `int_partner_event_calendar`. |
| **Infrastructure** | Protobuf schema (`proto/stacks/internal/v1/partner.proto`). |
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
| **Backend (Phoenix)** | Same context and controller as US-9.3.1 (`StacksWeb.PartnerEventController` — dashboard form actions live on the same controller). |
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
| **Backend (Phoenix)** | `Stacks.Partners.Spaces` context -- `register/2`, `update/2`. `StacksWeb.PartnerController` (space actions). Schema validation via Protobuf (`Space`). Event emission: `space.registered`. Owner approval for first submission. |
| **Database** | **Write:** `partner_spaces` (name, type, address, amenities, opening_hours, links). **Write:** `event_log`. |
| **Jobs (Oban)** | None. |
| **External Services** | None. |
| **dbt Models** | `stg_partner_spaces`. |
| **Infrastructure** | Protobuf schema (`proto/stacks/internal/v1/partner.proto`). |
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
| **Backend (Phoenix)** | `Stacks.Partners.Metrics` context -- aggregate queries on `event_log` filtered by partner. Counts rounded to nearest 10. `StacksWeb.PartnerController` (metrics action). |
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
| **Backend (Phoenix)** | `Stacks.Partners.update_profile/2` -- partitions fields into immediate-effect (description, hours, website, logo) and approval-required (name, address). Approval-required changes create a pending update visible to owner. `StacksWeb.PartnerController` (profile action). |
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

### 10. Social Graph & Visibility

---

#### US-10.1.1 -- Set Profile Visibility

| Dimension | Detail |
|-----------|--------|
| **Summary** | Set the visibility of one's profile (public / group / private), establishing the ceiling that every shelf, placement, and post is clamped to. |
| **Phase** | Phase 6 (Social Graph & Visibility) |
| **Status** | Built |
| **Implementation** | `PUT /api/settings/profile_visibility` → `StacksWeb.UserSettingsController.update_profile_visibility`; ceiling enforced by `Stacks.Visibility.resolve/2`. Frontend `Page.Settings.Privacy`. Recap via `Stacks.Workers.VisibilityRecapJob`. |

---

#### US-10.1.2 -- Block a User

| Dimension | Detail |
|-----------|--------|
| **Summary** | Block another user so neither party sees the other's content or interactions; filtering is silent and bidirectional. |
| **Phase** | Phase 6 (Social Graph & Visibility) |
| **Status** | Built |
| **Implementation** | `POST /api/users/:id/block`, `DELETE /api/users/:id/block`, `GET /api/settings/blocked-users` → `Stacks.Social` (`op.user_blocks`, `Stacks.Social.Group`/blocks). Frontend `Page.Settings.Privacy`. |

---

#### US-10.2.1 -- Set Bookshelf Visibility

| Dimension | Detail |
|-----------|--------|
| **Summary** | Set per-bookshelf visibility and grant specific groups access, clamped to the profile ceiling. |
| **Phase** | Phase 6 (Social Graph & Visibility) |
| **Status** | Built |
| **Implementation** | `PUT /api/bookshelves/:bookshelf_name/visibility`, `DELETE /api/bookshelves/:bookshelf_id/grants` → `Stacks.Shelving` (+ `op.visibility_grants`). Frontend `Page.Settings.Privacy` / `Page.Settings.Consent`. |

---

#### US-10.2.2 -- Override Placement Visibility

| Dimension | Detail |
|-----------|--------|
| **Summary** | Override the visibility of a single placed book, more restrictive than its shelf, still clamped to the ceiling. |
| **Phase** | Phase 6 (Social Graph & Visibility) |
| **Status** | Built |
| **Implementation** | `PUT /api/placements/:id/visibility` → `StacksWeb.BookshelfPlacementController.update_visibility`; resolution via `Stacks.Visibility.resolve/2` / `viewable`. |

---

#### US-10.2.3 -- Set Blog Post Visibility

| Dimension | Detail |
|-----------|--------|
| **Summary** | Set the visibility of a blog post (public / group / private) at publish time, clamped to the author's profile ceiling. |
| **Phase** | Phase 6 (Social Graph & Visibility) |
| **Status** | Built |
| **Implementation** | `POST /api/blog/posts/:id/publish`, `PUT /api/blog/posts/:id` → `Stacks.Blog`; visibility via `Stacks.Visibility`. Frontend `Page.Blog.Editor`. |

---

#### US-10.3.1 -- Preview Content Visibility (View-As)

| Dimension | Detail |
|-----------|--------|
| **Summary** | Preview one's own content as another perspective (public / a specific group) would see it, to check visibility before sharing. |
| **Phase** | Phase 6 (Social Graph & Visibility) |
| **Status** | Built |
| **Implementation** | `StacksWeb.Plugs.ViewAsPlug` — parses the perspective in the router pipeline (Phase 1) and authorises via `authorize_view_as/2` in the controller (Phase 2). |

---

#### US-10.4.1 -- Search Engine Privacy

| Dimension | Detail |
|-----------|--------|
| **Summary** | Keep private and group-scoped content out of search-engine indexes; only public content is indexable. |
| **Phase** | Phase 6 (Social Graph & Visibility) |
| **Status** | Built |
| **Implementation** | `StacksWeb.Plugs.SecurityHeaders` (noindex headers on non-public responses); visibility source of truth `Stacks.Visibility.resolve/2`. |

---

#### US-10.5.1 -- Claim a Public Handle

| Dimension | Detail |
|-----------|--------|
| **Summary** | Every user has a unique public handle keying their profile at `/u/:handle`; auto-generated at registration and editable in Settings. A handle is not PII. |
| **Phase** | Phase 6 (Social Graph & Visibility) |
| **Status** | Built |
| **Implementation** | `PUT /api/settings/profile` (accepts `handle` alongside `display_name`/`website_url`); handle also returned by `GET /api/auth/me` and login. Auto-generated at registration; validated (3–30 chars, `[a-z0-9_]`, reserved-word check). No new endpoint. |

---

#### US-10.5.2 -- View a Reader's Public Profile

| Dimension | Detail |
|-----------|--------|
| **Summary** | View another reader's public profile at `/u/:handle`, showing only content visible to the viewer. |
| **Phase** | Phase 6 (Social Graph & Visibility) |
| **Status** | Built |
| **Implementation** | `GET /api/u/:handle` → `StacksWeb.ProfileController.show`; per-viewer filtering via `Stacks.Visibility.viewable`. Frontend `Page.Profile`. Optional-auth read model (#210). |

---

#### US-10.5.3 -- Browse a Reader's Bookshelf

| Dimension | Detail |
|-----------|--------|
| **Summary** | Browse a named bookshelf on another reader's public profile, filtered to what the viewer may see. |
| **Phase** | Phase 6 (Social Graph & Visibility) |
| **Status** | Built |
| **Implementation** | `GET /api/u/:handle/bookshelves/:bookshelf_name` → `StacksWeb.ProfileController.shelf`. Frontend `Page.Bookshelf` (public-view mode). |

---

#### US-10.5.4 -- Discover Readers

| Dimension | Detail |
|-----------|--------|
| **Summary** | Search for other readers by display name / handle to find their public profiles. |
| **Phase** | Phase 6 (Social Graph & Visibility) |
| **Status** | Built |
| **Implementation** | `GET /api/search/users` → `StacksWeb.UserSearchController.index` (hardened as an enumeration surface, #210). |

---

### 11. Groups (new additions)

---

#### US-11.1.1 -- Create a Group

| Dimension | Detail |
|-----------|--------|
| **Summary** | Create a group with one of three sharing models: close friends (bidirectional), broadcast (owner → members), or subscription (opt-in followers). |
| **Phase** | Phase 6 (Social Graph & Visibility) |
| **Status** | Built |
| **Implementation** | `POST /api/groups` → `StacksWeb.GroupController.create`; `GET /api/groups/:id` → `.show`. Schema `Stacks.Social.Group` (`op.groups`). |

---

#### US-11.1.2 -- Invite Members to a Group

| Dimension | Detail |
|-----------|--------|
| **Summary** | Invite a specific platform user to a group; the invitee accepts or declines, and declines are silent. |
| **Phase** | Phase 6 (Social Graph & Visibility) |
| **Status** | Built |
| **Implementation** | `POST /api/groups/:group_id/invitations` → `StacksWeb.GroupMemberController.invite`; `.../:id/accept` and `.../:id/decline`. Schemas `Stacks.Social.GroupInvitation` / `GroupMember`. |

---

#### US-11.1.3 -- Leave a Group

| Dimension | Detail |
|-----------|--------|
| **Summary** | Leave a group; the owner is not notified and the group's content becomes invisible to the leaver. |
| **Phase** | Phase 6 (Social Graph & Visibility) |
| **Status** | Built |
| **Implementation** | `DELETE /api/groups/:group_id/leave` → `StacksWeb.GroupMemberController.leave`. |

---

#### US-11.1.4 -- Manage Group Members

| Dimension | Detail |
|-----------|--------|
| **Summary** | Owner reviews the member list and removes members (silently); for subscription groups, accepts or ignores follow requests. |
| **Phase** | Phase 6 (Social Graph & Visibility) |
| **Status** | Built |
| **Implementation** | `DELETE /api/groups/:group_id/members/:user_id` → `StacksWeb.GroupMemberController.remove`. Member list visible to owner only. |

---

#### US-11.1.5 (new) -- Group Content Feed

| Dimension | Detail |
|-----------|--------|
| **Summary** | Group pages show a reverse-chronological feed of blog posts and shelf activity from group members. Content respects visibility rules. Feed behaviour varies by group type (close_friends: all members contribute; broadcast/subscription: owner only). |
| **Phase** | Phase 6 (Social Graph & Visibility) |

| Layer | Components |
|-------|------------|
| **Frontend (Elm)** | `Page.Group.Feed` module — card-based feed. `Components.FeedCard.BlogPost` (title, author, first two lines, date). `Components.FeedCard.ShelfActivity` ("[Name] added [Title] to Reading Pile" with spine thumbnail). Strict chronological order, no algorithmic ranking. Pagination at 20 items. |
| **Backend (Phoenix)** | `Stacks.Groups.Feed` context — `get_feed/2` (group_id, pagination). Queries `blog_posts` and `bookshelf_placement_history` for group members, filtered by visibility ceiling + block filtering. For broadcast/subscription groups, filters to owner's content only. `StacksWeb.GroupController.feed/2` (`GET /api/groups/:id/feed`). |
| **Database** | **Read:** `op.groups`, `op.group_members`, `op.blog_posts` (where visibility allows), `op.bookshelf_placements`, `op.bookshelf_placement_history`, `op.books`, `op.user_blocks`. |
| **Jobs (Oban)** | None (query-time aggregation). |
| **External Services** | None. |
| **dbt Models** | `int_group_activity`. |
| **Infrastructure** | None additional. |
| **Dependencies** | US-11.1.1 (groups exist), US-10.1.1 (visibility infrastructure), US-12.1.1 (blog posts). |

---

### 12. Blog

---

#### US-12.1.1 -- Write a Blog Post

| Dimension | Detail |
|-----------|--------|
| **Summary** | Compose, save, and publish a native blog post with a chosen visibility. |
| **Phase** | Phase 7 (Blog & Comments) |
| **Status** | Built |
| **Implementation** | `POST /api/blog/posts`, `PUT /api/blog/posts/:id`, `POST /api/blog/posts/:id/publish` → `StacksWeb.BlogController`. Context `Stacks.Blog`; schema `Stacks.Blog.Post` (`op.blog_posts`). Frontend `Page.Blog.Editor`. |

---

#### US-12.1.2 -- LLM Book Associations

| Dimension | Detail |
|-----------|--------|
| **Summary** | The platform proposes books mentioned in a post (LLM-derived); the author confirms or dismisses each association. |
| **Phase** | Phase 7 (Blog & Comments) |
| **Status** | Built |
| **Implementation** | `Stacks.Workers.PostBookAssociationWorker` + `Stacks.Blog.Handlers.BlogAssociationHandler`; `PUT /api/blog/posts/:post_id/associations/:id/confirm` and `.../dismiss` → `BlogController`. Schema `Stacks.Blog.PostBookAssociation`. |

---

#### US-12.1.3 -- Browse the Blog

| Dimension | Detail |
|-----------|--------|
| **Summary** | Browse and read published blog posts the viewer is allowed to see. |
| **Phase** | Phase 7 (Blog & Comments) |
| **Status** | Built |
| **Implementation** | `GET /api/blog/posts` → `BlogController.index`, `GET /api/blog/posts/:id` → `.show`; per-viewer filtering via `Stacks.Visibility`. Frontend `Page.Blog.Post`. |

---

#### US-12.2.1 -- Use the Writing Assistant

| Dimension | Detail |
|-----------|--------|
| **Summary** | An in-editor writing assistant (chat + contextual nudges) that draws on the author's own reading data, gated by consent (#184). |
| **Phase** | Phase 7 (Blog & Comments) |
| **Status** | Built |
| **Implementation** | `POST /api/blog/posts/:id/chat`, `GET /api/blog/posts/:id/assistant/session`, `.../assistant/nudge` → `StacksWeb.BlogController`; consent-gated route pipeline (#184). Backend `Stacks.WritingAssistant` (`stacks/writing_assistant/`). Frontend `Page.Blog.Editor`. |

---

#### US-12.2.2 -- Manage Writing Assistant Data

| Dimension | Detail |
|-----------|--------|
| **Summary** | View and delete the writing-assistant sessions and the derived data the assistant holds about the user. |
| **Phase** | Phase 7 (Blog & Comments) |
| **Status** | Built |
| **Implementation** | `GET /api/writing-assistant/sessions`, `DELETE /api/writing-assistant/sessions/:id` → writing-assistant controller; schema `Stacks.AI.BlogAssistantSession` (`gen/writing_assistant/session.ex`). Frontend `Page.Settings.WritingAssistant`. GDPR-covered derived data. |

---

### 13. Comments & Marketplace Q&A

---

#### US-13.1.1 -- Comment on a Blog Post

| Dimension | Detail |
|-----------|--------|
| **Summary** | Leave threaded plain-text comments on a visible blog post; authors can delete any comment on their post, commenters their own. |
| **Phase** | Phase 7 (Blog & Comments) |
| **Status** | Built |
| **Implementation** | `GET/POST /api/posts/:post_id/comments`, `DELETE /api/comments/:id` → `StacksWeb.CommentController`. Schema `Stacks.Blog.PostComment` (`gen/blog/post_comment.ex`, migration `create_post_comments`). |

---

#### US-13.1.2 -- Block Filtering in Comments

| Dimension | Detail |
|-----------|--------|
| **Summary** | Comments from (or visible to) blocked users are filtered per-viewer at render time; a blocked root collapses its sub-thread silently. |
| **Phase** | Phase 7 (Blog & Comments) |
| **Status** | Built |
| **Implementation** | Per-viewer filtering in `StacksWeb.CommentController.index`, using `Stacks.Social` block relationships. No placeholder markers. |

---

#### US-13.2.1 -- Ask a Question on a Listing

| Dimension | Detail |
|-----------|--------|
| **Summary** | Post a public question on a marketplace listing that the seller can answer, functioning as a per-listing FAQ (subject to block filtering). |
| **Phase** | Phase 5 (Marketplace) |
| **Status** | Not built — spec only (no Q&A route/schema in `apps/core`). |
| **Implementation** | Planned: public Q&A thread on the listing detail surface; depends on the listings machinery (US-7.1.1, built) and block filtering (US-10.1.2, built). |

---

#### US-13.2.2 -- Private Offer Thread

| Dimension | Detail |
|-----------|--------|
| **Summary** | A private buyer↔seller message/offer thread on a listing, with accept/decline/counter, moving the listing to pending on acceptance. |
| **Phase** | Phase 5 (Marketplace) |
| **Status** | Not built — spec only. The `op.offer_threads` / `op.offer_messages` tables exist but are unused (see [ADR 013](decisions/013-marketplace-classifieds-first.md)); payments/offers deferred. |
| **Implementation** | Planned on the existing (currently-unused) offer tables; depends on US-7.1.1 (listings, built). |

---

### 14. Authentication

---

#### US-14.1.1 -- Register a New Account

| Dimension | Detail |
|-----------|--------|
| **Summary** | First user becomes owner. Guardian JWT, Argon2 password hashing. |
| **Phase** | Phase 1 (MVP) |

| Layer | Components |
|-------|------------|
| **Frontend (Elm)** | `Page.Login` module (registration form). Types: `User`, `RemoteData`. |
| **Backend (Phoenix)** | `Stacks.Accounts` context -- `Accounts.register/1`. `StacksWeb.AuthController.register/2`. Guardian JWT token generation. |
| **Database** | **Write:** `op.users`, `op.audit_log`. |
| **Dependencies** | None (foundational). |

---

#### US-14.2.1 -- Sign In to an Existing Account

| Dimension | Detail |
|-----------|--------|
| **Summary** | Email + password login, JWT token returned. |
| **Phase** | Phase 1 (MVP) |

| Layer | Components |
|-------|------------|
| **Frontend (Elm)** | `Page.Login` module (login form). |
| **Backend (Phoenix)** | `Stacks.Accounts` context -- credential verification with Argon2. `StacksWeb.AuthController.login/2`. Guardian JWT signing. |
| **Database** | **Read:** `op.users`. **Write:** `op.audit_log`. |
| **Dependencies** | US-14.1.1 (account must exist). |

---

#### US-14.1.2 (new) -- First-Time Onboarding Flow

| Dimension | Detail |
|-----------|--------|
| **Summary** | The **D2 flow** — a 4-step guided overlay after first registration: **Welcome → Upload your first book → Consent → Done**. The Upload step is a *real* US-1.1.1 upload; the Consent step collects analytics + writing-assistant consent (`Stacks.GDPR.Consent`, timestamps preserved). ⚠️ **Steps are data-driven** — an ordered list the view folds over, not hardcoded branches, so a step can be added/reordered/removed without rewriting the flow (reviewed acceptance criterion). Dismissable; Skip persists by the same path as advance. Maps client steps onto the server `onboarding_steps` model (#149). |
| **Phase** | Phase 1 (MVP) |

| Layer | Components |
|-------|------------|
| **Frontend (Elm)** | `Components.OnboardingOverlay` — fullscreen overlay whose flow is **`steps : List Step` + `currentIndex`** (descriptors `Welcome | UploadFirstBook | Consent | Done`), NOT a hardcoded enum-transition chain; progress dots derive from list length. The Upload step embeds the real US-1.1.1 upload/identify sub-view; the Consent step embeds the consent toggles (`POST /api/gdpr/consent`). "Skip" always visible and persists identically to advancing. |
| **Backend (Phoenix)** | Reuses `StacksWeb.UploadController.create/2` + the confirm/placement flow for the inline upload, and `StacksWeb.GDPRController.update_consent/2` for the Consent step. Server step granularity via `PUT /api/onboarding/step/:step` / `GET /api/onboarding/status` and `Stacks.Accounts.complete_onboarding_step/2` (#149); `onboarding_completed` is a `GENERATED ALWAYS AS` column. |
| **Database** | **Write:** `op.users` (`onboarding_steps`, and `consent_analytics`/`consent_writing_assistant` + `_at` timestamps if granted). Plus all writes from US-1.1.1 if the user uploads a book. |
| **Jobs (Oban)** | Same as US-1.1.1 if a book is uploaded; `WritingAssistantDataPurgeWorker` only on a later revoke (not from onboarding grants). |
| **External Services** | Same as US-1.1.1 if a book is uploaded (Modal, Open Library, Google Books). |
| **dbt Models** | `int_onboarding_completion_rate`. |
| **Infrastructure** | None additional. |
| **Dependencies** | US-14.1.1 (registration), US-1.1.1 (upload flow for the Upload step), US-8.3 (consent for the Consent step), #149 (server step model). |

---

#### US-14.3.1 -- Authenticated Navigation State

| Dimension | Detail |
|-----------|--------|
| **Summary** | Elm SPA stores JWT, shows user-specific navigation when authenticated. |
| **Phase** | Phase 1 (MVP) |

| Layer | Components |
|-------|------------|
| **Frontend (Elm)** | `Types.User`, `Api` module (token storage), navigation state management. |
| **Backend (Phoenix)** | `StacksWeb.AuthController.me/2` -- returns current user from JWT. `StacksWeb.Plugs.AuthPipeline`. |
| **Database** | **Read:** `op.users`. |
| **Dependencies** | US-14.2.1 (must be logged in). |

---

#### US-14.3.2 -- Session Expiry and Token Refresh

| Dimension | Detail |
|-----------|--------|
| **Summary** | 24h access token, 7d refresh token. Graceful redirect to login on expiry. |
| **Phase** | Phase 1 (MVP) |

| Layer | Components |
|-------|------------|
| **Frontend (Elm)** | Token expiry detection, automatic redirect to login page. |
| **Backend (Phoenix)** | Guardian token lifecycle. Refresh token handling. |
| **Database** | **Read:** `op.users`. |
| **Dependencies** | US-14.2.1. |

---

#### US-14.3.3 (new) -- Log Out

| Dimension | Detail |
|-----------|--------|
| **Summary** | Display name in nav is a dropdown with "Settings" and "Sign Out". Sign out clears JWT, resets Elm state, redirects to sign-in page. |
| **Phase** | Phase 1 (MVP) |

| Layer | Components |
|-------|------------|
| **Frontend (Elm)** | `Components.UserMenu` — dropdown toggled by clicking display name. Two items: "Settings" (navigates to `/settings`) and "Sign Out" (clears JWT via `clearAuth` port, resets model, redirects). `userMenuOpen : Bool` in model. |
| **Backend (Phoenix)** | None additional (sign out is client-side JWT removal). |
| **Database** | **Write:** `op.audit_log` (logout event). |
| **Dependencies** | US-14.3.1 (authenticated state), US-17.1.1 (settings page must exist). |

---

#### US-14.4.1 -- Reset a Forgotten Password

| Dimension | Detail |
|-----------|--------|
| **Summary** | Request a password-reset link by email, then set a new password via a tokened link. |
| **Phase** | Phase 1 (extended) |
| **Status** | Built |
| **Implementation** | `POST /api/auth/forgot-password` → `StacksWeb.AuthController.forgot_password`; `POST /api/auth/reset-password` → `.reset_password`. Frontend `Page.ForgotPassword`, `Page.ResetPassword`. |

---

#### US-14.4.2 -- Resend Confirmation Email

| Dimension | Detail |
|-----------|--------|
| **Summary** | Re-request the account-confirmation email if the original was lost or expired. |
| **Phase** | Phase 1 (extended) |
| **Status** | Built |
| **Implementation** | `POST /api/auth/resend-confirmation` → `StacksWeb.AuthController.resend_confirmation`; `GET /api/auth/confirm/:token` confirms. Frontend `Page.Login`. |

---

#### US-14.1.3 -- Invite-Only Registration (Closed Beta)

| Dimension | Detail |
|-----------|--------|
| **Summary** | Gate registration behind an invite code during closed beta; the owner issues and revokes invites, and the SPA reflects invite-only mode via `/api/config`. |
| **Phase** | Phase 1 (extended) |
| **Status** | Not built — spec only (`Stacks.Accounts.Invites`, `Page.Admin.Invites`, invite routes are specified but absent). Builds on shipped `Stacks.Accounts.register` and `/api/config`. |
| **Implementation** | Planned: `POST /api/auth/register` (invite-gated), `GET /api/auth/invite/:code`, `GET/POST/DELETE /api/admin/invites` → invites admin; `Page.Admin.Invites`, `Page.Login`. |

---

#### US-14.5.1 -- If You Never Confirm, Your Account Is Erased Within a Day

| Dimension | Detail |
|-----------|--------|
| **Summary** | An account that is never email-confirmed is fully erased within ~24h, so abandoned/unverified registrations do not accumulate personal data. Retro-story of record. |
| **Phase** | Cross-cutting (auth hygiene / GDPR) |
| **Status** | Built (shipped in #124 A2 / #179 / #373, no prior story file) |
| **Implementation** | `Stacks.Workers.ExpiredUnverifiedAccountsJob` runs erasure through `Stacks.GDPR.Deletion.delete_user_data/1`; companion sweeps `Stacks.Workers.GuardianTokenSweepJob`, `Stacks.Workers.CacheSweepJob`, `Stacks.Workers.ImageRetentionJob`. Registration/confirmation via `StacksWeb.AuthController` (`POST /api/auth/register`, `.../resend-confirmation`), `Stacks.Accounts.Guardian`. |

---

### 15. Home & Navigation

---

#### US-15.1.1 -- View the Home Page

| Dimension | Detail |
|-----------|--------|
| **Summary** | Two faces of one route (`/`), no forced redirect. **Unauthenticated:** a welcoming static landing (title, subtitle, About + Marketplace CTAs, #235). **Authenticated:** routes the reader into their collection — proposed widget set (confirmed in 8c, #318): a shelf preview, a continue-reading entry point, and a persistent Add-Book CTA. Resolves the former "authed home does nothing useful" drift. |
| **Phase** | Phase 1 (MVP) |

| Layer | Components |
|-------|------------|
| **Frontend (Elm)** | Home view branches on auth state. Unauthenticated → static landing (title, subtitle, `home__link--about` → `/about`, `home__link--marketplace` → `/marketplace`). Authenticated → collection-routing home (shelf preview in the shelf-room aesthetic, continue-reading into the Reading Pile, persistent primary Add-Book CTA); holds a small `RemoteData` preview field. Exact widget composition finalised in 8c (#318). |
| **Backend (Phoenix)** | Unauthenticated → none (SPA catch-all serve). Authenticated → a lightweight shelf-preview read reusing existing bookshelf reads (`GET /api/bookshelves/:name`, US-1.2.1/US-1.2.4); no bespoke endpoint required. |
| **Database** | Unauthenticated → none. Authenticated → **Read:** `op.bookshelves`, `op.bookshelf_placements` for the shelf preview / continue-reading data. |
| **Dependencies** | US-14.3.1 (auth state selects the variant), US-1.2.1/US-1.2.4 (shelf reads reused by the preview), US-1.1.1 (Add-Book CTA target). |

---

#### US-15.2.1 -- Navigate Between Sections via the Top Navigation Bar

| Dimension | Detail |
|-----------|--------|
| **Summary** | Persistent top navigation. Authenticated: Library, AntiLibrary, WishList, Reading Pile, Looking for a Home, Search, Add Book, plus display name dropdown (Settings + Sign Out). Unauthenticated: Costs, Sign In. |
| **Phase** | Phase 1 (MVP) |

| Layer | Components |
|-------|------------|
| **Frontend (Elm)** | `Navigation.Route` module. Main.elm handles URL routing via `Browser.application`. `Components.UserMenu` dropdown on display name (US-14.3.3). Nav items conditionally rendered based on `Maybe User` in model. |
| **Backend (Phoenix)** | `CoreWeb.Router` catch-all route serves Elm SPA for all non-API paths. |
| **Database** | None. |
| **Dependencies** | US-14.3.1 (auth state determines nav items), US-14.3.3 (user menu dropdown). |

---

#### US-15.2.2 -- Swipe Navigation Between Bookshelves (Mobile)

| Dimension | Detail |
|-----------|--------|
| **Summary** | Touch swipe gestures to navigate between bookshelves on mobile. |
| **Phase** | Phase 1 (MVP) |

| Layer | Components |
|-------|------------|
| **Frontend (Elm)** | `Navigation.SwipeNavigation` module. Touch event handling via ports or subscriptions. |
| **Backend (Phoenix)** | None (client-side only). |
| **Database** | None. |
| **Dependencies** | US-1.2.5 (shelf navigation). |

---

#### US-15.3.1 -- View the Platform Footer

| Dimension | Detail |
|-----------|--------|
| **Summary** | Footer with links to settings, GDPR pages, and project info. |
| **Phase** | Phase 1 (MVP) |

| Layer | Components |
|-------|------------|
| **Frontend (Elm)** | Footer component in Main.elm view. |
| **Backend (Phoenix)** | None (static content). |
| **Database** | None. |
| **Dependencies** | None. |

---

#### US-15.4.1 -- Platform FAQ

| Dimension | Detail |
|-----------|--------|
| **Summary** | A platform-info FAQ page reached via nav/footer, answering the questions a stranger asks before trusting the platform. Launch Milestone B; a new member of the existing epic 15 (15.1–15.3 taken). |
| **Phase** | Phase 1 (extended) |
| **Status** | Not built — spec only (`Page.Faq` absent; `/api/config` / `Page.About` exist and would be reused). |
| **Implementation** | Planned: `Page.Faq` (static content surface, reusing `curator-desk`/`about__*` styles), reachable from nav/footer; server flags via `GET /api/config` → `StacksWeb.ConfigController.show`. Fourteen new CSS classes must ship with rules in the same change (`scripts/check-css.sh`). |

---

#### US-15.5.1 -- Beta Feedback Channel

| Dimension | Detail |
|-----------|--------|
| **Summary** | An in-app feedback channel for beta users to submit feedback, with an owner-side triage/status view. A new member of the existing epic 15, reached via nav/footer. |
| **Phase** | Phase 1 (extended) |
| **Status** | Not built — spec only (`Stacks.Feedback`, `Page.Admin.Feedback` absent). |
| **Implementation** | Planned: `POST /api/feedback` → `Stacks.Feedback.submit`; `GET /api/admin/feedback`, `PUT /api/admin/feedback/:id/status` → `StacksWeb.FeedbackAdminController`; `Stacks.Notifications.FeedbackHandler`, `Stacks.Workers.FeedbackRetentionJob`; frontend `Page.Admin.Feedback`. |

---

### 16. Error Handling

---

#### US-16.1.1 -- View the 404 Not Found Page

| Dimension | Detail |
|-----------|--------|
| **Summary** | Themed 404 page matching the dark-academic aesthetic. |
| **Phase** | Phase 1 (MVP) |

| Layer | Components |
|-------|------------|
| **Frontend (Elm)** | 404 variant in route handling. Themed error display. |
| **Backend (Phoenix)** | `CoreWeb.ErrorJSON` for API 404s. SPA catch-all handles client-side 404s. |
| **Database** | None. |
| **Dependencies** | US-15.2.1 (routing). |

---

#### US-16.2.1 -- Handle Network Failures Gracefully

| Dimension | Detail |
|-----------|--------|
| **Summary** | Display helpful error messages when API calls fail. Retry where appropriate. |
| **Phase** | Phase 1 (MVP) |

| Layer | Components |
|-------|------------|
| **Frontend (Elm)** | `Types.RemoteData` handles Loading/Success/Failure states. Error display components. |
| **Backend (Phoenix)** | Structured error responses from all controllers. |
| **Database** | None. |
| **Dependencies** | None. |

---

#### US-16.3.1 -- Handle Unauthenticated Access to Protected Pages

| Dimension | Detail |
|-----------|--------|
| **Summary** | Redirect to login when accessing protected routes without valid JWT. |
| **Phase** | Phase 1 (MVP) |

| Layer | Components |
|-------|------------|
| **Frontend (Elm)** | Route guard in Main.elm — redirects to login if no token. |
| **Backend (Phoenix)** | `StacksWeb.Plugs.AuthPipeline` returns 401 for unauthenticated API requests. |
| **Database** | None. |
| **Dependencies** | US-14.2.1, US-15.2.1. |

---

### 17. Settings

---

#### US-17.1.1 -- Settings Index Page

| Dimension | Detail |
|-----------|--------|
| **Summary** | Central settings hub at `/settings` with sidebar navigation linking to all sub-pages: Profile, Password, Privacy, Consent, Notifications, Audit Log. Accessible from display name dropdown. Data export and account deletion have **no dedicated sub-page** — both are actions on the Privacy sub-page (see US-8.1.1 / US-8.1.2). Age verification has no settings page either (ADR-020 §2). |
| **Phase** | Phase 1 (MVP) |

| Layer | Components |
|-------|------------|
| **Frontend (Elm)** | `Page.Settings` module with sidebar navigation. Sub-pages (the six modules that actually exist under `frontend/src/Page/Settings/`): `Page.Settings.Profile` (US-17.2.1), `Page.Settings.Password` (US-17.2.3), `Page.Settings.Privacy` (hosts export + delete-account actions — US-8.1.1 / US-8.1.2), `Page.Settings.Consent` (US-8.1.3), `Page.Settings.Notifications` (US-17.3.1), `Page.Settings.AuditLog` (US-8.1.5). No `AgeVerification`, `Export`, or `Delete` module exists. Sidebar highlights active sub-page. On mobile, sidebar collapses to dropdown. |
| **Backend (Phoenix)** | `StacksWeb.UserSettingsController` with routes for each sub-page. |
| **Database** | **Read:** `op.users`. |
| **Dependencies** | US-14.3.1 (authenticated), US-14.3.3 (accessible from user menu dropdown). |

---

#### US-17.2.1 (new) -- View and Edit Profile

| Dimension | Detail |
|-----------|--------|
| **Summary** | User edits display name, email, and website URL. Email changes require password confirmation. |
| **Phase** | Phase 1 (MVP) |

| Layer | Components |
|-------|------------|
| **Frontend (Elm)** | `Page.Settings.Profile` — form with Display Name, Email, Website URL fields. Inline validation. Save button with confirmation toast. |
| **Backend (Phoenix)** | `Stacks.Accounts.update_profile/2`. Email changes require `current_password` param. `StacksWeb.UserSettingsController.update_profile/2` (`PUT /api/settings/profile`). |
| **Database** | **Write:** `op.users` (display_name, email, website_url), `op.audit_log`. |
| **Dependencies** | US-17.1.1 (settings hub). |

---

#### US-17.2.2 (new) -- Set Location

| Dimension | Detail |
|-----------|--------|
| **Summary** | User sets country and city for Third Spaces, partner inventory, and event filtering. Explicit setting, not device geolocation. Saving triggers geographic discovery sweep. |
| **Phase** | Phase 1 (MVP) |

| Layer | Components |
|-------|------------|
| **Frontend (Elm)** | Location section within `Page.Settings.Profile` — Country dropdown (ZA at top), City text input with autocomplete. Explanation: "We use your location to show nearby bookshops, events, and reading spaces." Post-save note: "We'll start looking for spaces near [City]." |
| **Backend (Phoenix)** | `Stacks.Accounts.update_location/2`. Emits `user.location_updated` event on change, triggering `GeographicDiscoveryJob` (US-2.5.2). `StacksWeb.UserSettingsController.update_profile/2` (same endpoint as US-17.2.1). |
| **Database** | **Write:** `op.users` (country_code, city), `op.event_log` (user.location_updated). |
| **Jobs (Oban)** | `GeographicDiscoveryJob` triggered by event. |
| **Dependencies** | US-17.1.1 (settings hub), US-2.5.2 (geographic sweep). |

---

#### US-17.2.3 (new) -- Change Password

| Dimension | Detail |
|-----------|--------|
| **Summary** | Current password + new password (twice) form. Argon2 hashing. |
| **Phase** | Phase 1 (MVP) |

| Layer | Components |
|-------|------------|
| **Frontend (Elm)** | `Page.Settings.Password` — three fields: Current Password, New Password, Confirm. Strength indicator. |
| **Backend (Phoenix)** | `Stacks.Accounts.change_password/2`. Verifies current password before applying. `StacksWeb.UserSettingsController.change_password/2` (`PUT /api/settings/password`). Rate limit: 3/min. |
| **Database** | **Write:** `op.users` (password_hash), `op.audit_log`. |
| **Dependencies** | US-17.1.1 (settings hub). |

---

#### US-17.3.1 (new) -- Email Notification Preferences

| Dimension | Detail |
|-----------|--------|
| **Summary** | Toggle email notifications per category. Quiet by default. ToS changes always sent (non-toggleable). |
| **Phase** | Phase 1 (MVP) |

| Layer | Components |
|-------|------------|
| **Frontend (Elm)** | `Page.Settings.Notifications` — list of notification categories with toggles. ToS toggle is locked (always on). Auto-save on toggle change. Philosophy note in italic serif. |
| **Backend (Phoenix)** | `Stacks.Accounts.update_notification_preferences/2`. `StacksWeb.UserSettingsController.update_notifications/2` (`PUT /api/settings/notifications`). |
| **Database** | **Write:** `op.users` (notify_wishlist_availability, notify_marketplace, notify_group_invitations, notify_event_matches). |
| **Jobs (Oban)** | `Stacks.Workers.EmailNotificationJob` — checks user preferences before sending any email. Queue: `notifications`, concurrency: 3. `Stacks.Workers.WishListAvailabilityJob` — triggered by partner inventory ingestion or marketplace listing creation. Checks WishList ISBNs against new availability. |
| **External Services** | Resend / Postmark (transactional email). |
| **dbt Models** | `int_notification_delivery_rate`. |
| **Dependencies** | US-17.1.1 (settings hub). |

---

### 18. Looking for a Home Shelf

---

#### US-18.1.1 -- Browse the Looking for a Home Shelf

| Dimension | Detail |
|-----------|--------|
| **Summary** | Fifth bookshelf with community-driven wear state. Spine wear reflects how many users across the platform have read each book (aggregate `Library` shelf placement count), not the individual user's engagement. Books can arrive from any shelf or directly from upload. Marketplace-ready in future phases. |
| **Phase** | Phase 1 (MVP) |

| Layer | Components |
|-------|------------|
| **Frontend (Elm)** | `Page.Bookshelf.LookingForHome` module. Renders as a **real room in the shelf-room family** (shared wallpaper / wood / brass-plate label / lamplight, per US-1.2.1), with a **pile-view of face-out cover cards staged inside that room** — not a flat page. Warm, transitional market-stall / windowsill character; uses `CommunityWear` for wear signalling. Room-class alignment settled by #318's "Looking-for-a-Home gets its room" treatment. |
| **Backend (Phoenix)** | `Stacks.Shelving` context, bookshelf_name `:looking_for_home`. `Stacks.Books.community_read_count/1` — reads from `wh.mart_community_read_count` to determine community wear level. `StacksWeb.BookshelfController.show/2`. |
| **Database** | **Read:** `op.bookshelves`, `op.bookshelf_placements`, `op.books`, `op.book_editions`. **Read:** `wh.mart_community_read_count` (aggregate read stats). |
| **Jobs (Oban)** | None directly. `mart_community_read_count` is refreshed by dbt on schedule. |
| **dbt Models** | `mart_community_read_count` — `SELECT book_id, COUNT(DISTINCT user_id) AS read_count FROM bookshelf_placements bp JOIN bookshelves b ON bp.bookshelf_id = b.id WHERE b.name = 'library' AND bp.removed_at IS NULL GROUP BY book_id`. |
| **Infrastructure** | None additional. |
| **Dependencies** | US-1.1.1 (books exist), US-1.2.1 (shelf infrastructure). |

---

### 19. Accessibility

---

#### US-19.1.1 (new) -- ARIA Labels for Visual Elements

| Dimension | Detail |
|-----------|--------|
| **Summary** | Every spine, shelf, overlay, and interactive element gets meaningful ARIA labels. Upload states announced via `aria-live` regions. |
| **Phase** | Phase 1 (MVP) |

| Layer | Components |
|-------|------------|
| **Frontend (Elm)** | Attributes added to existing components: `Components.Spine` gets `aria-label` ("Book: [Title] by [Author], [Pages] pages, [wear state]"). `Components.Shelf` gets `role="list"`, `aria-label` ("[Shelf Name] — N books"). Book detail overlay gets `role="dialog"` with focus trapping. Upload states use `aria-live="polite"` for progress announcements. `Components.UserMenu` dropdown labelled "User menu". |
| **Backend (Phoenix)** | API responses must include all data needed for labels: shelf name, book count per shelf, wear state as text, page count. No new endpoints — data already present in existing responses. |
| **Database** | None additional. |
| **Dependencies** | US-1.2.1–4 (shelves), US-1.3.1 (spines), US-1.3.2 (detail overlay). |

---

#### US-19.1.2 (new) -- Keyboard Navigation

| Dimension | Detail |
|-----------|--------|
| **Summary** | Full keyboard navigation: Tab between nav items → shelf content → spines. Arrow keys within shelf grid. Enter opens detail overlay. Escape closes. Skip links for main content. |
| **Phase** | Phase 1 (MVP) |

| Layer | Components |
|-------|------------|
| **Frontend (Elm)** | `Navigation.Keyboard` module — keyboard event subscriptions. `tabindex` attributes on all interactive spine elements. Arrow key handlers for shelf grid navigation. Focus management: return focus to triggering spine when overlay closes. Skip link: hidden "Skip to main content" link before navigation. Visible focus indicators styled with platform aesthetic. |
| **Backend (Phoenix)** | None (purely client-side). |
| **Database** | None. |
| **Dependencies** | US-1.2.1–4 (shelves), US-1.3.2 (detail overlay), US-19.1.1 (ARIA labels). |

---

#### US-19.2.1 (new) -- List View Toggle

| Dimension | Detail |
|-----------|--------|
| **Summary** | Toggle between spine view (visual bookshelf) and list view (sortable table of books with metadata). Preference persisted in localStorage. Better for accessibility, small screens, and information-dense browsing. |
| **Phase** | Phase 1 (MVP) |

| Layer | Components |
|-------|------------|
| **Frontend (Elm)** | `ShelfViewMode` type: `SpineView | ListView`. Toggle icon in shelf header. `Components.BookList` — table with columns: cover thumbnail, title, author, page count, date added, shelf, format indicators, wear state (text label). Sortable columns (click header). Clicking a row opens book detail overlay. Preference stored via `setViewMode` port → `localStorage`. |
| **Backend (Phoenix)** | None additional (same API data, different rendering). |
| **Database** | None (preference in localStorage). |
| **Dependencies** | US-1.2.1–4 (shelves), US-1.3.2 (detail overlay). |

---

### 20. Admin & Owner Surfaces

> New epic (Wave 10): the operator-facing surfaces that sit apart from the reader
> product. Cross-cutting admin — reached through a dedicated admin session, not the
> ordinary user menu.

---

#### US-20.1.1 -- Reach the Admin Surfaces Behind a Second Factor

| Dimension | Detail |
|-----------|--------|
| **Summary** | Admin surfaces sit behind a dedicated admin login plus a TOTP second factor; a distinct admin session (not the ordinary user JWT) authorises admin actions. Retro-story of record for the shipped MFA gate. |
| **Phase** | Cross-cutting (admin) |
| **Status** | Built (shipped in #237 / #303 / #332, no prior story file) |
| **Implementation** | `POST /api/admin/auth/login`, `.../mfa/setup`, `.../mfa/confirm`, `.../verify_mfa`, `DELETE /api/admin/auth/logout` → admin auth; `Stacks.AdminSession`, `Stacks.MFA.UserMFA` (secret in `Stacks.EncryptedBinary`). Frontend `Page.Admin.Session`. Token hygiene via `Stacks.Workers.GuardianTokenSweepJob`. |

---

#### US-20.2.1 -- Split a Wrongly Merged Edition Back Off Its Work (Owner Only)

| Dimension | Detail |
|-----------|--------|
| **Summary** | The owner un-merges an edition that was wrongly merged into a work, splitting it back onto its own work, with a required reason and an audit trail. |
| **Phase** | Cross-cutting (admin) |
| **Status** | Built |
| **Implementation** | `Stacks.DataCorrection` framework (`data_correction/unmerge_edition.ex`, `data_correction/targeted.ex`); `GET /api/admin/data_corrections`, `POST /api/admin/data_corrections/:name/target`, `.../:name/apply` (reason required) → `StacksWeb.DataCorrectionController`. Audited via `Stacks.Audit`; cache invalidated via `Stacks.Books.BookDetailCache`; re-enriched via `Stacks.Workers.EnrichBookJob`. Frontend surfaced through the admin data-corrections view. |

---

### Cross-cutting: Data Architecture — Contract-First Derived Data (ADR 010)

| Layer | Components |
|-------|------------|
| **Summary** | The data pipeline follows a **contract-first derived data** pattern (ADR 010, drawing from DDIA Ch. 4, 11, 12). Protobuf contracts enforce shape at the write boundary; the event log provides ordered history; all downstream views are purpose-built derivations that can be rebuilt from the systems of record (`op.*`, `audit.*`). This is neither star schema nor medallion — it is "one log, many derivations" with contract-enforced input. |
| **Systems of record** | `op.*` tables (OLTP, Ecto writes), `op.event_log` (append-only domain events), `audit.audit_log` (immutable, encrypted). |
| **Derived data** | `wh.stg_*` (structural projections, PII-excluded), `wh.int_*` (semantic aggregates — domain joins), `wh.mart_*` (consumer-optimised read models), ETS caches (`BookDetailCache`), search indexes (`mart_platform_searchable`), Atom feeds. |
| **Key invariant** | Every layer after `op.*` is derived and rebuildable. If the `wh` schema is dropped, `dbt run` reconstructs it. |
| **Materialisation** | Staging: `VIEW`. Intermediate: `VIEW` or `incremental`. Marts: `incremental` for hot-path (5-min), `VIEW`/`table` for cold-path (daily). Hot-path marts may use `MATERIALIZED VIEW` with `REFRESH CONCURRENTLY`. |
| **Refresh trigger** | Event-triggered selective dbt runs (event → specific model set) with daily cron as catch-all. Mapping in `Stacks.Workers.DbtRefreshJob`. |
| **Design rules** | (1) No mart without a named consumer. (2) No `SELECT *` in staging — explicit column lists. (3) Tier 3/4 data never enters `wh`. (4) Incremental models for unboundedly growing sources. |
| **References** | ADR 010, ADR 009 (proto codegen), ADR 007 (proto contracts), `docs/data-quality.md`. |

### Cross-cutting: Event-Driven Architecture

| Layer | Components |
|-------|------------|
| **Summary** | Oban-backed event bus. All significant state changes emit events to `event_log` table. Subscribers are registered at startup and notified via Oban jobs. The event log is both a system of record (immutable history) and the integration point that connects subsystems — enrichment workers, feed regeneration, dbt refresh, and caches are all event-driven (ADR 010). |
| **Affects stories** | All stories benefit. Primary consumers: US-9.2.1 (inventory events), US-9.3.1 (event events), US-9.5.1 (metrics from events), US-1.5.1 (shelf movement events), US-2.1.1–2.4.1 (enrichment fan-out). |
| **Backend (Phoenix)** | `Stacks.Events` -- `emit/1`, `replay/3`. `Stacks.Events.Registry` -- subscriber mapping. `Stacks.Events.Upcaster` -- schema version migration. `Stacks.Events.SubscriberWorker` -- Oban worker that dispatches to subscriber modules. |
| **Database** | `event_log` table (event_type, aggregate_type, aggregate_id, schema_version, payload JSONB, metadata JSONB, occurred_at, published_at). Index on (event_type, aggregate_id, occurred_at DESC). |
| **dbt Models** | `stg_event_log`, `int_event_throughput`, `mart_event_bus_health`. |
| **dbt Integration** | Events trigger selective dbt runs via `DbtRefreshJob` (e.g., `shelf.book_placed` → `mart_community_read_count`). See ADR 010 for the full event-to-model mapping. |
| **Infrastructure** | Oban queue `:events` with concurrency tuned to subscriber count. |

### Cross-cutting: Schema Contracts (Protobuf)

| Layer | Components |
|-------|------------|
| **Summary** | `.proto` files as single source of truth for all structured data contracts. `buf` for linting and breaking change detection in CI. JSON on the wire. |
| **Affects stories** | All partner stories (US-9.x), internal event bus, service-to-service contracts. |
| **Proto files** | `proto/stacks/internal/v1/` (partner, event_bus, audit, scraper, vision), `proto/stacks/common/v1/` (book, location, user, listing, marketplace, blog, etc.), `proto/stacks/api/v1/` (request/response envelopes), `proto/stacks/monitoring/v1/`, `proto/stacks/infra/v1/`. |
| **Code generation** | Elixir, Rust, Python: generated at build time, gitignored. Elm: generated JSON decoders gitignored and regenerated at build time via `scripts/gen-elm-proto.sh`. |
| **Schema codegen (Issue #080)** | `mix proto.sync` generates Ecto migrations, Ecto schemas, and dbt staging models from `.proto` messages tagged with `(stacks.persisted) = true`. `mix proto.sync --check` in CI catches drift. Covers raw ingestion tables only — domain tables remain hand-written. This is the "contract-enforced input" pillar of ADR 010 — the proto defines the shape, and the staging model is mechanically derived from that contract. See ADR 009. |
| **CI** | `buf lint proto/` + `buf breaking proto/ --against '.git#branch=main'` + `mix proto.sync --check` in every PR. |
| **Event upcasting** | `Stacks.Events.Upcaster` -- pattern-matched version transforms for old events. Same pattern as Commanded (Elixir CQRS). |

---

### Cross-cutting: Data Quality Framework

| Layer | Components |
|-------|------------|
| **Summary** | Continuous quality monitoring per data product. Source health tracking, LLM faithfulness metrics, quality trend analysis. See `docs/data-quality.md` for the full framework. |
| **Affects stories** | US-5.1 (metrics dashboard — data quality section), US-2.1.1–2.4.1 (enrichment — source health), US-12.1.2 (blog — LLM faithfulness) |
| **Backend (Phoenix)** | `Stacks.Enrichment.SourceHealth` — `record_success/2`, `record_failure/3`. Instrumented in all enrichment workers. `Stacks.Workers.RSSLivenessJob` — weekly feed health check. |
| **Database** | `op.source_health_checks` — per-source operational health with consecutive failure tracking and computed status (healthy/degraded/broken). |
| **dbt Models** | `stg_source_health_checks`, `int_source_health` (per-source status), `mart_data_quality_trend` (12-week rollup), `mart_enrichment_gaps` (missing data by cause), `mart_llm_faithfulness` (LLM output quality). |
| **Rust Scraper** | Returns `selector_match_rate` in scrape response — percentage of CSS selectors that found matches. Low rate indicates HTML structure change. |
| **Elm** | Metrics dashboard: quality trend sparklines, source health table, enrichment gap cards, LLM faithfulness indicators. |

---

## Deliberate exclusions (recorded so audits stop re-raising)

These are choices, not gaps. Each names the ruling so a future audit stops
re-raising it (and a future reader can reopen the decision rather than
rediscover it). See also the phase-level exclusions table near the top.

- **Cancel-deletion grace period** — EXCLUDED; immediate erasure stays (owner ruling, 2026-07-30). A grace window means the data still exists after the person asked for it to be gone. The doubt belongs in the confirmation flow, not behind it. See US-8.1.2.
- **Public "delete this photo" UI** — EXCLUDED publicly; the guarantee is automatic 30-day deletion (US-8.1.4, `ImageRetentionJob`). What the ruling requires instead is *verifying the auto-deletion path actually works* — that verification folds into the deferred GDPR revisit.
- **Age-gate self-service Verify affordance** — REMOVED by ADR-020 §2; provider-sourced verification is the model, and the provider flow is tracked in #069. A spec asking for a user-facing "Verify my age" button describes a withdrawn design — treat as `n/a (ADR-020 §2, #069)`.
- **Non-ISBN readables** (articles, zines, papers, video as first-class knowledge sources) — OUT OF SCOPE by the ISBN hard gate (no book enters the system without a verified ISBN). A generalisation to non-ISBN Readables would warrant its own ADR because it touches that gate; recorded as a forward-looking Phase 7 direction, not built.

---

## Quick Reference: Table-to-Story Mapping

Which user stories touch each database table:

| Table | Stories |
|-------|---------|
| `books` (works) | US-1.1.1, US-1.1.2, US-1.1.4, US-1.1.5, US-1.1.6, US-1.1.8, US-1.2.1--4, US-1.3.1, US-1.3.2, US-1.4.1, US-1.5.1--3, US-1.6.3, US-2.1.1, US-2.3.1, US-2.4.1, US-4.1.1, US-7.1.1, US-7.2.1, US-8.1.1, US-11.1.5, US-18.1.1, US-19.2.1 |
| `book_editions` | US-1.1.1, US-1.1.5, US-1.1.6, US-1.1.8, US-1.3.2, US-1.5.4, US-2.2.1, US-9.2.1, US-9.8.1, US-14.1.2, US-19.1.1, US-19.2.1 |
| `authors` | US-1.1.1, US-1.2.1--4, US-1.3.2, US-1.4.1, US-2.3.1, US-2.4.1, US-6.1.1, US-8.1.1 |
| `bookshelves` | US-1.2.1--5, US-1.4.1, US-1.5.1, US-6.1.1, US-8.1.1 |
| `bookshelf_placements` | US-1.1.5, US-1.2.1--4, US-1.3.1, US-1.3.2, US-1.4.1, US-1.5.1--3, US-1.6.4, US-1.6.5, US-2.4.1, US-6.1.1, US-8.1.1 |
| `bookshelf_placement_history` | US-1.3.1, US-1.5.1--3, US-1.6.4, US-8.1.1 |
| `review_snapshots` | US-1.3.2, US-2.1.1 |
| `price_snapshots` | US-1.3.2, US-1.4.1, US-1.5.3, US-2.2.1 (references `book_editions`, not `books`) |
| `bookstores` | US-2.2.1, US-2.2.2, US-2.4.1 |
| `bookstore_events` | US-2.4.1 |
| `third_spaces` | US-3.1.1, US-2.5.2, US-2.5.3 |
| `third_space_events` | US-3.1.1, US-2.5.2 |
| `blog_posts` | US-12.1.1, US-12.1.2, US-12.1.3, US-10.2.3, US-8.1.1 |
| `post_book_associations` | US-12.1.2 |
| `comments` | US-13.1.1, US-13.1.2, US-13.2.1 |
| `user_blocks` | US-10.1.2, US-13.1.2 |
| `groups` | US-11.1.1, US-11.1.2, US-11.1.3, US-11.1.4, US-11.1.5, US-10.2.1 |
| `group_members` | US-11.1.2, US-11.1.3, US-11.1.4, US-11.1.5 |
| `group_invitations` | US-11.1.2, US-11.1.4 |
| `visibility_grants` | US-10.2.2 |
| `uploaded_images` | US-1.1.1, US-7.1.1, US-8.1.4 |
| `audit_log` | US-1.1.3, US-1.1.4, US-2.5.1, US-4.1.1, US-4.1.2, US-5.1.1, US-7.2.1, US-7.3.1, US-8.1.1, US-8.1.2, US-8.1.3, US-8.1.5 |
| `discovered_sources` | US-2.3.1, US-2.5.1, US-2.5.2, US-2.5.3 |
| `partners` | US-9.1.1, US-9.1.2, US-9.6.1, US-9.7.1, US-9.7.2, US-9.8.1 |
| `partner_inventory` | US-9.2.1, US-9.2.2, US-9.5.1, US-9.8.1 (references `book_editions`, not `books`) |
| `partner_events` | US-9.3.1, US-9.3.2, US-9.5.1, US-9.6.1 |
| `partner_spaces` | US-9.4.1, US-9.5.1, US-9.6.1 |
| `source_health_checks` | US-2.1.1, US-2.2.1, US-2.3.1, US-2.4.1, US-5.1 (quality dashboard) |
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
| `RecalculateWearJob` | US-1.5.1, US-1.5.2, US-1.6.3 (shelf moves / re-read) | Event-driven |
| `FetchReviewsJob` | US-2.1.1 | Adaptive staleness (hours to days) |
| `TriggerPriceScrapeJob` | US-2.2.1 | Scheduled (daily) |
| `DiscoverAuthorSourcesJob` | US-2.3.1 | Scheduled (weekly) |
| `FetchAuthorRSSJob` | US-2.3.1 | Scheduled (hourly) |
| `DiscoverBookstoreEventsJob` | US-2.4.1 | Scheduled (daily) |
| `SourceDiscoveryJob` | US-2.5.1 | Scheduled (daily) |
| `ScoreSourceJob` | US-2.5.1 | On-demand (after discovery) |
| `DiscoverThirdSpacesJob` | US-3.1.1 | Scheduled (weekly) |
| `ModerationPipelineJob` | US-4.1.1 | On-demand (part of upload) |
| `KYCCallbackJob` | US-4.1.2 | Webhook-driven (US-7.3.1 deferred per ADR 013) |
| `MetricsSnapshotJob` | US-5.1.1 | Scheduled (every 5 min) |
| `RegenerateFeedJob` | US-6.1.1 | Event-driven (shelf change) |
| `ListingExpiryJob` | US-7.1.1 | Scheduled (daily) |
| `PaymentCallbackJob` | US-7.2.1 | Webhook-driven — **DEFERRED** (ADR 013) |
| `ShipmentTrackingJob` | US-7.2.1 | Scheduled (hourly) — **DEFERRED** (ADR 013) |
| `DataExportJob` | US-8.1.1 | On-demand |
| `AccountDeletionJob` | US-8.1.2 | On-demand |
| `ConfirmDeletionJob` | US-8.1.2 | On-demand |
| `ImageRetentionJob` | US-8.1.4 | Scheduled (daily) |
| `PartnerApprovalNotificationJob` | US-9.1.1 | Event-driven (partner.approved/declined) |
| `PartnerISBNResolveJob` | US-9.2.1, US-9.2.2 | Event-driven (unknown ISBN in partner inventory) |
| `ArchivePartnerEventsJob` | US-9.3.1 | Scheduled (daily) |
| `PartnerMetricsSnapshotJob` | US-9.5.1 | Scheduled (daily) |
| `GeographicDiscoveryJob` | US-2.5.2 | Event-driven (user.location_updated) + quarterly Oban.Cron |
| `OptOutConfirmationJob` | US-2.5.3 | On-demand (opt-out request) |
| `MarketplaceSaleWorker` | US-7.2 | Event-driven (book.sold — checks buyer WishList, prompts) — **DEFERRED** (ADR 013, relevant when payments are on-platform) |
| `WishListAvailabilityJob` | US-17.3.1 | Event-driven (partner inventory ingested, classifieds listing activated) |
| `EmailNotificationJob` | US-17.3.1 | On-demand (checks preferences before sending) |
| `EventSubscriberWorker` | EDA (cross-cutting) | Event-driven (dispatches to subscriber modules) |

---

## Quick Reference: External API Usage

| API / Service | Stories | Purpose |
|---------------|---------|---------|
| Modal | US-1.1.1, US-1.1.3, US-4.1.1 | Vision model (book identification, classification via Qwen2.5-VL-7B) |
| Open Library | US-1.1.1, US-1.1.2, US-4.1.1 | ISBN resolution, book metadata |
| Google Books | US-1.1.1, US-1.1.2, US-4.1.1 | ISBN resolution fallback, metadata |
| Brave Search | US-2.3.1, US-2.4.1, US-2.5.1, US-2.5.2, US-3.1.1 | Source discovery, author search, event search, geographic sweep |
| SearXNG (self-hosted) | US-2.4.1, US-2.5.1, US-2.5.2, US-3.1.1 | Meta-search for discovery and geographic sweep |
| GoodReads | US-2.1.1 | Review aggregation |
| Reddit API | US-2.1.1 | Review aggregation |
| Storygraph | US-2.1.1 | Review aggregation |
| Smile Identity / Yoti / Sumsub | US-4.1.2 | KYC / age verification (US-7.3.1 deferred per ADR 013) |
| Stitch Money | US-7.2.1 | Payment processing — **DEFERRED** (ADR 013) |
| Pargo | US-7.2.1 | Shipping / logistics — **DEFERRED** (ADR 013) |
| Resend / Postmark | US-2.5.3, US-8.1.2, US-9.1.1, US-9.7.1, US-17.3.1 | Transactional email (business opt-out confirmation, GDPR confirmation, partner notifications, status updates, WishList availability, event match, group invitation emails) |

---

## Quick Reference: dbt Model Inventory

| Model | Type | Fed By Stories | Consumed By Stories |
|-------|------|---------------|-------------------|
| `stg_books` | Staging | US-1.1.1 | Many |
| `stg_book_editions` | Staging | US-1.1.1, US-1.1.8 | US-1.3.2, US-1.5.4, US-2.2.1 |
| `stg_uploaded_images` | Staging | US-1.1.1 | US-8.1.4 |
| `stg_bookshelf_placements` | Staging | US-1.5.1--3 | US-1.2.1--4 |
| `stg_bookshelf_placement_history` | Staging | US-1.5.1--3 | US-1.3.1 |
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
| `stg_user_blocks` | Staging | US-10.1.2 | US-10.x, US-11.x |
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
| `mart_community_read_count` | Mart | US-1.2.1 (Library placements) | US-18.1.1 (Looking for a Home wear) |
| `int_onboarding_completion_rate` | Intermediate | US-14.1.2 | US-5.1.1 |
| `int_notification_delivery_rate` | Intermediate | US-17.3.1 | US-5.1.1 |
| `int_opt_out_rate` | Intermediate | US-2.5.3 | US-5.1.1 |
| `stg_source_health_checks` | Staging | US-2.1.1–2.4.1 (enrichment workers) | US-5.1.1 |
| `int_source_health` | Intermediate | US-2.1.1–2.4.1 | US-5.1.1 (source health table) |
| `mart_data_quality_trend` | Mart | US-2.1.1–2.4.1 | US-5.1.1 (quality trend sparklines) |
| `mart_enrichment_gaps` | Mart | US-2.1.1–2.4.1 | US-5.1.1 (gap drill-down) |
| `mart_llm_faithfulness` | Mart | US-12.1.2, US-2.1.1 | US-5.1.1 (LLM quality metrics) |
