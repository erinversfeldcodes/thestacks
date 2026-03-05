# Plan: The Stacks — Consolidated Implementation Roadmap
**Created**: 2026-03-05
**Status**: Draft
**Branch**: `main` (greenfield — no existing code)

---

## Context

The Stacks is a greenfield, open-source, self-hosted book management and discovery platform. This plan sequences every deliverable from empty repository to feature-complete across 5 phases, with cross-cutting infrastructure woven in. The build sequence derives from the ordered dependency graph in `docs/implementation-mapping.md` (items 1–49).

**Target user**: A single book-obsessive who wants a beautiful, private, self-hosted library that enriches their reading life with price tracking, review aggregation, author intelligence, local bookshop discovery, and community reading spaces. NOT a social network. NOT a corporate tool.

**Aesthetic**: Dark-academic-meets-cottage-core. Walnut shelves, botanical prints, parchment textures, hand-lettered flyers, cork boards.

---

## Architecture Decisions (see `docs/technical-architecture.md`)

- **Core**: Elixir + Phoenix (OTP supervision, Oban job processing, Guardian JWT)
- **Frontend**: Elm SPA (zero runtime exceptions, TEA architecture, RemoteData pattern)
- **Vision sidecar**: Python + FastAPI (hosted open-source models via Together AI / Replicate)
- **Price scraper**: Rust microservice (TOML config per store, standalone OSS tool)
- **Database**: PostgreSQL with 3 schemas (`op`, `wh`, `audit`), 3 DB roles
- **Data transforms**: dbt (staging -> intermediate -> marts)
- **Event bus**: Oban-backed EDA with `event_log` table (no Kafka, no RabbitMQ)
- **Schema contracts**: Protobuf + buf (JSON on wire, `.proto` as source of truth)
- **Infrastructure**: Fly.io (JHB region), Nix/Flox dev environment, Docker for deploys
- **Partner integration**: One-directional (partner -> platform), API key auth (Argon2), Protobuf-validated payloads

---

## Model Selection Guide

The orchestrator runs on **Sonnet 4.6** throughout. Subagents use the model indicated below.

| Phase(s) | Model | Rationale |
|----------|-------|-----------|
| Phase 1A (DB + migrations) | **Sonnet 4.6** | Well-specified schema from docs; mechanical translation |
| Phase 1B (Elixir contexts) | **Opus 4.6** | Architectural judgment — context boundaries, Ecto.Multi patterns, event emission design |
| Phase 1C (Elm frontend) | **Sonnet 4.6** | TEA patterns are mechanical once types are defined |
| Phase 1D (Python sidecar) | **Sonnet 4.6** | Small, well-specified FastAPI service |
| Phase 1E (Platform + CI) | **Sonnet 4.6** | Config files, Dockerfiles, GitHub Actions — pattern-following |
| Phase 2 (Enrichment) | **Opus 4.6** | External API integration, scraper architecture, LLM guardrails — judgment required |
| Phase 3 (Partner + EDA) | **Opus 4.6** | Event bus design, Protobuf schema authoring, partner auth — security-critical |
| Phase 4 (Polish) | **Sonnet 4.6** | Third Spaces, RSS feeds, metrics — well-specified features |
| Phase 5 (Marketplace) | **Opus 4.6** | Payment integration, KYC, state machines — high stakes |

---

## Pre-Flight: Credential & Account Provisioning (human task)

Agents cannot create accounts. This must be done by a human before Phase 1E (first deployment). Code work in 1A–1D can proceed immediately without credentials.

| Service | Required for | What to provision |
|---------|-------------|-------------------|
| Fly.io | Phase 1E deploy | Organisation created; 3 apps (`thestacks-core`, `thestacks-vision`, `thestacks-scraper`); `FLY_API_TOKEN` in GitHub secrets |
| Fly Postgres | Phase 1E DB | Postgres cluster in JHB; connection string; 3 DB roles (`stacks_app`, `stacks_dbt`, `stacks_readonly`) |
| Tigris / S3-compatible (Fly) | Phase 1E image storage | Bucket created; access keys; `TIGRIS_ACCESS_KEY_ID`, `TIGRIS_SECRET_ACCESS_KEY`, `TIGRIS_BUCKET_NAME` in `.env` |
| Together AI | Phase 1B vision calls | API key; `TOGETHER_AI_API_KEY` in `.env` |
| Brave Search | Phase 2 discovery | API key; `BRAVE_SEARCH_API_KEY` in `.env` |
| Resend or Postmark | Phase 3 partner notifications | API key; `EMAIL_API_KEY` in `.env` |
| Domain + DNS | Phase 1E | Domain pointed to Fly.io; TLS via Fly |

**Optional (later phases):**

| Service | Required for | What to provision |
|---------|-------------|-------------------|
| Smile Identity / Yoti / Sumsub | Phase 1 (late) age verification | API key; `KYC_API_KEY` |
| Stitch Money | Phase 5 marketplace payments | API key; `STITCH_API_KEY`, webhook secret |
| Pargo | Phase 5 marketplace shipping | API key; `PARGO_API_KEY` |

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
    fly.vision.toml
    fly.scraper.toml
    Dockerfile.core
    Dockerfile.vision
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
11. `deploy/Dockerfile.core` (multi-stage Elixir release), `deploy/Dockerfile.vision`, `deploy/Dockerfile.scraper`

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

## GROUP 1: MVP (Phase 1)

> The core loop: upload a photo, identify a book, place it on a shelf, browse and manage. Everything a single user needs to start using The Stacks.

### Phase 1A — Database Foundation (database-agent)
**Objective**: All operational tables, indexes, and DB roles exist. Migrations pass. dbt can connect.
**Starts after**: Repository scaffolding committed.

**Migrations to create** (in order):

1. `create_users` — `op.users` table per schema spec
2. `create_books` — `op.books` with ISBN unique index, GIN index on title tsvector
3. `create_authors` — `op.authors`
4. `create_shelves` — `op.shelves` with enum type for shelf names
5. `create_shelf_placements` — `op.shelf_placements` with unique constraint `(book_id, shelf_id, removed_at)`
6. `create_shelf_placement_history` — `op.shelf_placement_history`
7. `create_uploaded_images` — `op.uploaded_images`
8. `create_my_writing_links` — `op.my_writing_links`
9. `create_audit_log` — `op.audit_log` (append-only, partitioned by month)
10. `create_discovered_sources` — `op.discovered_sources`
11. `create_review_snapshots` — `op.review_snapshots`
12. `create_price_snapshots` — `op.price_snapshots`
13. `create_bookstores` — `op.bookstores`
14. `create_bookstore_events` — `op.bookstore_events`
15. `create_third_spaces` — `op.third_spaces`
16. `create_third_space_events` — `op.third_space_events`
17. `create_event_log` — `op.event_log` with index on `(event_type, aggregate_id, occurred_at DESC)`
18. `create_oban_tables` — Oban migration (`Oban.Migration`)
19. `create_db_roles` — SQL migration for `stacks_app`, `stacks_dbt`, `stacks_readonly` roles with appropriate grants

**dbt setup:**
- `profiles.yml` pointing to `stacks_dbt` role
- Staging models: `stg_books`, `stg_authors`, `stg_shelves`, `stg_shelf_placements`, `stg_shelf_placement_history`, `stg_uploaded_images`, `stg_audit_log`
- Empty intermediate and mart directories with `.gitkeep`

**Files created:**
- `apps/core/priv/repo/migrations/` — 19 migration files
- `dbt/models/staging/` — 7 staging model SQL files
- `dbt/profiles.yml`, `dbt/dbt_project.yml`

**Test command**: `mix ecto.create && mix ecto.migrate && mix test`
**DoD:**
- [ ] All 19 migrations run without error
- [ ] `mix ecto.rollback --all` succeeds (migrations are reversible)
- [ ] DB roles exist with correct grants
- [ ] `dbt run --select staging` succeeds
- [ ] GIN index exists on `books.title`
- [ ] `audit_log` has INSERT-only grant for `stacks_app`
- [ ] `event_log` index exists on `(event_type, aggregate_id, occurred_at DESC)`

---

### Phase 1B — Elixir Core Contexts (elixir-agent)
**Objective**: All Phoenix contexts, controllers, and Oban workers for MVP stories exist and pass tests. No frontend yet — API-only.
**Starts after**: Phase 1A committed.
**Parallel with**: Phase 1C (Elm) and Phase 1D (Python sidecar) can start once context interfaces are defined (after day 1 of 1B).

#### 1B.1 — Foundation Contexts

**`Stacks.Accounts`** — user registration, authentication, Guardian pipeline
- `Stacks.Accounts.register/1`, `authenticate/2`, `get_user/1`
- Guardian serializer, auth pipeline plug, error handler
- `StacksWeb.AuthController` — `login/2`, `logout/2`, `register/2`
- Owner bootstrap: first user to register becomes owner

**`Stacks.Audit`** — append-only audit logging
- `Stacks.Audit.log/3` (action, actor, metadata)
- IP hashing via `:crypto.hash(:sha256, ip)`
- Metadata encryption via Cloak
- No UPDATE/DELETE in context — INSERT only

**`Stacks.GDPR.Consent`** — consent management
- `grant_consent/2`, `revoke_consent/2`, `check_consent/2`
- `StacksWeb.Plugs.ConsentCheck`

**Files:**
- `apps/core/lib/core/accounts.ex`, `accounts/user.ex`
- `apps/core/lib/core/audit.ex`, `audit/log_entry.ex`
- `apps/core/lib/core/gdpr/consent.ex`
- `apps/core/lib/core_web/plugs/` — `auth_pipeline.ex`, `consent_check.ex`, `rate_limiter.ex`, `security_headers.ex`
- `apps/core/lib/core_web/controllers/auth_controller.ex`

#### 1B.2 — Book Management Contexts

**`Stacks.Books`** — the core domain
- `Books.upload_and_identify/2` — orchestrates vision call + ISBN resolution
- `Books.create/1`, `Books.create_from_isbn/1` (US-1.1.5 manual entry)
- `Books.find_existing/1` (US-1.1.6 duplicate detection)
- `Books.get_book_detail/1` — aggregates book + author + reviews + prices + writing links
- `Books.search_books/2` — full-text search with `pg_trgm`, dynamic sort/filter
- `Books.update_placement_formats/2`
- `Books.ISBNResolver` — Open Library primary, Google Books fallback
- `StacksWeb.BookController`, `StacksWeb.UploadController`, `StacksWeb.SearchController`

**`Stacks.Shelving`** — shelf operations
- `Shelving.get_shelf_books/2`, `Shelving.move_book/3`, `Shelving.abandon_book/2`, `Shelving.reread_book/1`
- `Shelving.remove_book/1` (US-1.6.4 — soft delete via `removed_at`)
- `Shelving.spine_data/1` — computes wear level from history
- `StacksWeb.ShelfController`, `StacksWeb.ShelfPlacementController`

**`Stacks.Moderation`** — content moderation pipeline
- `Moderation.Pipeline` — classify_image -> resolve_isbn -> classify_subject -> store_with_tier
- `Moderation.classify_subject/1` using BISAC lookup
- `StacksWeb.Plugs.AgeGate`

**Oban workers (MVP):**
- `Stacks.Workers.IdentifyBookJob` — vision call + ISBN resolution + moderation pipeline
- `Stacks.Workers.EnrichBookJob` — fetch metadata from Open Library / Google Books
- `Stacks.Workers.RecalculateWearJob` — wear level recalculation on shelf moves
- `Stacks.Workers.ImageRetentionJob` — daily cleanup of images older than 30 days

**`Stacks.AI.BudgetTracker`** — GenServer for per-provider daily/monthly caps
**`Stacks.AI.Client`** — HTTP client with Fuse circuit breaker wrapping Together AI / Replicate calls

**Files:**
- `apps/core/lib/core/books.ex`, `books/book.ex`, `books/isbn_resolver.ex`
- `apps/core/lib/core/shelving.ex`, `shelving/shelf.ex`, `shelving/shelf_placement.ex`, `shelving/shelf_placement_history.ex`
- `apps/core/lib/core/moderation.ex`, `moderation/pipeline.ex`
- `apps/core/lib/core/ai/budget_tracker.ex`, `ai/client.ex`
- `apps/core/lib/core/workers/` — 4 worker files
- `apps/core/lib/core_web/controllers/` — `book_controller.ex`, `upload_controller.ex`, `search_controller.ex`, `shelf_controller.ex`, `shelf_placement_controller.ex`
- `apps/core/lib/core_web/router.ex`

#### 1B.3 — GDPR Contexts

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

**Test command**: `mix test`
**DoD:**
- [ ] All contexts have at least one happy-path and one error-path test
- [ ] `mix compile --warnings-as-errors` passes
- [ ] `mix credo --strict` passes
- [ ] `mix sobelow --config` passes (no high-severity findings)
- [ ] Guardian auth pipeline works: register -> login -> access protected route -> logout
- [ ] Upload flow works end-to-end via API: upload image -> identify book -> place on shelf (with mocked vision sidecar)
- [ ] Shelf operations: move, abandon, re-read, remove all write correct history records
- [ ] Search returns results with full-text matching
- [ ] Audit log captures all significant actions
- [ ] GDPR export produces valid JSON with all user data
- [ ] Image retention job deletes files older than 30 days
- [ ] Budget tracker rejects calls when daily limit exceeded

---

### Phase 1C — Elm Frontend (elm-agent)
**Objective**: All MVP pages render and interact with the Phoenix API. Shelf views, book detail, upload, search, navigation, empty states.
**Starts after**: Phase 1B context interfaces defined (can mock API responses initially).

#### Pages

**`Page.Upload`** — drag-and-drop / camera capture, upload progress, result confirmation
- `UploadMsg`, `UploadModel`, `PhotoFile` types
- `IdentificationFailed` variant (US-1.1.2 ISBN Hard Gate)
- `NotABook` variant (US-1.1.3 Non-Book Rejection)
- `ManualISBNEntry` variant (US-1.1.5) with client-side ISBN checksum validation
- `DuplicateDetected` variant (US-1.1.6) with view/move/close actions

**`Page.Shelf.Library`** — dark walnut, green damask (`ShelfTheme { wood: DarkWalnut, backdrop: GreenDamask }`)
**`Page.Shelf.AntiLibrary`** — light oak, botanical prints
**`Page.Shelf.WishList`** — blue-grey, watercolour florals
**`Page.Shelf.ReadingPile`** — vertical stack, armchair background (`PileView`)

**`Page.BookDetail`** — cover image, metadata, review summary (stub), price info (stub), author card, writing links, shelf mover, format picker, remove action

**`Page.Search`** — debounced search bar, filter panel, sort selector

**`Page.Settings.Consent`** — toggle switches per consent category
**`Page.Settings.AgeVerification`** — self-declaration toggle

#### Shared Components

- `Components.Spine` — thickness from page_count, wear level (Pristine|Softened|Cracking|WellRead|WellLoved), bookmark icon, green dot for partner availability (Phase 3 stub)
- `Components.EmptyShelf` — per-shelf themed empty state with CTA (US-1.6.5)
- `Components.ShelfMover` — dropdown of target shelves
- `Components.AbandonModal` — optional note textarea
- `Components.RemoveBookModal` — confirmation with warning
- `Components.FormatPicker` — multi-select checkboxes
- `Components.AgeGate` — interstitial overlay
- `Components.ISBNInput` — ISBN-10/13 checksum validation
- `Components.DuplicateDetected` — existing book with actions
- `Components.SearchBar`, `Components.FilterPanel`, `Components.SortSelector`
- `Components.ConsentBanner` — first-visit consent collection

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
- `frontend/src/Page/` — `Upload.elm`, `Shelf/Library.elm`, `Shelf/AntiLibrary.elm`, `Shelf/WishList.elm`, `Shelf/ReadingPile.elm`, `BookDetail.elm`, `Search.elm`, `Settings/Consent.elm`, `Settings/AgeVerification.elm`
- `frontend/src/Components/` — `Spine.elm`, `EmptyShelf.elm`, `ShelfMover.elm`, `AbandonModal.elm`, `RemoveBookModal.elm`, `FormatPicker.elm`, `AgeGate.elm`, `ISBNInput.elm`, `DuplicateDetected.elm`, `SearchBar.elm`, `FilterPanel.elm`, `SortSelector.elm`, `ConsentBanner.elm`
- `frontend/src/Navigation/ShelfRouter.elm`
- `frontend/src/Animation/` — `SlideTransition.elm`, `RoomTransition.elm`
- `frontend/src/Api.elm` — HTTP client module
- `frontend/src/Types/` — `Book.elm`, `Shelf.elm`, `User.elm`, `RemoteData.elm`
- `frontend/tests/`

**Test command**: `elm-test`
**DoD:**
- [ ] `elm make src/Main.elm --optimize` succeeds with zero warnings
- [ ] `elm-format --validate src/` passes
- [ ] All 5 shelf views render with correct themes
- [ ] Empty shelf states display per-shelf messages (US-1.6.5)
- [ ] Upload flow: select photo -> progress -> result (or error variants)
- [ ] Manual ISBN entry with client-side checksum validation
- [ ] Duplicate detection shows existing book with actions
- [ ] Book detail page renders all sections
- [ ] Shelf navigation with slide/room transitions
- [ ] Search with debounced input and filter/sort
- [ ] Remove book modal with confirmation
- [ ] All API calls use RemoteData pattern

---

### Phase 1D — Python Vision Sidecar (python-agent)
**Objective**: FastAPI service with `/extract`, `/classify`, `/health` endpoints. Deployed as separate Fly machine.
**Starts after**: Repository scaffolding.

**Endpoints:**

| Method | Path | Purpose |
|--------|------|---------|
| `POST` | `/extract` | Send image, receive extracted text (title, author, potential ISBN) |
| `POST` | `/classify` | Send image, receive classification (book / not_book / ambiguous) |
| `GET` | `/health` | Health check |

**Files:**
- `apps/vision/app/main.py` — FastAPI app with 3 endpoints
- `apps/vision/app/models/extraction.py` — Pydantic models for request/response
- `apps/vision/app/models/classification.py`
- `apps/vision/app/services/vision_client.py` — Together AI / Replicate HTTP client
- `apps/vision/app/services/hmac_auth.py` — HMAC token validation for internal requests
- `apps/vision/app/config.py` — model version pinning, budget defaults
- `apps/vision/tests/` — pytest test files
- `apps/vision/requirements.txt`
- `apps/vision/Dockerfile`

**Key constraints:**
- Never trust model output — always return raw extraction, let Phoenix validate
- Model version pinned in config (`Qwen/Qwen2.5-VL-7B-Instruct`)
- Budget tracking delegated to Phoenix (sidecar just makes calls)
- HMAC auth on all endpoints — reject requests without valid `X-Internal-Token`

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

### Phase 1E — Platform & Deployment (platform-agent)
**Objective**: First successful Fly.io deployment. CI pipeline green. Dev environment reproducible.
**Starts after**: Phases 1A–1D committed.

#### 1E.1 — Fly.io Configuration

**Files:**
- `deploy/fly.core.toml` — Phoenix app, JHB region, 256MB RAM, health check at `/health`
- `deploy/fly.vision.toml` — Python sidecar, JHB, 512MB RAM (model inference), private networking only
- `deploy/fly.scraper.toml` — Rust scraper, JHB, 256MB, private networking only
- `deploy/Dockerfile.core` — multi-stage Elixir release (build with 1.18+, OTP 27; run on Alpine)
- `deploy/Dockerfile.vision` — Python 3.12 slim
- `deploy/Dockerfile.scraper` — Rust multi-stage (builder + Alpine runtime)

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

**Test command**: `just test && just lint`
**DoD:**
- [ ] `fly deploy -c deploy/fly.core.toml` succeeds
- [ ] `fly deploy -c deploy/fly.vision.toml` succeeds (private networking)
- [ ] `fly deploy -c deploy/fly.scraper.toml` succeeds (private networking)
- [ ] Phoenix app responds at public URL
- [ ] Vision sidecar reachable from Phoenix via `*.internal` DNS
- [ ] CI pipeline passes on push to `main`
- [ ] `nix develop` drops into working shell on clean machine
- [ ] All `justfile` recipes work

#### Phase 1 Integration Test
After all tracks merge:
- [ ] Register owner account via API
- [ ] Upload a book photo -> vision sidecar identifies it -> ISBN resolved -> book on shelf
- [ ] Browse all 5 shelf views (4 show empty states, 1 shows the book)
- [ ] Click spine -> book detail page renders
- [ ] Move book between shelves -> history recorded
- [ ] Search finds the book
- [ ] Full CI pipeline green on `main`

---

## GROUP 2: Enrichment (Phase 2)

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
- `Stacks.Admin.ScraperConfig` — CRUD for bookstore scraper configs

**Oban workers:**
- `FetchReviewsJob` (adaptive staleness)
- `TriggerPriceScrapeJob` (daily)
- `DiscoverAuthorSourcesJob` (weekly)
- `FetchAuthorRSSJob` (hourly)
- `DiscoverBookstoreEventsJob` (daily)
- `SourceDiscoveryJob` (daily)
- `ScoreSourceJob` (on-demand, LLM scoring)

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
- [ ] All enrichment data surfaces on book detail page API response
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

## GROUP 3: Partner Integration & EDA (Phase 3)

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

## GROUP 4: Polish (Phase 4)

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

## GROUP 5: Marketplace (Phase 5, Future)

> Listings, payments, shipping. Deferred until the core platform is stable.

### Phase 5A — Marketplace Tables (database-agent)
**Objective**: `listings`, `offers`, `transactions` tables exist.

Migrations:
1. `create_listings` — state machine: draft -> active -> sold -> removed -> expired
2. `create_offers` — status: pending -> accepted -> declined -> withdrawn -> expired
3. `create_transactions` — payment_status, shipping_status

---

### Phase 5B — Marketplace Backend (elixir-agent)
**Objective**: Listing, offer, and transaction flows with Stitch Money and Pargo integration.

- `Stacks.Marketplace` context — `create_listing/1`, listing state machine
- `Stacks.Marketplace.Transactions` — `create_offer/1`, `accept_offer/1`, `initiate_payment/1`, `create_shipment/1`
- `Stacks.Marketplace.SellerVerification` — extends `Stacks.Accounts.Verification`
- Oban workers: `ListingExpiryJob`, `PaymentCallbackJob`, `ShipmentTrackingJob`
- Webhook handlers for Stitch and Pargo callbacks

---

### Phase 5C — Marketplace Frontend (elm-agent)
**Objective**: Listing creation, browsing, purchase flow, seller onboarding.

- `Page.Marketplace.CreateListing`, `Browse`, `Checkout`, `SellerOnboarding`
- `Components.ConditionGrader`, `Components.OfferModal`

#### Phase 5 Integration Test
- [ ] Seller verification -> list book -> buyer makes offer -> payment -> shipping
- [ ] Listing expires automatically after configured period

---

## Cross-cutting: Security Hardening (incremental across all phases)

Security is not a separate phase — it's woven into every phase. The security-agent reviews each phase's PR before merge.

| Phase | Security work |
|-------|--------------|
| Phase 1B | Guardian auth, Argon2 passwords, HMAC service-to-service, security headers plug, rate limiting, CSP, image upload validation, EXIF stripping |
| Phase 1E | Fly.io private networking, secrets management, CI security scanning (sobelow, mix_audit, cargo audit, pip audit) |
| Phase 2B | Circuit breakers (Fuse) on all external calls, AI budget controls, LLM output validation |
| Phase 3C | Partner API key auth (Argon2 hash), partner rate limiting (separate tier), Protobuf schema validation, text blocklist |
| Phase 5B | PCI considerations for payment flow, KYC webhook verification |

---

## Quick Reference: Agent Assignments

| Phase | Primary Agent(s) | Review Agent |
|-------|-----------------|--------------|
| Scaffolding | platform-agent | -- |
| 1A | database-agent | principle-engineer-agent |
| 1B | elixir-agent | security-agent |
| 1C | elm-agent | elixir-agent (API contract) |
| 1D | python-agent | security-agent |
| 1E | platform-agent | principle-engineer-agent |
| 2A | rust-agent | security-agent |
| 2B | elixir-agent | testing-coordinator |
| 2C | elm-agent | elixir-agent |
| 3A | protobuf-agent | principle-engineer-agent |
| 3B | elixir-agent | principle-engineer-agent |
| 3C | partner-agent + elixir-agent | security-agent |
| 3D | elm-agent | partner-agent |
| 4A | elixir-agent + elm-agent | testing-coordinator |
| 4B | elixir-agent | -- |
| 4C | elixir-agent + elm-agent | -- |
| 5A | database-agent | principle-engineer-agent |
| 5B | elixir-agent | security-agent |
| 5C | elm-agent | elixir-agent |

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

(Updated by agents during execution.)
