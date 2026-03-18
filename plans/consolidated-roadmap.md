# Plan: The Stacks — Consolidated Implementation Roadmap
**Created**: 2026-03-05
**Updated**: 2026-03-17
**Status**: Draft
**Branch**: `main` (greenfield — no existing code)

---

## Context

The Stacks is a greenfield book management and discovery platform. This plan sequences every deliverable from empty repository to a feature-complete Phase 1, with deferred features (Third Spaces, partner integration, groups, comments) in Phase 2. The build sequence derives from the ordered dependency graph in `docs/implementation-mapping.md`.

**Phase 1 is the full product** for individual and multi-user use: upload, shelve, browse, enrich (reviews, prices, author intel, events), simple fixed-price marketplace (Stitch Money + Pargo), blog with LLM book associations, visibility/privacy controls, metrics dashboard, RSS feeds, and accessibility. The only deferred features are Third Spaces discovery, partner push API, social groups, and comments.

**Target user**: A book-obsessive whose reading life is enriched with price tracking, review aggregation, author intelligence, local bookshop discovery, and a marketplace for rehoming books. The platform is visibility-first: content defaults to owner-only and is selectively shared with the broader platform community. NOT a public social network. NOT a corporate tool.

**Self-hosting**: The source is visible and forkable, but self-hosting is not a first-class use case. Forks can modify everything. The canonical deployment is the hosted platform with KYC age verification at registration.

**Aesthetic**: Dark-academic-meets-cottage-core. Walnut shelves, botanical prints, parchment textures, hand-lettered flyers, cork boards.

---

## Architecture Decisions (see `docs/technical-architecture.md`)

- **Core**: Elixir + Phoenix (OTP supervision, Oban job processing, Guardian JWT)
- **Frontend**: Elm SPA (zero runtime exceptions, TEA architecture, RemoteData pattern)
- **Vision service**: Python + FastAPI on Modal (Qwen2.5-VL-7B-Instruct on A10G GPU; HMAC-authenticated HTTPS; not co-located with core)
- **Price scraper**: Rust microservice (TOML config per store, standalone OSS tool)
- **Database**: PostgreSQL with 3 schemas (`op`, `wh`, `audit`), 3 DB roles. **Works/editions model**: `books` = work (logical book), `book_editions` = edition (ISBN, format, cover). Placements/reviews reference works; prices/partner inventory reference editions.
- **Data transforms**: dbt (staging -> intermediate -> marts)
- **Event bus**: Oban-backed EDA with `event_log` table (no Kafka, no RabbitMQ)
- **Schema contracts**: Protobuf + buf (JSON on wire, `.proto` as source of truth). Lands early — event envelope and core messages are proto-defined from day one.
- **Infrastructure**: Fly.io (IAD region), Nix/Flox dev environment, Docker for deploys
- **Visibility**: `resolve_visibility/2` as single gate for all content access. RLS designed from day one as safety net. Active marketplace listings punch through profile ceiling.
- **KYC**: Age verification via Smile Identity / Yoti / Sumsub at registration. Config flag `REQUIRE_KYC` (false during dev, true before launch). Stitch Money handles FICA for marketplace payouts.
- **Email**: Resend or Postmark for transactional email (registration confirmation, password reset, marketplace notifications, GDPR, notification preferences).
- **Partner integration** (Phase 2): One-directional (partner -> platform), API key auth (Argon2), Protobuf-validated payloads

---

## Model Selection Guide

The orchestrator runs on **Sonnet 4.6** throughout. Subagents use the model indicated below.

| Sub-Phase | Model | Rationale |
|-----------|-------|-----------|
| 1A (DB + migrations + RLS design) | **Sonnet 4.6** | Well-specified schema from docs; mechanical translation |
| 1B.1 (Foundation + Event Bus + Protobuf) | **Opus 4.6** | Event bus design, proto schema authoring, security plugs — architectural judgment |
| 1B.2 (Core Book Management) | **Opus 4.6** | Works/editions model, two-step upload, multi-format merge — judgment required |
| 1B.3 (Visibility + RLS) | **Opus 4.6** | Security-critical — resolve_visibility/2, block graph, ceiling rules, RLS policies |
| 1C.1 (Rust Scraper) | **Sonnet 4.6** | Well-specified TOML-driven scraper; pattern-following |
| 1C.2 (Enrichment Contexts) | **Opus 4.6** | External API integration, LLM guardrails, discovery agent — judgment required |
| 1D (Python Vision Sidecar) | **Sonnet 4.6** | Small, well-specified FastAPI service |
| 1D.1 (Vision eval framework) | **Sonnet 4.6** | Framework harness is mechanical; corpus assembly is human |
| 1D.2 (Local OCR pre-pass) | **Sonnet 4.6** | Well-specified in-process library integration |
| 1E.1 (Marketplace Backend) | **Opus 4.6** | Payment integration (Stitch Money), shipping (Pargo), listing state machine — high stakes |
| 1E.2 (Blog Backend) | **Sonnet 4.6** | Blog CRUD, LLM association worker — well-specified once visibility exists |
| 1E.3 (RSS + Metrics + Email) | **Sonnet 4.6** | Feed generation, dbt marts, email templates — pattern-following |
| 1F (Elm Frontend — 4 waves) | **Sonnet 4.6** | TEA patterns are mechanical once API interfaces are defined |
| 1G (Platform + Deployment) | **Sonnet 4.6** | Config files, Dockerfiles, GitHub Actions — pattern-following |
| Phase 2 (Third Spaces, Partners, Groups) | **Opus 4.6** | Partner auth, Protobuf partner schemas, group semantics — judgment required |

---

## Pre-Flight: Credential & Account Provisioning (human task)

Agents cannot create accounts. This must be done by a human before Phase 1G (first deployment). Code work in 1A–1F can proceed with mocked services. **Long-lead items** (Stitch Money, KYC provider) should be provisioned early — they may involve contracts and approval processes.

| Service | Required for | What to provision |
|---------|-------------|-------------------|
| Fly.io | 1G deploy | Organisation created; 3 apps (`thestacks-core`, `thestacks-scraper`, `thestacks-searxng`); `FLY_API_TOKEN` in GitHub secrets. Vision runs on Modal, not Fly. |
| Neon PostgreSQL | 1G DB | Serverless PostgreSQL; connection string with `?sslmode=require`; 3 DB roles (`stacks_app`, `stacks_dbt`, `stacks_readonly`) |
| **Modal** | 1D vision calls | Account created; `modal deploy apps/vision/modal_app.py`; `VISION_HMAC_SECRET` set as Modal secret. |
| Brave Search | 1C.2 discovery | API key; `BRAVE_SEARCH_API_KEY` in `.env` |
| Resend or Postmark | 1E.3 email | API key; `EMAIL_API_KEY` in `.env`. Needed for registration confirmation, password reset, marketplace notifications, GDPR. |
| Smile Identity / Yoti / Sumsub | 1E.1 KYC | API key; `KYC_API_KEY`. **Long lead** — may require vendor contract. Config flag `REQUIRE_KYC=false` allows development without it; switch to `true` before launch. |
| Stitch Money | 1E.1 marketplace payments | API key; `STITCH_API_KEY`, webhook secret. **Long lead** — requires SA business registration + Stitch onboarding. Stitch handles FICA for seller payouts. |
| Pargo | 1E.1 marketplace shipping | API key; `PARGO_API_KEY` |
| Domain + DNS | 1G | Domain pointed to Fly.io; TLS via Fly |

**Validate** by checking `.env.example` against `apps/core/config/runtime.exs` — every referenced env var must have a value before deployment.

---

## Pre-Flight: Repository Scaffolding (platform-agent, first task)

Before any agent writes domain code, the repository skeleton must exist. This is item 0 — the platform-agent creates the empty project structure.

**Files created:**
```
thestacks/
  apps/
    core/              mix phx.new --umbrella
    vision/            fastapi project skeleton
    scraper/           cargo init
  frontend/            elm init
  proto/
    buf.yaml
    buf.gen.yaml
    stacks/
      common/
      partner/
      internal/
  dbt/
    dbt_project.yml
    profiles.yml
    models/staging/
    models/intermediate/
    models/marts/
  scrapers/za/
  deploy/
    fly.core.toml
    fly.scraper.toml
    Dockerfile.core
    Dockerfile.scraper
  nix/flake.nix
  .github/workflows/ci.yml
  .env.example
  justfile
  CLAUDE.md             (already exists)
  AGENTS.md             (already exists)
```

**Steps:**
1. `mix phx.new thestacks --umbrella --app core --database postgres` — configure for UUID PKs, TIMESTAMPTZ
2. Add deps to `mix.exs`: `guardian`, `argon2_elixir`, `oban`, `fuse`, `cloak_ecto`, `sobelow`, `mix_audit`, `excoveralls`, `credo`, `prom_ex`
3. `elm init` in `frontend/`, add `elm.json` with `elm/http`, `elm/json`, `elm/url`, `elm/browser`
4. `cargo init --name stacks-scraper` in `apps/scraper/`, add deps: `reqwest`, `scraper`, `toml`, `serde`, `tokio`, `thiserror`, `anyhow`
5. FastAPI skeleton in `apps/vision/`: `main.py`, `requirements.txt` (fastapi, uvicorn, httpx, pydantic)
6. `buf.yaml` + `buf.gen.yaml` with Elixir, Rust, Python, Elm gen targets
7. `flake.nix` with Elixir 1.18+, Erlang 27, Node 22, Rust stable, Python 3.12, buf, dbt-postgres, elm, elm-format
8. `justfile` with recipes: `dev`, `test`, `lint`, `format`, `db-create`, `db-migrate`, `db-reset`, `buf-lint`, `buf-generate`, `deploy-core`, `deploy-vision`, `deploy-scraper`
9. `.env.example` with all production env vars documented
10. `.github/workflows/ci.yml` with dorny/paths-filter for monorepo (Elixir, Elm, Rust, Python, Proto paths)
11. `deploy/Dockerfile.core` (multi-stage Elixir release), `deploy/Dockerfile.scraper`; `apps/vision/modal_app.py` (Modal builds the vision container)

**DoD:**
- [ ] `nix develop` drops into shell with all tools available
- [ ] `mix compile` succeeds (empty app)
- [ ] `elm make src/Main.elm` succeeds (Hello World)
- [ ] `cargo build` succeeds (empty main)
- [ ] `python -m pytest` succeeds (empty test)
- [ ] `buf lint proto/` succeeds
- [ ] `just test` runs all language test suites
- [ ] CI workflow passes on push

---

## Phase 1: The Full Product

> The complete individual + multi-user experience: upload, shelve, browse, enrich (reviews, prices, author intel, events), simple fixed-price marketplace (Stitch Money + Pargo), blog with LLM book associations, visibility/privacy controls, metrics dashboard, RSS feeds, and accessibility. Deferred: Third Spaces, partner push API, groups, comments, closed bid marketplace.

### Phase 1A — Database Foundation (database-agent)
**Objective**: ALL operational tables for the entire expanded scope, indexes, DB roles, and RLS policy designs exist. One migration wave — no revisits. dbt staging models for all tables.
**Starts after**: Repository scaffolding committed.

**Migrations to create** (in order):

1. `create_schemas` — create `op`, `wh`, `audit` schemas; set `search_path`
2. `create_users` — `op.users` with `profile_visibility`, `website_url`, `onboarding_completed`, notification preference booleans (`notify_wishlist_availability`, `notify_marketplace`, `notify_group_invitations`, `notify_event_matches`); role enum
3. `create_authors` — `op.authors`
4. `create_books` — `op.books` as **works** (no ISBN on this table — ISBN lives on `book_editions`). GIN index on title tsvector. Contains: `title`, `author_id`, `description`, `subjects`, `bisac_codes`, `visibility_tier`, `open_library_work_id`.
5. `create_book_editions` — `op.book_editions` with `isbn UNIQUE NOT NULL` (the hard gate), `book_id FK`, `format` enum, `is_primary BOOLEAN`, `cover_image_url`, `page_count`, `publisher`, `publication_year`, `language`, `open_library_edition_id`, `google_books_id`. Index on `book_id`.
6. `create_bookshelves` — `op.bookshelves` with `visibility`, `visibility_group_id`
7. `create_bookshelf_placements` — `op.bookshelf_placements` with `visibility`, `listing_mode` (`ENUM('fixed', 'offers')` — closed bid deferred), `listing_status`, `listing_price_cents`, `listing_min_price_cents`. **No `formats TEXT[]` column** — formats are derived from `book_editions`.
8. `create_bookshelf_placement_history` — `op.bookshelf_placement_history`
9. `create_uploaded_images` — `op.uploaded_images` (references `book_editions` via `edition_id`, not `books`)
10. `create_audit_log` — `audit.audit_log` (append-only)
11. `create_discovered_sources` — `op.discovered_sources` with status enum including `'excluded'`, `excluded_at`, `exclusion_email`
12. `create_review_snapshots` — `op.review_snapshots` (references `books` works, not editions — reviews are about the work)
13. `create_bookstores` — `op.bookstores`
14. `create_price_snapshots` — `op.price_snapshots` (references `book_editions` via `edition_id` — prices are per edition)
15. `create_bookstore_events` — `op.bookstore_events`
16. `create_third_spaces` — `op.third_spaces` with `opted_out BOOLEAN`, `opted_out_at TIMESTAMPTZ`
17. `create_third_space_events` — `op.third_space_events`
18. `create_event_log` — `op.event_log` with index on `(event_type, aggregate_id, occurred_at DESC)`
19. `create_user_blocks` — `op.user_blocks` with unique `(blocker_id, blocked_id)`
20. `create_groups` — `op.groups` with type enum `(close_friends, broadcast, subscription)`
21. `create_group_members` — `op.group_members`
22. `create_group_invitations` — `op.group_invitations` with status enum
23. `create_visibility_grants` — `op.visibility_grants` (polymorphic per-resource grants)
24. `create_blog_posts` — `op.blog_posts` with visibility, `published_at TIMESTAMPTZ`
25. `create_post_book_associations` — `op.post_book_associations` with confidence score, source enum
26. `create_offer_threads` — `op.offer_threads` per `(placement_id, buyer_id)`, status enum
27. `create_offer_messages` — `op.offer_messages` with type enum `(message, offer, counter, accept, decline)`
28. `create_listings` — `op.listings` with pricing_mode `(fixed, offer)`, status, condition, photos
29. `create_transactions` — `op.transactions` with payment/shipping status
30. `create_oban_tables` — Oban migration (`Oban.Migration`)
31. `create_db_roles` — SQL migration for `stacks_app`, `stacks_dbt`, `stacks_readonly` roles with appropriate grants

> **Note**: `my_writing_links` table is not created — superseded by `blog_posts`. `website_url` on `users` covers the external-link use case.
> **Note**: Group tables (20-23) are created now even though group features are deferred to Phase 2. The `visibility_grants` and `groups` tables are needed by the visibility infrastructure (1B.3) for the ceiling rule and shelf visibility options.

**RLS policy design** (designed now, enforcement deferred until after core controllers are built):
- `bookshelf_placements`: user can only read/write their own placements (except public marketplace listings)
- `blog_posts`: user can only write their own; reads filtered by visibility
- `offer_threads` / `offer_messages`: scoped to `(placement_id, buyer_id)` — only buyer and seller
- Active marketplace listings (`listing_status = 'active'`) are exempt from profile ceiling — always visible to platform users
- RLS policies documented in `docs/rls-design.md`; enforced via `ALTER TABLE ... ENABLE ROW LEVEL SECURITY` after 1B.3 visibility contexts pass tests

**dbt setup:**
- `profiles.yml` pointing to `stacks_dbt` role
- `dbt_project.yml` with `+materialized: view` for staging, `+schema` routing per schema
- `macros/generate_schema_name.sql` — custom macro so seeds land in `op`/`audit` without target-schema prefix
- `packages.yml` — pin `AxelThevenot/dbt-assertions` for row-level data quality assertions (see below); run `dbt deps` after creating
- Staging models for ALL tables: `stg_books`, `stg_book_editions`, `stg_authors`, `stg_users`, `stg_bookshelves`, `stg_bookshelf_placements`, `stg_bookshelf_placement_history`, `stg_uploaded_images`, `stg_audit_log`, `stg_discovered_sources`, `stg_review_snapshots`, `stg_bookstores`, `stg_price_snapshots`, `stg_bookstore_events`, `stg_third_spaces`, `stg_third_space_events`, `stg_event_log`, `stg_user_blocks`, `stg_groups`, `stg_group_members`, `stg_blog_posts`, `stg_post_book_associations`, `stg_offer_threads`, `stg_partners`, `stg_partner_inventory`, `stg_partner_events`, `stg_partner_spaces`, `stg_listings`, `stg_transactions`
- Seed fixtures in `dbt/seeds/` for core tables (small CSVs, internally-consistent UUIDs) — books, editions, authors, users, bookshelves, placements, audit_log minimum
- Empty intermediate and mart directories with `.gitkeep`

**dbt-assertions** (`AxelThevenot/dbt-assertions`, pin to `1.8.3`): adds row-level assertions to model YAML files so failing rows are identified individually rather than the test just reporting a count. Wire into staging model schemas as follows:
- `stg_books` — assert ISBN is exactly 13 digits; `visibility_tier` is one of `public`, `restricted`, `private`, `hidden`
- `stg_bookshelves` — assert `shelf_type` is a known enum value
- `stg_bookshelf_placements` — assert `placed_at <= current_date`; no placement without a matching bookshelf row
- `stg_audit_log` — assert `action` and `actor_id` are never null

```yaml
# dbt/packages.yml
packages:
  - package: AxelThevenot/dbt-assertions
    version: 1.8.3
```

**Files created:**
- `apps/core/priv/repo/migrations/` — 31 migration files
- `dbt/models/staging/` — ~28 staging model SQL files
- `dbt/seeds/` — core seed CSV files
- `docs/rls-design.md` — RLS policy documentation
- `dbt/macros/generate_schema_name.sql`
- `dbt/packages.yml`
- `dbt/profiles.yml`, `dbt/dbt_project.yml`

**Test command**: `just test-dbt`
**DoD:**
- [ ] All 31 migrations run without error
- [ ] `mix ecto.rollback --all` succeeds (migrations are reversible)
- [ ] DB roles exist with correct grants
- [ ] `dbt run --select staging` succeeds
- [ ] GIN index exists on `books.title`
- [ ] `book_editions.isbn` has UNIQUE constraint
- [ ] `book_editions.book_id` has index
- [ ] `audit_log` has INSERT-only grant for `stacks_app`
- [ ] `event_log` index exists on `(event_type, aggregate_id, occurred_at DESC)`
- [ ] `dbt deps` installs `dbt-assertions` without errors
- [ ] Row-level assertions pass on all 4 staging models listed above when seeded with valid fixture data

---

### Phase 1B — Elixir Core (3 tracks)
**Objective**: All Phoenix contexts, controllers, and Oban workers for the expanded scope. API-only — no frontend yet.
**Starts after**: Phase 1A committed.
**Parallel with**: Phase 1C.1 (Rust scraper) and Phase 1D (Python vision) can start immediately. Phase 1F (Elm) can start once 1B.2 API interfaces are defined.

#### 1B.1 — Foundation + Event Bus + Protobuf (MUST be first)

**`Stacks.Accounts`** — user registration, authentication, profile, settings, Guardian pipeline
- `Stacks.Accounts.register/1`, `authenticate/2`, `get_user/1`
- `Stacks.Accounts.complete_onboarding/1` — sets `onboarding_completed = true` (US-14.1.2)
- `Stacks.Accounts.update_profile/2` — display name, email (requires password), website URL (US-17.2.1)
- `Stacks.Accounts.update_location/2` — city, country_code; emits `user.location_updated` event (US-17.2.2)
- `Stacks.Accounts.change_password/2` — verify current, hash new with Argon2 (US-17.2.3)
- `Stacks.Accounts.update_notification_preferences/2` — toggle email notification booleans (US-17.3.1)
- Guardian serializer, auth pipeline plug, error handler
- `StacksWeb.AuthController` — `login/2`, `logout/2`, `register/2`
- `StacksWeb.UserSettingsController` — `update_profile/2`, `change_password/2`, `update_notifications/2`
- Owner bootstrap: first user to register becomes owner
- Login redirects to `/antilibrary`; first-time registration triggers onboarding flow (US-14.1.2)
- KYC integration: config flag `REQUIRE_KYC` (false during dev). When true, registration requires age verification via Smile Identity / Yoti / Sumsub before account is active.

**`Stacks.Audit`** — append-only audit logging
- `Stacks.Audit.log/3` (action, actor, metadata)
- IP hashing via `:crypto.hash(:sha256, ip)`
- Metadata encryption via Cloak
- No UPDATE/DELETE in context — INSERT only

**`Stacks.GDPR.Consent`** — consent management
- `grant_consent/2`, `revoke_consent/2`, `check_consent/2`
- `StacksWeb.Plugs.ConsentCheck`

**`Stacks.Events`** — event bus infrastructure (MOVED UP from old Phase 3B)
- `Stacks.Events.emit/1` — insert into `event_log`, enqueue `EventSubscriberWorker` per registered subscriber
- `Stacks.Events.replay/3` — replay events for a given aggregate
- `Stacks.Events.Registry` — subscriber mapping (`event_type -> [handler_module]`)
- `Stacks.Events.Upcaster` — pattern-matched version transforms
- `Stacks.Events.SubscriberWorker` — Oban worker that dispatches to subscriber modules
- Event payloads use Protobuf-defined `EventEnvelope` (see below)

**Protobuf core schemas** (MOVED UP from old Phase 3A)
- `proto/stacks/internal/event_bus.proto` — `EventEnvelope` (event_type, aggregate_type, aggregate_id, schema_version, payload, metadata, occurred_at)
- `proto/stacks/common/book.proto` — Book, Edition, Author, ISBN messages
- `proto/stacks/common/location.proto` — Country, City, Coordinates
- `buf lint` + `buf generate` for Elixir and Elm (Elm decoders checked in)
- Partner protos (inventory, events, spaces) deferred to Phase 2

**Files:**
- `apps/core/lib/core/accounts.ex`, `accounts/user.ex`
- `apps/core/lib/core/audit.ex`, `audit/log_entry.ex`
- `apps/core/lib/core/gdpr/consent.ex`
- `apps/core/lib/core/events.ex`, `events/registry.ex`, `events/upcaster.ex`
- `apps/core/lib/core/workers/event_subscriber_worker.ex`
- `apps/core/lib/core_web/plugs/` — `auth_pipeline.ex`, `consent_check.ex`, `rate_limiter.ex`, `security_headers.ex`
- `apps/core/lib/core_web/controllers/auth_controller.ex`, `user_settings_controller.ex`
- `proto/stacks/internal/event_bus.proto`, `proto/stacks/common/book.proto`, `proto/stacks/common/location.proto`

#### 1B.2 — Book Management Contexts

**`Stacks.Books`** — the core domain (works/editions model)
- `Books.identify/2` — step 1: orchestrates vision call + ISBN resolution, returns candidate(s) without committing
- `Books.confirm/2` — step 2: user confirms candidate + shelf → creates work + edition + placement
- `Books.create_work_with_edition/2` — creates `books` work + first `book_editions` edition
- `Books.create_from_isbn/1` (US-1.1.5 manual entry) — same two-step verify+confirm flow
- `Books.find_existing/1` (US-1.1.6 duplicate detection) — checks `book_editions.isbn`
- `Books.find_same_work/2` (US-1.1.8 multi-format merge) — fuzzy title+author match (Jaro-Winkler > 0.8)
- `Books.merge_edition/2` (US-1.1.8) — adds new `book_editions` row under existing work
- `Books.get_book_detail/1` — aggregates work + editions + author + reviews + prices (per edition) + writing links + community read count
- `Books.search_books/2` — full-text search with `pg_trgm`, dynamic sort/filter (US-1.5.1)
- `Books.search_platform/2` — platform-wide search: public shelves, marketplace, partner inventory (US-1.5.3)
- `Books.community_read_count/1` — reads from `wh.mart_community_read_count` (US-18.1.1)
- `Books.ISBNResolver` — Open Library primary, Google Books fallback; returns work + edition metadata
- `StacksWeb.UploadController.identify/2` (`POST /api/upload/identify`)
- `StacksWeb.BookController.confirm/2` (`POST /api/books/confirm`)
- `StacksWeb.BookController.merge_format/2` (`POST /api/books/:id/merge-format`)
- `StacksWeb.SearchController` — includes `/api/search/platform` endpoint

**`Stacks.Shelving`** — shelf operations
- `Shelving.get_shelf_books/2`, `Shelving.move_book/3`, `Shelving.abandon_book/2`, `Shelving.reread_book/1`
- `Shelving.remove_book/1` (US-1.6.4 — soft delete via `removed_at`)
- `Shelving.spine_data/1` — computes wear level from history (personal wear for most shelves, community wear for Looking for a Home)
- `StacksWeb.ShelfController`, `StacksWeb.ShelfPlacementController`
- All five shelves are valid move targets from any source shelf; books can return from Looking for a Home

**`Stacks.Moderation`** — content moderation pipeline
- `Moderation.Pipeline` — classify_image -> resolve_isbn -> classify_subject -> store_with_tier
- `Moderation.classify_subject/1` using BISAC lookup
- `StacksWeb.Plugs.AgeGate`

**Oban workers (MVP):**
- `Stacks.Workers.IdentifyBookJob` — vision call + ISBN resolution + moderation pipeline; returns candidate(s) to frontend
- `Stacks.Workers.EnrichBookJob` — fetch metadata from Open Library / Google Books (work + edition level)
- `Stacks.Workers.RecalculateWearJob` — wear level recalculation on shelf moves
- `Stacks.Workers.ImageRetentionJob` — daily cleanup of images older than 30 days
- `Stacks.Workers.EmailNotificationJob` — checks user preferences before sending (US-17.3.1)
- `Stacks.Workers.WishListAvailabilityJob` — checks WishList ISBNs against new partner/marketplace availability

**`Stacks.AI.BudgetTracker`** — GenServer for per-provider daily/monthly caps
**`Stacks.AI.Client`** — HTTP client with Fuse circuit breaker wrapping Modal vision service calls

**Files:**
- `apps/core/lib/core/books.ex`, `books/book.ex`, `books/edition.ex`, `books/isbn_resolver.ex`
- `apps/core/lib/core/shelving.ex`, `shelving/shelf.ex`, `shelving/shelf_placement.ex`, `shelving/shelf_placement_history.ex`
- `apps/core/lib/core/moderation.ex`, `moderation/pipeline.ex`
- `apps/core/lib/core/ai/budget_tracker.ex`, `ai/client.ex`
- `apps/core/lib/core/workers/` — 6 worker files (identify, enrich, recalculate_wear, image_retention, email_notification, wishlist_availability)
- `apps/core/lib/core_web/controllers/` — `book_controller.ex`, `upload_controller.ex`, `search_controller.ex`, `shelf_controller.ex`, `shelf_placement_controller.ex`, `user_settings_controller.ex`, `opt_out_controller.ex`
- `apps/core/lib/core_web/router.ex`

#### 1B.2.1 — GDPR Contexts (part of 1B.2)

**`Stacks.GDPR.Export`** — `export_user_data/2` (JSON, CSV, OPDS)
**`Stacks.GDPR.Deletion`** — `delete_user_data/1` with Ecto.Multi cascade
**`Stacks.GDPR.ImageRetention`** — `cleanup_expired_images/0`

**Oban workers:**
- `Stacks.Workers.DataExportJob`
- `Stacks.Workers.AccountDeletionJob`, `ConfirmDeletionJob`

**Files:**
- `apps/core/lib/core/gdpr/export.ex`, `gdpr/deletion.ex`, `gdpr/image_retention.ex`
- `apps/core/lib/core/workers/data_export_job.ex`, `account_deletion_job.ex`, `confirm_deletion_job.ex`
- `apps/core/lib/core_web/controllers/gdpr_controller.ex`

**1B.2 Test command**: `mix test`
**1B.2 DoD:**
- [ ] All contexts have at least one happy-path and one error-path test
- [ ] `mix compile --warnings-as-errors` passes
- [ ] `mix credo --strict` passes
- [ ] `mix sobelow --config` passes (no high-severity findings)
- [ ] Guardian auth pipeline works: register -> login -> access protected route -> logout
- [ ] Two-step upload flow works end-to-end via API: identify (returns candidate) -> confirm (creates work + edition + placement) with mocked vision service
- [ ] Multi-format merge: uploading a Kindle ISBN for an existing hardcover merges under same work
- [ ] Shelf operations: move (all 5 shelves valid), abandon, re-read, remove all write correct history records
- [ ] Search returns results with full-text matching; platform-wide search returns public shelf data
- [ ] Settings: profile update, location change (emits event), password change, notification preferences toggle
- [ ] Onboarding flag: `onboarding_completed` set after first registration flow
- [ ] Event bus: `emit/1` writes to `event_log`; shelf operations emit events; subscribers receive correct events
- [ ] Protobuf: `buf lint` passes; `EventEnvelope` compiles for Elixir and Elm
- [ ] Audit log captures all significant actions
- [ ] GDPR export produces valid JSON with all user data
- [ ] Image retention job deletes files older than 30 days
- [ ] Budget tracker rejects calls when daily limit exceeded

---

#### 1B.3 — Visibility Infrastructure (elixir-agent — SECURITY CRITICAL)
**Objective**: `resolve_visibility/2` gate, block graph, ceiling rule enforcement, ViewAsPlug. Every content endpoint routes through visibility checks from day one. No retrofit.
**Starts after**: 1B.1 committed. **Parallel with** 1B.2 (core book management).
**Must complete before**: 1E.1 (Marketplace), 1E.2 (Blog), 1E.3 (RSS).

**`Stacks.Visibility`** context
- `resolve_visibility/2` — single authoritative gate; viewer contexts: `:unauthenticated`, `{:platform_user, user_id}`, `{:group_member, group_id}`, `{:specific_user, user_id}`
- Clauses: profile ceiling → block check → age gate → resource visibility. Returns `:hidden` on ambiguity (404, not 403).
- `can_view?/2`, `viewable_shelves/2`, `viewable_placements/2`
- Ceiling rule enforcement on write: `validate_visibility_ceiling/3`
- **Marketplace exception**: active listings (`listing_status = 'active'`) on `looking_for_home` punch through profile ceiling — always visible to platform users. Users can still restrict individual listings for future closed-bid scenarios.

**`Stacks.Social`** context
- `block_user/2`, `unblock_user/2`, `is_blocked?/2`, `blocked_by?/2`
- Blocked users see 404 (not 403) for all blocked content — no information leakage

**`StacksWeb.Plugs.ViewAsPlug`** — owner sets `?view_as=user_id` param; plug sets viewer context; 403 for non-owners

**Retrofit**: All controllers from 1B.2 (book, shelf, search, upload, settings) must route through `resolve_visibility/2`. If 1B.3 is built in parallel with 1B.2, the visibility gate can be wired in as controllers are built rather than retrofitted.

**RLS enforcement**: After visibility contexts pass tests, enable PostgreSQL RLS policies designed in 1A.

**Property-based tests**: `resolve_visibility/2` has a large combinatorial input space (4 visibility levels x 4 viewer types x block/no-block x age-gated/not x ceiling violations). Use `StreamData` for property-based testing — generate random (resource, viewer) pairs and assert invariants:
- A blocked viewer never sees `:visible`
- A viewer cannot see content above the profile ceiling
- An unauthenticated viewer never sees non-public content
- An age-gated resource is always hidden from unverified viewers

**Files:**
- `apps/core/lib/core/visibility.ex`
- `apps/core/lib/core/social.ex`, `social/block.ex`
- `apps/core/lib/core_web/plugs/view_as_plug.ex`
- `apps/core/test/core/visibility_property_test.exs`
- `docs/rls-design.md` → `apps/core/priv/repo/migrations/enable_rls.sql`

**Events emitted:**
- `social.user_blocked`, `social.user_unblocked`

**dbt models:**
- `stg_user_blocks`
- `int_visibility_resolution` (for audit/debugging)

**1B.3 DoD:**
- [ ] `resolve_visibility/2` passes all ceiling-rule and block-graph scenarios
- [ ] Property-based tests pass with 1000+ generated cases
- [ ] Blocked users see 404 (not 403)
- [ ] `ViewAsPlug` correctly impersonates viewer context for owner only
- [ ] Active marketplace listings visible regardless of profile visibility
- [ ] All content endpoints in 1B.2 route through `resolve_visibility/2`
- [ ] RLS policies enabled and tested
- [ ] All shelf/placement writes enforce ceiling rule

---

### Phase 1C — Enrichment (2 parallel tracks)

#### 1C.1 — Rust Scraper (rust-agent — independent, parallel)
**Objective**: Bookshop price scraper works end-to-end with TOML configs for SA stores.
**Starts after**: Phase 1A committed. No dependency on Elixir contexts — fully independent service.

See current Phase 2A content below (unchanged — moved up from old Phase 2).

#### 1C.2 — Enrichment Elixir Contexts (elixir-agent)
**Objective**: Review aggregation, price tracking, author intelligence, bookstore events, source discovery (book-triggered + geographic sweep), business opt-out — all wired to Oban jobs and the event bus.
**Starts after**: 1B.2 committed (books/shelving must exist). Event bus (1B.1) must be available.

See current Phase 2B content below (updated — enrichment contexts + geographic sweep + opt-out).

---

### Phase 1D — Python Vision Sidecar (python-agent — independent, parallel)
**Unchanged from current Phase 1D.** Starts after repository scaffolding. Add `/associate` endpoint stub (for blog LLM associations in 1E.2).

---

### Phase 1E — Marketplace, Blog, RSS, Metrics, Email (after visibility + enrichment)

#### 1E.1 — Marketplace Backend (elixir-agent)
**Objective**: Fixed-price listings, Stitch Money payment, Pargo shipping, post-sale lifecycle. No offers mode, no closed bid, no Q&A (deferred).
**Starts after**: 1B.3 (visibility) + 1C.2 (enrichment — prices must exist for buyer context).

See current Phase 5B content (simplified — fixed price only, no closed bid, post-sale lifecycle added).

#### 1E.2 — Blog Backend (elixir-agent)
**Objective**: Blog CRUD with visibility ceiling. LLM book associations via PostBookAssociationWorker. BookDetailCache (ETS, event-driven invalidation). No comments.
**Starts after**: 1B.3 (visibility — blog posts have visibility controls).

See current Phase 7B content (minus comments).

#### 1E.3 — RSS, Metrics, Email Infrastructure (elixir-agent)
**Objective**: Atom feeds per public shelf. Metrics dashboard with dbt marts. Email delivery infrastructure.
**Starts after**: 1B.2 (core book management — feeds need shelf data), 1B.1 (event bus — feeds are event-driven).

**RSS/OPDS**: See current Phase 4B content.
**Metrics**: See current Phase 4C content.

**Email infrastructure** (NEW — not previously scoped):
- `Stacks.Email` context — template rendering, delivery via Resend/Postmark
- `Stacks.Email.Mailer` — Swoosh adapter for Resend/Postmark
- Templates: registration confirmation, password reset, marketplace sale notification, GDPR export ready, WishList availability alert, event match notification
- `StacksWeb.EmailVerificationController` — confirm email address at registration
- `Stacks.Workers.EmailDeliveryJob` — Oban worker for async email send with retry
- All emails respect `users.notify_*` preferences (except ToS changes and registration confirmation)

**dbt models for 1E.3:**
- `mart_system_health`, `mart_job_stats`, `mart_data_freshness`, `mart_cost_tracking`, `mart_gdpr_compliance`
- `mart_community_read_count` (for Looking for a Home wear — refreshes every 5 min)
- `mart_platform_searchable` (for platform-wide search index — refreshes every 5 min)
- `mart_marketplace_activity`, `mart_transaction_volume`
- `mart_blog_activity`

---

### Phase 1F — Elm Frontend (elm-agent — 4 waves)
**Objective**: All Phase 1 pages render and interact with the Phoenix API. Built incrementally as backend APIs become available.
**Starts after**: 1B.2 API interfaces are defined (can mock API responses initially).

#### Wave 1 (after 1B.2 APIs): Core UX

Auth, shelves, upload, spine rendering, book detail overlay, search, settings hub, navigation, empty states, accessibility.

**`Page.Upload`** — multi-step upload with verification, drop zone (single and bulk), review/confirmation
- `UploadStep` type: `Uploading → Verifying IdentifiedBook → ChoosingShelf → Complete`
- Single-image flow: drop → process → **verify** ("We think this is…" with uploaded image + identified book side-by-side) → **choose shelf** (default WishList) → add → "Add another" / "View on shelf" (US-1.1.1)
- Bulk flow: drop N images → processing progress → Review screen with card grid (US-1.1.7)
  - `Components.BookReviewCard` — confirmed / ambiguous / rejected states, per-card shelf selector (default WishList)
  - `Components.BulkProgress` — N images processing indicator
- `IdentificationFailed` variant (US-1.1.2 ISBN Hard Gate)
- `NotABook` variant (US-1.1.3) — in bulk, appears as rejected card; in single, full-screen rejection
- `ManualISBNEntry` variant (US-1.1.5) with client-side ISBN checksum validation, same verify+shelf flow
- `DuplicateDetected` variant (US-1.1.6) with view/move/close actions + multi-format merge prompt (US-1.1.8)
- `FormatMerge` variant (US-1.1.8) — "You own [Title] as [format]. Add [new format]?"

**`Page.Shelf.Library`** — dark walnut, green damask (`ShelfTheme { wood: DarkWalnut, backdrop: GreenDamask }`)
**`Page.Shelf.AntiLibrary`** — light oak, botanical prints
**`Page.Shelf.WishList`** — blue-grey, watercolour florals
**`Page.Shelf.ReadingPile`** — vertical stack, armchair background (`PileView`)

**Book Detail Overlay** (not a page/route — UI state in model)
- `Maybe BookDetailOverlay` in model. Opens on spine click, search result click, etc.
- Dismissable via X button, click-outside, or Escape. URL does not change.
- Shows: cover image, editions list, metadata, review summary (stub), price info per edition (stub), author card (with "Report an issue" link), writing links, shelf mover (all 5 shelves), format picker (creates editions via US-1.1.8), remove action
- Focus trapping within overlay for accessibility (US-19.1.1)

**`Page.Search`** — debounced search bar, filter panel, sort selector
- `SearchScope` type: `AllShelves | SpecificShelf ShelfId | WholePlatform`
- Platform-wide results in separate "On the Platform" section (US-1.5.3)

**`Page.Settings`** — settings hub with sidebar navigation (US-17.1.1)
- Sub-pages: `Profile` (US-17.2.1), `Password` (US-17.2.3), `Consent` (US-8.3), `AgeVerification` (US-4.2), `Export` (US-8.1), `Delete` (US-8.2), `AuditLog` (US-8.5), `Notifications` (US-17.3.1)
- Location fields (city/country) within Profile (US-17.2.2)
- Notification toggles with auto-save (US-17.3.1)

**`Components.OnboardingOverlay`** — 3-step first-time flow: Welcome → Upload → Shelve (US-14.1.2). Dismissable via "Skip".

**`Components.UserMenu`** — display name dropdown with "Settings" and "Sign Out" (US-14.3.3)

#### Shared Components

- `Components.Spine` — thickness from page_count, wear level (Pristine|Softened|Cracking|WellRead|WellLoved), bookmark icon, green dot for partner availability (Phase 3 stub)
- `Components.EmptyShelf` — per-shelf themed empty state with CTA (US-1.6.5)
- `Components.ShelfMover` — dropdown of target shelves
- `Components.AbandonModal` — optional note textarea
- `Components.RemoveBookModal` — confirmation with warning
- `Components.FormatPicker` — shows owned editions; adding new format triggers ISBN input + merge flow (US-1.1.8)
- `Components.AgeGate` — interstitial overlay
- `Components.ISBNInput` — ISBN-10/13 checksum validation
- `Components.DuplicateDetected` — existing book with actions
- `Components.SearchBar`, `Components.FilterPanel`, `Components.SortSelector`
- `Components.ConsentBanner` — first-visit consent collection
- `Components.BookList` — sortable table view for list mode (US-19.2.1)
- `Components.ViewModeToggle` — spine/list toggle icon in shelf header (US-19.2.1)

#### Navigation

- `Navigation.ShelfRouter` — URL-driven routing via `Browser.application`
- `Animation.SlideTransition` (adjacent shelves), `Animation.RoomTransition` (shelf vs pile)
- Swipe gesture detection via ports for mobile

#### Architecture

- All API calls use `RemoteData` pattern (`NotAsked | Loading | Success a | Failure e`)
- No ports unless absolutely necessary (file input interop, swipe gestures)
- `elm-format` enforced

**Files:**
- `frontend/src/Main.elm`
- `frontend/src/Page/` — `Upload.elm`, `Shelf/Library.elm`, `Shelf/AntiLibrary.elm`, `Shelf/WishList.elm`, `Shelf/ReadingPile.elm`, `Shelf/LookingForHome.elm`, `Search.elm`, `Settings.elm` (hub), `Settings/Profile.elm`, `Settings/Password.elm`, `Settings/Consent.elm`, `Settings/AgeVerification.elm`, `Settings/Notifications.elm`
- `frontend/src/Components/` — `Spine.elm`, `EmptyShelf.elm`, `ShelfMover.elm`, `AbandonModal.elm`, `RemoveBookModal.elm`, `FormatPicker.elm`, `AgeGate.elm`, `ISBNInput.elm`, `DuplicateDetected.elm`, `FormatMerge.elm`, `SearchBar.elm`, `FilterPanel.elm`, `SortSelector.elm`, `ConsentBanner.elm`, `BookDetailOverlay.elm`, `OnboardingOverlay.elm`, `UserMenu.elm`, `BookList.elm`, `ViewModeToggle.elm`
- `frontend/src/Navigation/ShelfRouter.elm`
- `frontend/src/Animation/` — `SlideTransition.elm`, `RoomTransition.elm`
- `frontend/src/Api.elm` — HTTP client module
- `frontend/src/Types/` — `Book.elm`, `Shelf.elm`, `User.elm`, `RemoteData.elm`
- `frontend/tests/`

**Test command**: `elm-test`
**DoD:**
- [ ] `elm make src/Main.elm --optimize` succeeds with zero warnings
- [ ] `elm-format --validate src/` passes
- [ ] All 5 shelf views render with correct themes (including Looking for a Home with community wear)
- [ ] Empty shelf states display per-shelf messages (US-1.6.5)
- [ ] Upload flow: select photo → verify ("We think this is…") → choose shelf (default WishList) → result (US-1.1.1)
- [ ] Manual ISBN entry with client-side checksum validation + same verify flow
- [ ] Duplicate detection shows existing book with actions + multi-format merge prompt (US-1.1.8)
- [ ] Book detail **overlay** opens on spine click, dismissable via X/Escape/click-outside, URL unchanged
- [ ] Detail overlay shows editions list with per-edition prices
- [ ] Shelf navigation with slide/room transitions
- [ ] Search with debounced input, filter/sort, and platform-wide scope option
- [ ] Remove book modal with confirmation
- [ ] All API calls use RemoteData pattern
- [ ] Settings hub with sidebar navigation and all sub-pages
- [ ] Onboarding overlay for first-time registration (dismissable)
- [ ] User menu dropdown (Settings + Sign Out) on display name
- [ ] List view toggle on all shelf pages (US-19.2.1)
- [ ] ARIA labels on spines, shelves, overlay, upload progress (US-19.1.1)
- [ ] Keyboard navigation: Tab, arrow keys, Enter, Escape (US-19.1.2)

#### Wave 2 (after 1C.2 APIs): Enrichment Display

- `Components.ReviewSummary` — sentiment bar, source cards with rating + link (no longer stubs)
- `Components.PriceInfo` — current prices per edition by store, sparkline chart, lowest price highlight
- `Components.AuthorCard` (expanded) — website, RSS posts, events, new releases, "Report an issue" link
- `Page.Events` — event cards matched to user's books/authors
- `Page.Admin.ScraperConfig` — TOML editor with validation
- `Page.Admin.SourceApproval` — discovered sources queue with confidence scores

**Wave 2 DoD:**
- [ ] Book detail overlay shows real reviews, prices (per edition), author info when available
- [ ] Price sparkline renders with SVG
- [ ] Scraper config admin page saves valid TOML
- [ ] Source approval page shows approve/reject actions

#### Wave 3 (after 1E.1–1E.2 APIs): Marketplace + Blog + Privacy

- `Page.Marketplace.CreateListing` — condition grader, fixed price only
- `Page.Marketplace.ListingDetail` — listing with price, condition, "Buy" button
- `Page.Marketplace.Checkout` — payment via Stitch Money, shipping via Pargo
- `Page.Blog.New`, `Page.Blog.Edit` — rich text editor (markdown), visibility selector
- `Page.Blog.Post` — post detail with book associations sidebar (no comments)
- `Page.Blog.Archive` — reverse-chronological post list
- `Page.Settings.Privacy` — profile visibility selector, per-shelf overrides, ceiling rule UI
- `Components.ViewAsBar` — sticky banner when viewing as another user
- `Components.VisibilityBadge` — lock icon with tooltip per visibility level
- `Components.BookAssociations` — owner sees suggestions with confirm/dismiss
- `Components.PartnerAvailability` stub on book detail (populated in Phase 2)

**Wave 3 DoD:**
- [ ] Marketplace listing creation and purchase flow works end-to-end
- [ ] Blog post can be written, saved as draft, published with visibility control
- [ ] LLM associations appear after publish and can be confirmed/dismissed
- [ ] Privacy settings page saves and reflects current visibility per shelf
- [ ] "View As" banner appears and correctly restricts visible content

#### Wave 4 (after 1E.3 APIs): Metrics + RSS

- `Page.Admin.Metrics` — metric cards, job status table, freshness gauge, cost tracker. Curator's desk aesthetic.
- RSS icon/link on shelf pages (`Components.RSSLink`)

**Wave 4 DoD:**
- [ ] Metrics dashboard shows real system data (Oban jobs, data freshness, costs)
- [ ] RSS icon on public shelves generates valid Atom feed URL

---

### Phase 1G — Platform & Deployment (platform-agent)
**Objective**: First successful deployment. CI pipeline green. All services deployed.
**Starts after**: All backend tracks (1B, 1C, 1D, 1E) and Elm waves committed.

See current Phase 1E content (renamed to 1G — Fly.io config, CI pipeline, Nix/Flox, developer experience). Additionally:
- Deploy Rust scraper as Fly Machine (private networking)
- Deploy SearXNG instance on Fly.io (for source discovery fallback)
- Ensure email delivery (Resend/Postmark) is configured
- Ensure KYC provider is configured (set `REQUIRE_KYC=true` for production)
- Ensure Stitch Money + Pargo are configured for marketplace

---

### Phase 1D — Python Vision Sidecar — DETAILED SPEC (python-agent)
**Objective**: FastAPI service with `/extract`, `/classify`, `/health` endpoints, plus `/associate` stub. Deployed on Modal.
**Starts after**: Repository scaffolding. Independent — runs in parallel with all Elixir work.

**Endpoints:**

| Method | Path | Purpose |
|--------|------|---------|
| `POST` | `/extract` | Send image, receive extracted text (title, author, potential ISBN) |
| `POST` | `/classify` | Send image, receive classification (book / not_book / ambiguous) |
| `GET` | `/health` | Health check |

> **Deferred to Phase 7**: `POST /associate` — accept blog post text, return book ISBNs with confidence scores (LLM association for `post_book_associations`).

**Files:**
- `apps/vision/app/main.py` — FastAPI app with 3 endpoints
- `apps/vision/app/models/extraction.py` — Pydantic models for request/response
- `apps/vision/app/models/classification.py`
- `apps/vision/app/services/vision_client.py` — Modal client (calls `VisionModel` on Modal)
- `apps/vision/app/services/hmac_auth.py` — HMAC token validation for internal requests
- `apps/vision/app/config.py` — model version pinning, budget defaults
- `apps/vision/tests/` — pytest test files
- `apps/vision/requirements.txt`
- `apps/vision/Dockerfile`

**Key constraints:**
- Never trust model output — always return raw extraction, let Phoenix validate
- Model version pinned in config (`Qwen/Qwen2.5-VL-7B-Instruct`)
- Budget tracking delegated to Phoenix (vision service just makes calls)
- HMAC auth on all endpoints — reject requests without valid `X-Internal-Token`
- `/extract` returns `books: list[ExtractedBook]` — always a list, even for single-book images. Empty list = nothing extractable. See Issue #008.
- `/classify` prompt: "Does this image contain enough information to identify a book?" — accepts screenshots and non-physical-book images. See Issue #008.
- Image pre-processing (orientation, horizontal flip correction, EXIF strip) happens in Phoenix **before** the image reaches the vision service. The vision service receives a canonical JPEG.

**Test command**: `cd apps/vision && python -m pytest`
**DoD:**
- [ ] `/extract` returns structured JSON with title, author, potential ISBNs
- [ ] `/classify` returns `{classification: "book" | "not_book" | "ambiguous", confidence: float}`
- [ ] `/health` returns 200
- [ ] HMAC auth rejects unsigned requests with 401
- [ ] All responses have Pydantic model validation
- [ ] `ruff check` and `ruff format --check` pass
- [ ] Type hints on all functions

---

### Phase 1D.1 — Vision Model Evaluation Framework (python-agent + human)
**Objective**: Build a reusable, repeatable evaluation framework for vision model selection. The framework must be re-runnable whenever a new model appears, a prompt changes, or an architectural decision has model-selection implications. Establish a quantitative baseline for the current model and compare candidates.

**Starts after**: Phase 1D committed and Modal deployment in place (can proceed before Phase 1E).
**Does not block**: Phase 1D.2 (local OCR pre-pass) or Phase 1E deployment. Models are swappable via `VISION_MODEL_NAME` env var. Initial performance at the 7B level is acceptable; the framework provides evidence for upgrading when needed.
**Should complete before**: Production launch at meaningful scale. The ISBN hard gate means silent misidentification is the primary risk. A benchmark failure may warrant a model upgrade before opening to users beyond the owner.
**Issue**: `issues/005-vision-model-benchmark.md`

**Why a framework, not a script**: This will be re-run. New models, new prompts, new architectural changes (Phase 1D.2 local OCR pre-pass) all require re-evaluation. A one-off script becomes stale; a framework with versioned configs, versioned prompts, and committed results stays useful.

**Corpus** (human task — assembled before running the harness):

| Stratum | Min | Description |
|---------|-----|-------------|
| `clean_barcode` | 10 | Barcode clearly visible, ISBN machine-readable |
| `spine_only` | 10 | Spine/title visible, no barcode |
| `oblique` | 5 | Angled, poor light, or low-res phone shot |
| `worn_or_partial` | 5 | Sticker over barcode, worn edge, partial cover |
| `mirrored_cover` | 5 | Front cover photographed in selfie/mirror mode — text horizontally flipped. Isolates whether pre-flip pre-processing is needed or whether the model handles it natively. |
| `multi_book_image` | 5 | Single image with multiple visible books (shelfie, stack). ISBN recall computed across all ground-truth books, not just first returned. |
| `screenshot_text` | 10 | Screenshot of text referencing books (social media, articles, reading lists). No physical book visible. Primary metric: title/author extraction and correct classification as book-related. |
| `not_book` | 10 | Objects, documents, people — must reject |
| `ambiguous` | 5 | Expected model output: `ambiguous` |

Ground truth locked in `corpus/annotations.csv` before any run. Append-only — no post-hoc changes.

**Models under test** (first experiment):
1. `Qwen/Qwen2.5-VL-7B-Instruct` — current default (smallest, cheapest)
2. `Qwen/Qwen2.5-VL-72B-Instruct` — higher OCR accuracy, ~10× cost
3. `meta-llama/Llama-3.2-11B-Vision-Instruct` — alternative architecture

**Metrics** (per stratum, not overall):
- Classification precision/recall/F1 per class (`book`, `not_book`, `ambiguous`)
- ISBN recall, ISBN false positive rate
- Title/author fuzzy similarity (SequenceMatcher ratio)
- Latency p50/p95/p99 at `VisionClient` level
- Cost per image and per 1,000 uploads

**Outputs** (committed to repository):
- `apps/vision/benchmark/results/YYYY-MM-DD-{run_id}-{model_label}.json` — raw per-image results
- `apps/vision/benchmark/reports/YYYY-MM-DD-{run_id}-{model_label}.md` — auto-generated report with per-stratum tables, threshold pass/fail, go/no-go recommendation
- Model selection decision recorded in `apps/vision/app/config.py` comment with rationale

**Justfile recipes added**:
- `just benchmark` — runs harness
- `just benchmark-compare` — side-by-side delta between two result files

**DoD:**
- [ ] `benchmark/` directory structure created
- [ ] `corpus/annotations.csv` schema defined, ≥ 50 images annotated
- [ ] `benchmark/run.py` implemented (reads TOML config, runs VisionClient, writes results JSON)
- [ ] `benchmark/metrics.py` implemented (per-stratum F1, ISBN recall, title similarity, latency, cost)
- [ ] `benchmark/compare.py` implemented (side-by-side delta table)
- [ ] Report generator implemented (reads results JSON, writes markdown)
- [ ] At least one experiment config committed (`configs/experiment-001.toml`)
- [ ] Prompts versioned in `prompts/` (not hardcoded)
- [ ] First run executed against all three candidate models
- [ ] Results JSON and report committed
- [ ] Production `model_name` confirmed or updated in `config.py` with rationale comment
- [ ] `just benchmark` and `just benchmark-compare` recipes added to justfile

---

### Phase 1D.2 — Local OCR Pre-pass (python-agent)
**Objective**: Add an in-process Tesseract/EasyOCR pass for ISBN barcodes before calling the Modal VLM. When a barcode is cleanly readable locally, skip the VLM entirely — reducing API cost and latency for the common case.

**Starts after**: Phase 1D committed. Does not require Phase 1D.1 to complete first — Phase 1D.2 is model-agnostic and additive. When local OCR finds nothing, the code path is identical to today. When it finds a barcode, it short-circuits the VLM call. Either way, the active VLM model does not matter.
**Parallel with**: Phase 1D.1 and Phase 1E (does not block deployment).
**Feeds back into Phase 1D.1**: Once Phase 1D.2 is implemented, run a benchmark experiment comparing the pre-pass+VLM pipeline against VLM-only to quantify cost/accuracy trade-off. This is a config change in the experiment TOML, not a new framework.

**Why this does not gate on the benchmark**: Phase 1D.2 is worth implementing regardless of model choice — local barcode reads are cheaper, faster, and more reliable than any VLM for clean barcode images. The benchmark informs whether to keep a 7B model or upgrade, not whether to add a local pre-pass.

**Implementation** (in-process, no new service):
- Add `pytesseract` (wraps system Tesseract) and/or `pyzbar` (pure-Python barcode decoder) to `requirements.txt`
- New function `local_isbn_scan(image_bytes) -> str | None` in `app/services/local_ocr.py`
- In `POST /extract`: attempt local scan first → if ISBN found with high confidence, return immediately without calling Modal → if not found or low confidence, fall through to VLM
- Threshold for "high confidence local result" is configurable via `app/config.py` (`local_ocr_confidence_threshold`, default `0.9`)
- The VLM path is always the fallback — local OCR failure is silent (not an error)

**Files:**
- `apps/vision/app/services/local_ocr.py` — barcode + basic OCR scan
- `apps/vision/app/config.py` — `local_ocr_enabled: bool = True`, `local_ocr_confidence_threshold: float = 0.9`
- `apps/vision/tests/test_local_ocr.py`
- `apps/vision/modal_app.py` — add `tesseract-ocr` to the Modal image pip_install / apt_install step

**DoD:**
- [ ] `local_isbn_scan` returns a valid ISBN string or `None`
- [ ] `/extract` skips VLM when local scan returns high-confidence result
- [ ] `/extract` falls through to VLM when local scan returns `None` or low confidence
- [ ] `local_ocr_enabled = False` disables the pre-pass entirely (escape hatch)
- [ ] Tests cover: clean barcode (local succeeds), no barcode (falls through), low confidence (falls through)
- [ ] Dockerfile updated with `tesseract-ocr` apt package
- [ ] `ruff check` passes

---

### Phase 1G — Platform & Deployment — DETAILED SPEC (platform-agent)
**Objective**: First successful Fly.io deployment. CI pipeline green. Dev environment reproducible. All services deployed.
**Starts after**: All backend tracks (1B, 1C, 1D, 1E) and Elm frontend committed.

#### 1E.1 — Fly.io Configuration

**Files:**
- `deploy/fly.core.toml` — Phoenix app, IAD region, 256MB RAM, health check at `/health`
- `deploy/fly.scraper.toml` — Rust scraper, IAD, 256MB, private networking only
- `deploy/Dockerfile.core` — multi-stage Elixir release (build with 1.18+, OTP 27; run on Alpine)
- `deploy/Dockerfile.scraper` — Rust multi-stage (builder + Alpine runtime)
- `apps/vision/modal_app.py` — Modal app definition (vision service; Modal builds the container)

#### 1E.2 — CI Pipeline (`.github/workflows/ci.yml`)

Uses `dorny/paths-filter` for monorepo path-scoped jobs:

| Job | Trigger paths | Steps |
|-----|--------------|-------|
| `test-elixir` | `apps/core/**` | `mix format --check-formatted`, `mix credo --strict`, `mix sobelow --config`, `mix deps.audit`, `mix test`, `mix coveralls` (80% gate) |
| `test-elm` | `frontend/**` | `elm-format --validate src/`, `elm-test`, `elm make src/Main.elm --optimize` |
| `test-rust` | `apps/scraper/**` | `cargo fmt --check`, `cargo clippy --deny warnings`, `cargo test`, `cargo audit` |
| `test-python` | `apps/vision/**` | `ruff check`, `ruff format --check`, `python -m pytest`, `pip audit` |
| `lint-proto` | `proto/**` | `buf lint proto/`, `buf breaking proto/ --against '.git#branch=main'` |
| `deploy` | `main` branch only | Build + deploy all 3 services to Fly.io |

#### 1E.3 — Developer Experience

- `flake.nix` verified with all tools
- `justfile` recipes all working
- `.env.example` complete and documented
- `docs/deployment/SETUP.md` — step-by-step first deployment guide
- `docs/deployment/FLY_SETUP.md` — Fly.io app creation, secrets, scaling
- `docs/deployment/DEV_SETUP.md` — local development with `nix develop`

#### 1E.4 — Nix/Flox Reproducible Builds (Phase 1 priority)

**Must be complete before Phase 1 ends.** The current build pipeline uses system-installed tools (Node.js, Elm, esbuild) which vary across developer machines and CI. By the end of Phase 1, all builds — local dev, CI, and Docker — must be reproducible via Nix/Flox.

**What this means:**
- `nix develop` provides the exact toolchain: Elixir, Erlang, Node.js, Elm, elm-format, elm-test, Rust, Python, buf, dbt, esbuild — all pinned versions
- `nix build` produces the Docker image deterministically (no `apk add` with unpinned versions, no `npm ci` fetching latest)
- CI runs inside the Nix shell (or uses a Nix-built Docker image), eliminating "works on my machine" class of bugs
- The Docker multi-stage build can optionally be replaced with a Nix-built container (using `dockerTools.buildLayeredImage`) for fully reproducible, smaller images
- `flake.lock` pins all inputs — Nixpkgs, Elm packages, Hex packages — so builds are identical regardless of when they run

**Why this is Phase 1 priority:**
- Alpine package version pinning in Dockerfiles is brittle (packages get removed from repos)
- npm ci + esbuild-plugin-elm works but adds ~200MB to the builder layer
- Nix caches aggressively — subsequent builds are near-instant
- Fly.io supports deploying Nix-built images via `fly deploy --image`
- Once real users are on the platform, build reproducibility is a reliability requirement, not a nice-to-have

**Test command**: `just test && just lint`
**DoD:**
- [ ] `fly deploy -c deploy/fly.core.toml` succeeds
- [ ] `fly deploy -c deploy/fly.scraper.toml` succeeds (private networking)
- [ ] `modal deploy apps/vision/modal_app.py` succeeds
- [ ] Phoenix app responds at public URL
- [ ] Vision service (Modal) reachable via `VISION_SERVICE_URL`
- [ ] CI pipeline passes on push to `main`
- [ ] `nix develop` drops into working shell on clean machine
- [ ] All `justfile` recipes work

**Pre-launch gate (Issue #005 — Neon branch data isolation):**
- [ ] `staging` Neon branch created; preview branches clone from `staging`, not `main`
- [ ] `deploy-preview.sh` uses `NEON_PARENT_BRANCH` (default: `staging`) for branch creation
- [ ] `Stacks.Release.seed/0` is not called in production deploy path
- [ ] `docs/deployment/NEON_BRANCH_TOPOLOGY.md` documents `main → staging → preview/<branch>` topology
- [ ] Must be completed before real users register — see `issues/005-neon-preview-branch-data-isolation.md`

#### Phase 1 Integration Test
After all tracks merge:
- [ ] Register owner account → onboarding flow appears (dismissable)
- [ ] Upload a book photo → verify ("We think this is…") → choose shelf (default WishList) → book created as work + edition
- [ ] Login redirects to `/antilibrary`
- [ ] Browse all 5 shelf views (4 show empty states, 1 shows the book; Looking for a Home shows community wear)
- [ ] Click spine → book detail **overlay** opens (URL unchanged); dismiss via Escape
- [ ] Move book between all 5 shelves (including Looking for a Home and back) → history recorded
- [ ] Search finds the book; platform-wide search scope available
- [ ] Upload a Kindle edition of same book → multi-format merge prompt → editions listed on detail overlay
- [ ] Settings hub accessible from display name dropdown; profile, location, password, notifications all work
- [ ] List view toggle renders table view of shelf
- [ ] ARIA labels present on spines and shelf container; keyboard navigation works
- [ ] Full CI pipeline green on `main`
- [ ] `docs/capacity-model.md` exists with Elm performance budget, API latency targets, cost model, and database growth projections
- [ ] `docs/runbooks/` contains at least: `modal-outage.md`, `neon-outage.md`, `oban-queue-backlog.md`, `vision-hallucination.md`, `budget-exhaustion.md`
- [ ] At least one Broadway pipeline (PricePipeline) ingests batched data with backpressure
- [ ] API latency targets are measured via Telemetry and surfaced on metrics dashboard

---

## Cross-cutting: Capacity Model & Performance Budget

A staff-level deliverable: define, measure, and enforce performance constraints across the system. This is not a single sub-phase — it's a set of artefacts produced alongside each sub-phase and maintained as the system evolves.

**Deliverable:** `docs/capacity-model.md` — a living document with the following sections:

### Elm Frontend Performance Budget

| Metric | Target | Measurement | Enforcement |
|--------|--------|-------------|-------------|
| Bookshelf render (500 books) | < 200ms | `elm-benchmark` or manual profiling | Test with fixture of 500 books in CI |
| Bookshelf render (2,000 books) | < 500ms | Same | Documented as soft limit — consider pagination above 2K |
| Book detail overlay open | < 100ms (cached), < 500ms (cold API) | `Performance.now()` in Elm port | Alert in metrics dashboard if P95 > 1s |
| Search (local, all shelves) | < 50ms for 2,000 books | Elm-side timing | All book data in memory — test at scale |
| Page load (initial, cold) | < 3s on 3G | Lighthouse CI | `--budget-path` in CI |

**When to produce:** 1F Wave 1 (once shelves render). Revisit each wave.

### API Latency Targets

| Endpoint | P50 | P95 | P99 | Notes |
|----------|-----|-----|-----|-------|
| `GET /api/bookshelves/:name` | 30ms | 100ms | 200ms | Single user's shelf — indexed query |
| `GET /api/books/:id` (detail) | 50ms | 150ms | 300ms | Joins work + editions + enrichment |
| `POST /api/upload/identify` | 15-30s | 45s | 60s | Dominated by Modal cold start |
| `POST /api/books/confirm` | 30ms | 100ms | 200ms | DB writes only |
| `GET /api/search/platform` | 100ms | 500ms | 1s | Cross-user query — may need materialised index |
| `POST /api/auth/login` | 100ms | 200ms | 500ms | Argon2 hashing is intentionally slow |

**When to produce:** 1B.2 (after controllers exist). Enforce via `Telemetry.Metrics` + PromEx. Surface on metrics dashboard (1E.3).

### Cost Model (per-user projection)

| Scale | Books/user | Modal (vision) | Brave Search | Fly.io | Neon | Total/user/mo |
|-------|-----------|----------------|--------------|--------|------|---------------|
| 10 users | 200 avg | ~R10 (20 uploads/mo) | ~R0 (free tier) | R50 (shared) | R0 (free tier) | ~R6/user |
| 100 users | 300 avg | ~R100 | ~R15 (paid tier) | R150 | R50 | ~R3.15/user |
| 1,000 users | 300 avg | ~R500 | ~R150 | R500 | R200 | ~R1.35/user |
| 10,000 users | 300 avg | ~R2,000 | ~R1,500 | R2,000 | R1,000 | ~R0.65/user |

**Assumptions documented.** Modal: R0.50/identification, 2 uploads/user/month at scale. Brave: R0.003/query, ~50 queries/user/month. Fly.io: scales with machine count. Neon: scales with storage + compute.

**Trigger points:**
- At 100 users: evaluate Brave Search paid tier
- At 500 users: evaluate Neon scaling tier, consider read replicas
- At 1,000 users: evaluate DuckDB for `wh` schema analytical queries
- At 5,000 users: evaluate Snowflake / ClickHouse for time-series data (price history)

**When to produce:** 1E.3 (metrics dashboard provides the data to validate projections). Revisit quarterly.

### Database Growth Model

| Table | Growth rate | Size at 1K users | Partitioning trigger |
|-------|-----------|-------------------|---------------------|
| `price_snapshots` | ~2,500 rows/day (500 books x 5 stores) per user batch | ~5M rows/year | Partition by month at 10M rows |
| `event_log` | ~50 events/user/day | ~18M rows/year | Partition by month at 5M rows |
| `review_snapshots` | ~3 rows/book/quarter | ~900K rows/year | No partitioning needed |
| `bookshelf_placement_history` | ~5 transitions/user/month | ~60K rows/year | No partitioning needed |

**When to produce:** 1A (designed with migrations). Validate at 1G (first deployment with real data).

---

## Cross-cutting: Operational Runbooks

**Deliverable:** `docs/runbooks/` directory with incident response playbooks. Produced alongside the sub-phase that introduces each operational dependency.

### Runbooks to produce

| Runbook | When | Content |
|---------|------|---------|
| `modal-outage.md` | 1D | Modal vision service down: symptoms (upload timeouts), impact (no new books can be added via photo — manual ISBN entry still works), response (check Modal status page, verify HMAC config, confirm circuit breaker has tripped, monitor Oban `vision` queue backlog). Recovery: Oban retries automatically when Modal returns. |
| `neon-outage.md` | 1G | Neon Postgres down: symptoms (all API calls fail with 500), impact (total platform outage), response (check Neon status, verify connection string, check Fly.io logs for connection pool exhaustion). Recovery: Neon auto-recovers; Ecto pool reconnects. No cached read path in current architecture — document this as a known limitation. |
| `oban-queue-backlog.md` | 1B.1 | Oban queue backs up: symptoms (jobs in `available` state growing, data freshness dropping on metrics dashboard), diagnosis (check per-queue depth via `Oban.Met` or `SELECT count(*) FROM oban_jobs WHERE state = 'available' GROUP BY queue`), response (check for failed workers, increase concurrency temporarily, check circuit breakers on external services). |
| `vision-hallucination.md` | 1D | Vision model starts returning valid-but-wrong ISBNs: symptoms (identification success rate drops, users report wrong books), diagnosis (check `int_upload_rejection_rate` trend, sample recent `uploaded_images` resolutions), response (enable `REQUIRE_MANUAL_CONFIRM=true` flag to force user verification on every upload — already the default flow, but this makes it non-skippable for bulk). Escalation: run benchmark suite (1D.1) against recent corpus. |
| `stitch-money-failure.md` | 1E.1 | Payment processing fails: symptoms (checkout returns error, `transactions.payment_status = 'failed'`), impact (marketplace sales blocked), response (check Stitch Money status, verify webhook secret, check Fly.io logs for webhook delivery). Recovery: buyer can retry. Seller's listing remains active. No money has moved. |
| `budget-exhaustion.md` | 1B.2 | AI budget limit reached: symptoms (`BudgetTracker` snoozing all vision jobs, uploads return "try again later"), impact (no photo-based book additions — manual ISBN entry still works), response (check `BudgetTracker` state, verify daily/monthly limits are appropriate, check for runaway retry loops). Recovery: budget resets at midnight UTC (daily) or 1st of month (monthly). |
| `email-delivery-failure.md` | 1E.3 | Resend/Postmark delivery fails: symptoms (registration confirmation emails not arriving, `EmailDeliveryJob` failures in Oban), impact (new users can't confirm email — if email confirmation is required, registration is blocked), response (check provider dashboard, verify API key, check domain SPF/DKIM). |

### Runbook template

```markdown
# Runbook: [Service/Component] — [Failure Mode]

## Symptoms
- What the user sees
- What the operator sees (logs, metrics, alerts)

## Impact
- What's broken
- What still works (degraded mode)

## Diagnosis
- Commands to run
- Metrics to check
- Logs to inspect

## Response
- Immediate actions
- Escalation criteria

## Recovery
- How the system self-heals (if applicable)
- Manual recovery steps
- Post-incident verification
```

---

## Cross-cutting: Broadway Pipelines (enrichment ingestion)

Broadway pipelines are described in `docs/technical-architecture.md` section 6 as the ingestion mechanism for enrichment data. They must be implemented — not just documented — as part of Phase 1C.2 (enrichment contexts).

**Where Broadway is required:**

| Pipeline | Sub-Phase | Purpose |
|----------|-----------|---------|
| `Stacks.Enrichment.ReviewPipeline` | 1C.2 | Ingest reviews from GoodReads, Reddit, Storygraph. Backpressure prevents overwhelming scraped sites. Batched DB writes. |
| `Stacks.Enrichment.PricePipeline` | 1C.2 | Ingest price data from Rust scraper responses. Batch-insert into `price_snapshots`. Rate-limit signals back to scraper. |
| `Stacks.Enrichment.AuthorPipeline` | 1C.2 | Ingest author data from Open Library, RSS feeds, Brave Search. Dedup across sources. |
| `Stacks.Enrichment.EventPipeline` | 1C.2 | Ingest bookstore events. Match against user's book/author graph. |

**Why Broadway, not just Oban workers:**
- Oban workers are fire-and-forget individual jobs. Broadway provides **backpressure** (producers slow down when consumers are saturated), **batching** (group DB writes for efficiency), and **rate limiting** (respect external API quotas). For enrichment — where you're hitting dozens of external sites with hundreds of ISBNs — these properties matter.
- The Oban workers (`FetchReviewsJob`, `TriggerPriceScrapeJob`, etc.) remain as the *triggers*. Broadway handles the *ingestion* after the external call returns data.

**1C.2 DoD addition:**
- [ ] At least one Broadway pipeline (PricePipeline) ingests batched data from the Rust scraper with backpressure
- [ ] Broadway pipelines have `handle_failed/2` callbacks that log failures without crashing the pipeline
- [ ] Rate limiting per external source is enforced at the Broadway producer level

---

## Phase 2: Deferred Features (Future)

> Third Spaces, partner push API, groups, comments/Q&A, closed bid marketplace. Built after Phase 1 is stable and deployed.

### Phase 2A — Third Spaces (elixir-agent + elm-agent)
- `Stacks.ThirdSpaces` context with scraping support
- `Page.ThirdSpaces` — cork board with `Components.CorkBoard`, `Components.SpaceCard`, `Components.LocationFilter`
- SearXNG-driven discovery (infrastructure already deployed in 1G)
- User-submitted third spaces
- Depends on: source discovery agent (1C.2), geographic sweep (1C.2), location settings (1B.1)

### Phase 2B — Partner Integration (protobuf-agent + elixir-agent + elm-agent)
- Protobuf partner schemas: `inventory.proto`, `events.proto`, `spaces.proto`
- `Stacks.Partners` — registration, approval, API key auth, inventory sync, events, spaces
- Partner dashboard (Elm) — registration form, CSV import, event management, metrics
- Reader-facing: `Components.PartnerAvailability` on book detail, green dot on spines
- Owner-facing: partner approval queue, moderation, content management

### Phase 2C — Groups (elixir-agent + elm-agent)
- `Stacks.Social` extended — `create_group/2`, invite, accept, remove, leave, dissolve
- Group content feed (US-11.1.5) — aggregated blog + shelf activity
- `Page.Groups` — creation, member management, content feed
- Depends on: visibility infrastructure (1B.3), blog (1E.2)

### Phase 2D — Comments & Q&A (elixir-agent + elm-agent)
- `Stacks.Comments` — threaded comments with block-filtered CTE
- Blog comments (US-13.1.1, US-13.1.2)
- Marketplace Q&A (US-13.2.1) — public questions on listings
- Private offer threads (US-13.2.2) — buyer-seller negotiation
- Depends on: visibility (1B.3), blog (1E.2), marketplace (1E.1)

### Phase 2E — Marketplace Enhancements
- Offers mode (open to offers with minimum price)
- Closed bid mode (invited users, sealed offers)
- Full refund/dispute/non-delivery flows
- Depends on: basic marketplace (1E.1)

---

> **The following sections contain detailed content from the original phased roadmap. They are preserved as reference for the sub-phases above that reference them ("See current Phase 2A/2B/4B/4C/5B/7B content"). Once the Phase 1 sub-phases are implemented, these sections should be archived or removed.**

---

## REFERENCE: Original Phase 2 — Enrichment (now Phase 1C)

> Layer intelligence on top of the book graph: reviews, prices, author info, events, and source discovery.

### Phase 2A — Rust Scraper Implementation (rust-agent)
**Objective**: Bookshop price scraper works end-to-end with TOML configs for SA stores.
**Starts after**: Phase 1 committed.

**Files:**
- `apps/scraper/src/main.rs` — HTTP server with internal API endpoints
- `apps/scraper/src/config.rs` — TOML config loader
- `apps/scraper/src/scraper.rs` — generic scrape engine (reqwest + scraper crate)
- `apps/scraper/src/stores/mod.rs` — store-specific parsers
- `apps/scraper/src/rate_limiter.rs` — per-domain rate limiting
- `apps/scraper/src/robots.rs` — robots.txt compliance
- `scrapers/za/exclusive_books.toml`, `scrapers/za/takealot.toml` — initial configs

**Internal API:**
- `POST /scrape` — accept batch of ISBNs, return prices per store
- `POST /config/reload` — reload TOML configs
- `GET /health`

**Test command**: `cargo test`
**DoD:**
- [ ] Scraper fetches prices from at least 2 SA bookshops given an ISBN
- [ ] TOML config drives scraper behaviour (no hardcoded selectors)
- [ ] Rate limiting enforced per domain
- [ ] `robots.txt` checked before scraping
- [ ] HMAC auth on all endpoints
- [ ] Error handling via `thiserror`/`anyhow` — no `unwrap()` in production code

---

### Phase 2B — Enrichment Contexts (elixir-agent)
**Objective**: Review aggregation, price tracking, author intelligence, bookstore events, source discovery — all wired to Oban jobs.
**Starts after**: Phase 1B committed. Parallel with Phase 2A.

**Contexts:**
- `Stacks.Enrichment.Reviews` — `get_review_summary/1`, `FetchReviewsJob` (GoodReads, Reddit, Storygraph)
- `Stacks.Enrichment.Prices` — `get_price_history/1`, `TriggerPriceScrapeJob` (signals Rust scraper)
- `Stacks.Enrichment.Authors` — `get_author_intel/1`, `FetchAuthorRSSJob`, `DiscoverAuthorSourcesJob`
- `Stacks.Enrichment.Events` — `get_matched_events/1`, `DiscoverBookstoreEventsJob`
- `Stacks.Discovery` — `Agent` (Oban-driven), `search_and_score/1`, `approve_source/1`, `reject_source/1`
- `Stacks.Discovery.GeographicSweep` — location-based discovery of bookshops, reading groups, cafes (US-2.5.2). Triggered by `user.location_updated` event + quarterly cron.
- `Stacks.Discovery.OptOut` — business opt-out flow: `request_removal/1`, `process_removal/1`, `add_to_exclusion_list/1` (US-2.5.3). Unauthenticated `POST /api/opt-out` endpoint.
- `Stacks.Admin.ScraperConfig` — CRUD for bookstore scraper configs

**Oban workers:**
- `FetchReviewsJob` (adaptive staleness)
- `TriggerPriceScrapeJob` (daily)
- `DiscoverAuthorSourcesJob` (weekly)
- `FetchAuthorRSSJob` (hourly)
- `DiscoverBookstoreEventsJob` (daily)
- `SourceDiscoveryJob` (daily)
- `ScoreSourceJob` (on-demand, LLM scoring)
- `GeographicDiscoveryJob` (event-driven + quarterly cron) (US-2.5.2)
- `OptOutConfirmationJob` (on-demand — sends confirmation email) (US-2.5.3)

**Controllers:**
- `StacksWeb.Admin.ScraperConfigController`
- `StacksWeb.Admin.SourceApprovalController`

**dbt models:**
- `stg_review_snapshots`, `stg_price_snapshots`, `stg_authors`, `stg_bookstore_events`, `stg_discovered_sources`
- `int_review_sentiment`, `int_price_trends`, `int_author_activity`, `int_event_matches`, `int_source_approval_rate`, `int_book_engagement`
- `mart_book_reviews`, `mart_book_prices`

**Test command**: `mix test`
**DoD:**
- [ ] Review aggregation fetches and stores snapshots (mocked external sources in test)
- [ ] Price tracking triggers Rust scraper and stores results
- [ ] Author intelligence discovers and stores author RSS feeds
- [ ] Source discovery scores URLs with LLM confidence
- [ ] Human approval flow works: discover -> score -> approve/reject
- [ ] Geographic sweep discovers local spaces when location is set (US-2.5.2)
- [ ] Business opt-out: `POST /api/opt-out` sets status to excluded, prevents re-discovery (US-2.5.3)
- [ ] All enrichment data surfaces on book detail overlay API response
- [ ] dbt staging + intermediate models pass `dbt test`

---

### Phase 2C — Enrichment Frontend (elm-agent)
**Objective**: Book detail page shows real enrichment data. Admin pages for scraper config and source approval.
**Starts after**: Phase 2B API endpoints exist.

**Components updated:**
- `Components.ReviewSummary` — sentiment bar, source cards with rating + link
- `Components.PriceInfo` — current prices by store, sparkline chart, lowest price highlight
- `Components.AuthorCard` (expanded) — website, RSS posts, events, new releases
- `Page.Events` — event cards matched to user's books/authors

**New pages:**
- `Page.Admin.ScraperConfig` — TOML editor with validation
- `Page.Admin.SourceApproval` — discovered sources queue with confidence scores

**DoD:**
- [ ] Book detail page shows reviews, prices, author info when available
- [ ] Price sparkline renders with SVG
- [ ] Scraper config admin page saves valid TOML
- [ ] Source approval page shows approve/reject actions

#### Phase 2 Integration Test
- [ ] Add a book -> enrichment jobs fan out -> book detail page shows reviews + prices + author info
- [ ] Rust scraper returns prices for a known ISBN
- [ ] Source discovery finds and scores a URL; admin approves it

---

## REFERENCE: Original Phase 3 — Partner Integration & EDA (now split: EDA in 1B.1, partners deferred to Phase 2B)

> Inbound partner API, dashboard, CSV import. Event-driven architecture lands as cross-cutting infrastructure.

### Phase 3A — Protobuf Schemas (protobuf-agent)
**Objective**: All `.proto` files authored, `buf lint` passes, code generation works for all 4 languages.
**Starts after**: Phase 2 committed (or can start in parallel).

**Proto files:**
- `proto/stacks/common/book.proto` — Book, Author, ISBN messages
- `proto/stacks/common/location.proto` — Country, City, Coordinates
- `proto/stacks/partner/inventory.proto` — `InventorySyncRequest`, `InventoryItem`
- `proto/stacks/partner/events.proto` — `PartnerEvent`
- `proto/stacks/partner/spaces.proto` — `Space`
- `proto/stacks/internal/event_bus.proto` — `EventEnvelope` (event_type, aggregate_type, aggregate_id, schema_version, payload, metadata, occurred_at)
- `proto/stacks/internal/enrichment.proto` — `EnrichmentRequest`, `EnrichmentResult`

**Code generation:**
- Run `buf generate proto/`
- Verify Elixir, Rust, Python outputs in `proto/gen/` (gitignored)
- Generate and commit Elm decoders in `proto/gen/elm/`

**DoD:**
- [ ] `buf lint proto/` passes
- [ ] `buf generate proto/` produces valid code for all 4 languages
- [ ] Elm decoders checked in and compile
- [ ] `buf breaking` baseline established on `main`

---

### Phase 3B — Event-Driven Architecture (elixir-agent)
**Objective**: Event bus infrastructure exists. All MVP actions emit events. Subscribers registered.
**Starts after**: Phase 3A committed (event envelope is a proto).

**Core module: `Stacks.Events`**
- `emit/1` — insert into `event_log`, enqueue `EventSubscriberWorker` per registered subscriber
- `replay/3` — replay events for a given aggregate (useful for rebuilding read models)
- `Stacks.Events.Registry` — subscriber mapping (`event_type -> [handler_module]`)
- `Stacks.Events.Upcaster` — pattern-matched version transforms
- `Stacks.Events.SubscriberWorker` — Oban worker that dispatches to subscriber modules

**Events to emit (retrofit into Phase 1 contexts):**
- `book.created`, `book.updated`
- `shelf.book_placed`, `shelf.book_moved`, `shelf.book_removed`
- `enrichment.reviews_fetched`, `enrichment.prices_fetched`
- `moderation.completed`

**Subscribers to register:**
- `RecalculateWearJob` subscribes to `shelf.book_moved`
- `RegenerateFeedJob` subscribes to `shelf.*` (Phase 4)
- `PartnerMetricsSnapshotJob` subscribes to `partner.*` events (Phase 3C)

**Test command**: `mix test test/core/events_test.exs`
**DoD:**
- [ ] `Stacks.Events.emit/1` writes to `event_log` and enqueues subscriber workers
- [ ] Subscribers receive correct events
- [ ] Event replay works for a given aggregate
- [ ] Upcaster transforms v1 events to current schema
- [ ] All MVP shelf operations emit events
- [ ] Event envelope matches proto schema

---

### Phase 3C — Partner Integration (partner-agent + elixir-agent)
**Objective**: Partners can register, push inventory/events/spaces via API, manage content via dashboard. Owner approves and moderates.
**Starts after**: Phase 3B committed (partner actions emit events).

**Contexts:**
- `Stacks.Partners` — `register/1`, `approve/1`, `decline/2`, `suspend/1`, `reinstate/1`, `rotate_key/1`, `get_status/1`, `resubmit/2`, `update_profile/2`
- `Stacks.Partners.Inventory` — `sync/2` (upsert/remove), `available_for/1`
- `Stacks.Partners.Inventory.CSVImport` — parse, validate, preview, confirm
- `Stacks.Partners.Events` — `create/2`, `update/2`, `cancel/1`
- `Stacks.Partners.Spaces` — `register/2`, `update/2`
- `Stacks.Partners.Metrics` — aggregate queries on `event_log`, counts rounded to nearest 10
- `Stacks.Partners.Validation` — ISBN checksum, positive price, future date, text blocklist
- `Stacks.ThirdSpaces` — `suggest/2` (user-submitted spaces)

**Plugs:**
- `StacksWeb.Plugs.PartnerAuth` — API key extraction, Argon2 verify, partner status check
- `StacksWeb.Plugs.SchemaValidation` — Protobuf-generated JSON schema validation
- `StacksWeb.Plugs.PartnerRateLimiter` — 100/min, 10k/day

**Controllers (two sets — API for technical partners, Dashboard for non-technical):**
- `StacksWeb.PartnerAPI.InventoryController`, `EventController`, `SpaceController`, `MetricsController`
- `StacksWeb.PartnerDashboard.InventoryController` (CSV import), `EventController` (form), `ProfileController`, `MetricsController`
- `StacksWeb.PartnerController` — registration
- `StacksWeb.PartnerStatusController` — token-based status checking
- `StacksWeb.PartnerSettingsController` — key management

**Oban workers:**
- `PartnerApprovalNotificationJob` (event-driven)
- `PartnerISBNResolveJob` (event-driven)
- `ArchivePartnerEventsJob` (daily)
- `PartnerMetricsSnapshotJob` (daily)

**Events emitted:**
- `partner.registered`, `partner.approved`, `partner.suspended`
- `inventory.updated`, `event.created`, `space.registered`

**dbt models:**
- `stg_partners`, `stg_partner_inventory`, `stg_partner_events`, `stg_partner_spaces`
- `int_partner_approval_rate`, `int_partner_availability`, `int_partner_impressions`, `int_partner_clicks`, `int_partner_event_calendar`, `int_partner_validation_errors`, `int_partner_onboarding_funnel`, `int_partner_moderation`
- `mart_partner_stock_coverage`, `mart_partner_engagement`

**Test command**: `mix test test/core/partners_test.exs`
**DoD:**
- [ ] Partner registration -> owner approval -> API key generation flow works
- [ ] Partner status page accessible via token link
- [ ] Partner profile self-service update with immediate/approval-required field split
- [ ] Push inventory API validates against Protobuf schema, stores items, resolves unknown ISBNs
- [ ] CSV import: upload -> preview (matched/pending/invalid) -> confirm -> ingest
- [ ] Push events API stores events, auto-archives past events
- [ ] Event dashboard: create/edit/cancel events via form
- [ ] Space registration with owner approval
- [ ] User-submitted third spaces with `discovered_via: 'user_submission'`
- [ ] Partner metrics show rounded counts with sparklines
- [ ] Owner moderation: approve/decline/flag/suspend partner content
- [ ] Automated validation rejects malformed payloads with structured errors
- [ ] All partner actions emit events to `event_log`

---

### Phase 3D — Partner Frontend (elm-agent)
**Objective**: Partner registration form, dashboard pages, reader-facing partner availability.
**Starts after**: Phase 3C API endpoints exist.

**Partner-facing pages:**
- `Page.Partner.Register` — registration form
- `Page.Partner.Status` — progress tracker with resubmission (US-9.7.1)
- `Page.Partner.Settings` — API key management
- `Page.Partner.Profile` — self-service profile with live preview (US-9.7.2)
- `Page.Partner.Events` — event list + form
- `Page.Partner.InventoryImport` — CSV upload with preview table
- `Page.Partner.Metrics` — engagement counters with sparklines

**Owner-facing pages:**
- `Page.Metrics.PartnerRequests` — approval queue as index cards
- `Page.Metrics.PartnerManagement` — partner table with status/content count

**Reader-facing components:**
- `Components.PartnerAvailability` on `Page.BookDetail` — "Available at [Shop] for R149" (US-9.8.1)
- `Components.Spine` updated — green dot for partner-stocked books
- `Components.PartnerEventCard` on Third Spaces cork board — hand-lettered flyer style
- `Components.PartnerSpaceCard` — vintage postcard style
- `Components.CommunitySpaceCard` — handwritten "suggested by a reader" style

**DoD:**
- [ ] Partner registration form submits and shows confirmation
- [ ] Partner status page renders all states (pending/changes requested/approved/declined)
- [ ] Partner dashboard: manage events, upload CSV, view metrics
- [ ] Book detail page shows "Available at" section when partner inventory exists
- [ ] Spine green dot renders for books with partner availability
- [ ] Third Spaces cork board shows partner events and spaces with distinct styles

#### Phase 3 Integration Test
- [ ] Register a partner -> owner approves -> partner gets API key
- [ ] Partner pushes inventory via API -> books show "Available at" on detail page
- [ ] Partner creates event via dashboard -> event appears on cork board
- [ ] Partner uploads CSV -> preview -> confirm -> inventory updated
- [ ] Partner views engagement metrics (rounded counts)
- [ ] Owner flags partner content -> content hidden, partner notified

---

## REFERENCE: Original Phase 4 — Polish (now 1E.3 for RSS/Metrics, Third Spaces deferred to Phase 2A)

> Community features, operational visibility, sharing.

### Phase 4A — Third Spaces Scraping (elixir-agent + elm-agent)
**Objective**: Cork board page with discovered reading spaces. Brave Search + SearXNG discovery.
**Starts after**: Phase 3 committed (cork board infrastructure exists from partner integration).

- `Stacks.ThirdSpaces` context extended with scraping support
- `Stacks.Workers.DiscoverThirdSpacesJob` (weekly)
- `Page.ThirdSpaces` — cork board with `Components.CorkBoard`, `Components.SpaceCard`, `Components.LocationFilter`
- SearXNG instance deployment on Fly.io

**DoD:**
- [ ] Third spaces discovery job finds spaces via Brave Search
- [ ] Cork board renders with location filtering
- [ ] User can pin a new space (US-9.4.2)

---

### Phase 4B — RSS/OPDS Feeds (elixir-agent)
**Objective**: Atom feed per public shelf. OPDS catalogue.

- `Stacks.Feeds` context — `generate_atom/2`, `generate_opds/2`
- `StacksWeb.FeedController` — serves XML with ETag/Last-Modified caching
- `Stacks.Workers.RegenerateFeedJob` — event-driven (subscribes to `shelf.*` events)

**DoD:**
- [ ] Atom feed per shelf returns valid XML
- [ ] OPDS catalogue returns valid OPDS 1.2
- [ ] Feed regenerates when shelf changes (event-driven)
- [ ] CDN caching headers set correctly

---

### Phase 4C — Metrics Dashboard (elixir-agent + elm-agent)
**Objective**: Operational metrics for the platform owner. Curator's desk aesthetic.

- `Stacks.Admin.Metrics` context — aggregates from Oban telemetry, dbt freshness, audit log
- `Page.Admin.Metrics` — metric cards, job status table, freshness gauge, cost tracker
- dbt models: `mart_system_health`, `mart_job_stats`, `mart_data_freshness`, `mart_cost_tracking`, `mart_gdpr_compliance`

**DoD:**
- [ ] Dashboard shows Oban job health, data freshness, AI spend
- [ ] Partner management section integrated (from Phase 3D)
- [ ] dbt mart models pass `dbt test`

#### Phase 4 Integration Test
- [ ] Third Spaces cork board renders discovered + partner + user-submitted spaces
- [ ] RSS reader successfully subscribes to a shelf feed
- [ ] Metrics dashboard shows real system data

---

## REFERENCE: Original Phase 5 — Marketplace (now 1E.1, simplified)

> Listings, public Q&A, private offer threads, payments, shipping. Depop/Vinted interaction model. Deferred until core platform is stable.

### Phase 5A — Marketplace Tables (database-agent)
**Objective**: Marketplace tables exist. Listing columns already on `bookshelf_placements` (Phase 1A); these are the transaction and communication tables.

Migrations:
1. `create_offer_threads` — `listing_mode` context (fixed | offers; closed bid deferred); status: pending -> accepted -> declined -> withdrawn -> expired
2. `create_offer_messages` — individual messages within an offer thread; `message_type`: offer | counter_offer | question | answer | system
3. `create_transactions` — `payment_status`, `shipping_status`, FK to accepted `offer_thread_id`

> **Listing state machine** (on `bookshelf_placements.listing_status`): draft → active → sold → removed → expired
> **Offer state machine** (on `offer_threads.status`): pending → accepted / declined / withdrawn / expired
> **Closed bid mode**: deferred to a future phase.
> **Post-sale lifecycle** (US-7.2): On sale completion, seller's placement is soft-deleted. `MarketplaceSaleWorker` checks buyer's WishList and prompts to add the book. If already on WishList, offers to move to Library/AntiLibrary.

---

### Phase 5B — Marketplace Backend (elixir-agent)
**Objective**: Listing, Q&A, offer thread, and transaction flows with Stitch Money and Pargo integration. KYC for sellers.

- `Stacks.Marketplace` context — `create_listing/1`, `update_listing/2`, listing state machine
- `Stacks.Marketplace.QnA` — `post_question/2`, `post_answer/2` (public; moderation applies)
- `Stacks.Marketplace.Offers` — `create_offer_thread/2`, `send_message/2`, `accept_offer/1`, `decline_offer/1`, `withdraw_offer/1`
- `Stacks.Marketplace.Transactions` — `initiate_payment/1`, `confirm_payment/1`, `create_shipment/1`
- `Stacks.Marketplace.SellerVerification` — KYC via Smile Identity / Yoti / Sumsub
- Oban workers: `ListingExpiryJob`, `OfferExpiryJob`, `PaymentCallbackJob`, `ShipmentTrackingJob`, `MarketplaceSaleWorker` (post-sale buyer prompt)
- Webhook handlers for Stitch Money and Pargo callbacks

**dbt models:**
- `stg_offer_threads`, `stg_offer_messages`
- `int_offer_activity`
- `mart_marketplace_offers`, `mart_marketplace_activity`, `mart_transaction_volume`, `mart_marketplace_revenue`

---

### Phase 5C — Marketplace Frontend (elm-agent)
**Objective**: Listing creation, public Q&A, private offer threads, purchase flow, seller onboarding.

- `Page.Marketplace.CreateListing` — condition grader, price, listing mode toggle (fixed/offers)
- `Page.Marketplace.ListingDetail` — public Q&A thread, "Make an Offer" button
- `Page.Marketplace.OfferThread` — private offer/counter-offer/accept/decline flow
- `Page.Marketplace.Checkout` — payment via Stitch Money
- `Page.Marketplace.SellerOnboarding` — KYC flow
- `Components.ConditionGrader`, `Components.OfferModal`, `Components.QnAThread`

#### Phase 5 Integration Test
- [ ] Seller KYC -> list book (from any shelf) -> buyer posts question -> seller answers -> buyer makes offer -> seller accepts -> payment -> shipping
- [ ] Post-sale: seller's book removed from Looking for a Home; buyer prompted to add (WishList detection works)
- [ ] Listing expires automatically after configured period
- [ ] Offer expires automatically if no response

---

## REFERENCE: Original Phase 6 — Social Graph & Visibility (now 1B.3, groups deferred to Phase 2C)

> Fine-grained visibility controls, groups, block graph. Prerequisite for public profiles and selective sharing.

### Phase 6A — Social Graph Tables (database-agent)
**Objective**: All social graph and visibility tables exist.

Migrations:
1. `create_user_blocks` — bidirectional blocks; unique `(blocker_id, blocked_id)`
2. `create_groups` — `group_type` enum: `broadcast | close_friends | subscription`; owner-only creation
3. `create_group_members` — `role` enum: `owner | moderator | member`
4. `create_group_invitations` — token-based invitations with expiry
5. `create_visibility_grants` — per-object grants to specific users (`grantee_id`, `resource_type`, `resource_id`)

**Visibility columns** (already on tables from Phase 1A):
- `users.profile_visibility` — `owner | group | platform`
- `bookshelves.visibility`, `bookshelves.visibility_group_id`
- `bookshelf_placements.visibility`

**Ceiling rule**: child visibility ≤ parent visibility. Enforced at write time in context layer.

---

### Phase 6B — Visibility & Social Graph Backend (elixir-agent)
**Objective**: `resolve_visibility/2` gate, block graph, group management, `ViewAsPlug`.

- `Stacks.Visibility` context
  - `resolve_visibility/2` — single authoritative gate; viewer contexts: `:unauthenticated`, `{:platform_user}`, `{:specific_user, user_id}`, `{:group_member, group_id}`
  - `can_view?/2`, `viewable_shelves/2`, `viewable_placements/2`
  - Ceiling rule enforcement on write: `validate_visibility_ceiling/3`
- `Stacks.Social` context
  - `block_user/2`, `unblock_user/2`, `is_blocked?/2`, `blocked_by?/2`
  - `create_group/2`, `invite_member/3`, `accept_invitation/2`, `remove_member/2`, `leave_group/2`, `dissolve_group/1`
  - `visible_groups/1` — member-list never exposed outside interactive spaces
- `Stacks.Groups.Feed` — `get_feed/2` (US-11.1.5): aggregated blog posts + shelf activity from group members, filtered by visibility + blocks. Behaviour varies by group type (close_friends: all members; broadcast/subscription: owner only).
- `StacksWeb.Plugs.ViewAsPlug` — owner sets `?view_as=user_id` param; plug sets viewer context; 403 for non-owners
- Retrofit: all existing content endpoints route through `resolve_visibility/2`

**Events emitted:**
- `social.user_blocked`, `social.group_created`, `social.member_joined`, `social.member_removed`

**dbt models:**
- `stg_user_blocks`, `stg_groups`, `stg_group_members`
- `int_group_activity`, `int_visibility_resolution`
- `mart_social_graph_health`

**DoD:**
- [ ] `resolve_visibility/2` passes all ceiling-rule and block-graph scenarios
- [ ] Blocked users see 404 (not 403) for owner-profile content
- [ ] `ViewAsPlug` correctly impersonates viewer context for owner
- [ ] Group member list not exposed in API responses
- [ ] Leave group produces no owner notification
- [ ] All shelf/placement writes enforce ceiling rule

---

### Phase 6C — Visibility Frontend (elm-agent)
**Objective**: Privacy settings, group management, "View As" mode.

- `Page.Settings.Privacy` — profile visibility selector, per-shelf overrides, ceiling rule UI hint
- `Page.Settings.Groups` — create/manage groups, invite flow
- `Page.Groups.Detail` — members (visible to owner only), content feed (US-11.1.5: reverse-chronological blog posts + shelf activity from members)
- `Components.VisibilityBadge` — lock icon with tooltip per visibility level
- `Components.ViewAsBar` — sticky banner when viewing as another user

**DoD:**
- [ ] Privacy settings page saves and reflects current visibility per shelf
- [ ] Group invite link generates and can be accepted
- [ ] "View As" banner appears and correctly restricts visible content

---

## REFERENCE: Original Phase 7 — Blog & Comments (now 1E.2 for blog, comments deferred to Phase 2D)

> Native blog, LLM-powered book associations, comment threads with block-filtering.

### Phase 7A — Blog & Comment Tables (database-agent)
**Objective**: Blog and comment tables exist.

Migrations:
1. `create_blog_posts` — `visibility` (`owner | group | platform`); `published_at TIMESTAMPTZ`
2. `create_post_book_associations` — `confidence NUMERIC(4,3)`, `association_type` (`manual | llm_suggested | confirmed`); FK to `books` and `blog_posts`
3. `create_comments` — polymorphic (`commentable_type`, `commentable_id`); `parent_comment_id` for threading; `hidden_at` for moderation

---

### Phase 7B — Blog & Comment Backend (elixir-agent)
**Objective**: Blog CRUD, LLM book-association worker, comment threading with block-filtered CTE.

- `Stacks.Blog` context
  - `create_post/2`, `update_post/2`, `publish_post/1`, `delete_post/1`
  - `get_post/2` — routes through `resolve_visibility/2`
  - Visibility ceiling: post visibility ≤ profile visibility
- `Stacks.Blog.BookAssociations`
  - `associate_manually/3`, `confirm_suggestion/2`, `dismiss_suggestion/2`
- `Stacks.Workers.PostBookAssociationWorker` — Oban worker triggered on `blog.post_published`; calls vision service `/associate`; stores suggestions with confidence; fires `blog.associations_suggested` event
- `Stacks.Comments` context
  - `create_comment/3`, `delete_comment/1`, `hide_comment/1` (moderation)
  - `get_comment_tree/2` — recursive CTE with block-graph filter; hidden sub-trees collapse (not shown with `[hidden]`)
- vision service `POST /associate` endpoint — accept post text, return `[{isbn, confidence}]` (deferred from Phase 1D)
- **`Stacks.Books.BookDetailCache`** — ETS-backed GenServer caching the assembled `get_book_detail/1` response per `(user_id, book_id)`. On cache miss the full join runs and populates the cache. Subscribe to the following events for invalidation:
  - `blog.post_published` / `blog.associations_updated` → invalidate `(user_id, book_id)` for all books associated with the post
  - `placement.updated` → invalidate `(user_id, book_id)`
  - `price_snapshot.created` → invalidate all entries for `book_id`

  See `docs/technical-architecture.md` — "Book Detail Read Path & Caching" for the full rationale (ETS over PostgreSQL materialised view).

**Events emitted:**
- `blog.post_published`, `blog.associations_suggested`
- `comment.created`, `comment.hidden`

**dbt models:**
- `stg_blog_posts`, `stg_post_book_associations`, `stg_comments`
- `int_blog_engagement`, `int_comment_threads`
- `mart_blog_activity`

**DoD:**
- [ ] Blog post CRUD with visibility ceiling enforcement
- [ ] `PostBookAssociationWorker` fires after publish; suggestions appear for owner review
- [ ] Manual book tagging on posts
- [ ] Comment tree with block-filtered sub-tree collapse
- [ ] Comment moderation: hide hides full sub-tree
- [ ] Python `/associate` endpoint returns ISBN + confidence list
- [ ] `BookDetailCache` GenServer starts under supervision; `get_book_detail/1` routes through it
- [ ] Cache invalidation fires correctly for all four event types above
- [ ] Cache survives a GenServer crash (supervisor restarts with empty cache; first miss repopulates)

---

### Phase 7C — Blog & Comment Frontend (elm-agent)
**Objective**: Blog editor, post detail with book associations, comment threads.

- `Page.Blog.New`, `Page.Blog.Edit` — rich text editor (markdown), visibility selector, publish action
- `Page.Blog.Post` — post detail with associated books sidebar, comment thread
- `Components.BookAssociations` — owner sees suggestions with confirm/dismiss; readers see confirmed associations
- `Components.CommentThread` — threaded display with reply, collapse, report actions
- `Components.CommentComposer`

**DoD:**
- [ ] Blog post can be written, saved as draft, published
- [ ] LLM suggestions appear after publish and can be confirmed/dismissed
- [ ] Comment thread renders with correct nesting
- [ ] Blocked users' comment sub-trees collapse silently

---

## Cross-cutting: Security Hardening (woven into every sub-phase)

Security is not a separate phase — it's woven into every sub-phase. The security-agent reviews each sub-phase's PR before merge.

| Sub-Phase | Security work |
|-----------|--------------|
| 1B.1 | Guardian auth, Argon2 passwords, HMAC service-to-service, security headers plug, rate limiting, CSP, image upload validation, EXIF stripping, Protobuf schema validation for event envelope |
| 1B.3 | `resolve_visibility/2` gate on ALL content endpoints (built in, not retrofitted), block graph prevents information leakage, `ViewAsPlug` owner-only guard, RLS policies, `noindex`/`nofollow` meta, `robots.txt` disallow for auth-walled routes |
| 1C.1 | Rust scraper: HMAC auth, robots.txt compliance, per-domain rate limiting |
| 1C.2 | Circuit breakers (Fuse) on all external calls, AI budget controls, LLM output validation, source exclusion list |
| 1E.1 | KYC webhook verification, Stitch Money payment security, marketplace listing visibility exception audit |
| 1E.2 | LLM output validation (never trust `/associate` without ISBN verification), blog content CSP |
| 1E.3 | Email: verify sender domain, rate-limit email sends, no PII in email subject lines |
| 1G | Fly.io private networking, secrets management, CI security scanning (sobelow, mix_audit, cargo audit, pip audit), `REQUIRE_KYC=true` for production |

---

## Cross-cutting: Testing Enhancements (woven into sub-phases)

Testing infrastructure grows alongside features. The testing standards (`docs/agents/standards/testing.md`) define when each type of test is required.

| Enhancement | When | What |
|-------------|------|------|
| **Property-based tests (StreamData)** | 1B.3 (visibility) | `resolve_visibility/2` has a large combinatorial input space. Generate random `(resource, viewer)` pairs and assert invariants. Extend to ISBN validation, price parsing, and any function with a large input domain. |
| **Accessibility testing (axe-core)** | 1F Wave 1 | Add `@axe-core/playwright` alongside Playwright E2E tests. Every E2E run checks WCAG compliance. |
| **Migration rollback testing** | 1A | `mix ecto.rollback --all && mix ecto.migrate` in CI. Proves every migration is reversible. |
| **API fuzz testing (Schemathesis)** | 1B.1 (after Protobuf) | Auto-generate adversarial payloads from proto-generated JSON schemas. Catches input validation gaps. |
| **Mutation testing** | Post-Phase 1 | Muzak (Elixir) and cargo-mutants (Rust). Periodic audit, not CI gate. |
| **RSS/Atom feed validation** | 1E.3 | Integration test: parse as valid Atom, entries have required fields. |
| **dbt data quality** | 1A onwards | `dbt-assertions` package for row-level assertions on staging models. Expand with each new mart. |

---

## Quick Reference: Agent Assignments

| Sub-Phase | Primary Agent(s) | Review Agent |
|-----------|-----------------|--------------|
| Scaffolding | platform-agent | -- |
| 1A (DB) | database-agent | principle-engineer-agent |
| 1B.1 (Foundation + Event Bus + Proto) | elixir-agent + protobuf-agent | security-agent + principle-engineer-agent |
| 1B.2 (Core Book Management) | elixir-agent | security-agent |
| 1B.3 (Visibility + RLS) | elixir-agent | security-agent + principle-engineer-agent |
| 1C.1 (Rust Scraper) | rust-agent | security-agent |
| 1C.2 (Enrichment) | elixir-agent | testing-coordinator |
| 1D (Vision Sidecar) | python-agent | security-agent |
| 1E.1 (Marketplace) | elixir-agent | security-agent + principle-engineer-agent |
| 1E.2 (Blog) | elixir-agent + python-agent | security-agent |
| 1E.3 (RSS + Metrics + Email) | elixir-agent | -- |
| 1F Waves 1-4 (Elm) | elm-agent | elixir-agent (API contract) |
| 1G (Platform + Deploy) | platform-agent | principle-engineer-agent |
| Phase 2A (Third Spaces) | elixir-agent + elm-agent | -- |
| Phase 2B (Partners) | partner-agent + elixir-agent | security-agent |
| Phase 2C (Groups) | elixir-agent + elm-agent | -- |
| Phase 2D (Comments) | elixir-agent + elm-agent | security-agent |
| Phase 2E (Marketplace Enhancements) | elixir-agent | security-agent |

---

## Progress Notes Format

All agents updating this file during implementation must use:

```
## Progress Notes
[YYYY-MM-DD HH:MM] - [Agent Name] - [Action taken]
- Completed: [what was done]
- In Progress: [what's being worked on]
- Issue: [problem and resolution]
- Note: [important information]
```

---

## Progress Notes

[2026-03-06] - Claude Code - Design review + roadmap update
- Completed: Phase 1A DB foundation (19 migrations, dbt staging layer + seeds, custom generate_schema_name macro, CI workflow)
- Completed: Justfile audit and fixes (search_path persistence, rollback check, test-dbt recipe)
- Completed: User story authoring — sections 10 (Visibility & Privacy), 11 (Social Graph), 12 (Blog), 13 (Comments)
- Completed: technical-architecture.md updated to v1.1 — new tables, ER diagram, Sections 25/27/28
- Completed: implementation-mapping.md updated — phases table, service matrix, dbt model inventory
- Completed: consolidated-roadmap.md updated — Phases 6 & 7 added, Phase 5 updated to Depop/Vinted model, my_writing_links deprecated
- Note: my_writing_links table not created in Phase 1A (superseded by blog_posts); website_url on users covers external-link use case
- Note: /associate Python endpoint deferred from Phase 1D to Phase 7B
- In Progress: Phase 1B–1E implementation not yet started

[2026-03-17] - Claude Code - User story gap analysis + cross-document sync
- Completed: User stories gap analysis — identified 17 gaps, filled with 12 new stories + 15 amended stories
- Completed: Works/editions data model decision — `books` = work, `book_editions` = edition (ISBN, format)
- Completed: technical-architecture.md updated to v1.5 — works/editions schema, new Oban queues, new Elm types, new API endpoints, community wear mart
- Completed: implementation-mapping.md updated — 15 new story mappings, 8 amended stories, all quick reference tables updated
- Completed: consolidated-roadmap.md updated — works/editions in Phase 1A, two-step upload in 1B, overlay+settings+accessibility in 1C, geographic sweep+opt-out in 2B, post-sale in Phase 5, group feed in Phase 6
- Key decisions: book detail is overlay (not route), upload defaults to WishList, Looking for a Home has community-driven wear, closed bid deferred, email notifications quiet by default, list view toggle for accessibility

[2026-03-17] - Claude Code - Phase 1 scope expansion + roadmap restructure
- Completed: Expanded Phase 1 to include ALL features except Third Spaces, partners, groups, comments
- Completed: Principal engineer review of sub-phase ordering — event bus moved to 1B.1, visibility to 1B.3, Protobuf early
- Completed: Roadmap restructured — old Phases 2-7 absorbed into Phase 1 sub-phases; remaining deferred to Phase 2
- Key decisions: KYC config flag (REQUIRE_KYC), RLS designed now, Protobuf as contract from day one, marketplace listings punch through profile ceiling, email infrastructure explicitly scoped, property-based tests for visibility, dbt data engineering tracks per sub-phase
- Deferred to Phase 2: Third Spaces (2A), Partner Integration (2B), Groups (2C), Comments/Q&A (2D), Marketplace Enhancements (2E)
