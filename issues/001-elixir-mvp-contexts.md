# Issue #001: Implement Elixir Phoenix contexts, API, and Oban workers for MVP

## Summary
Build all Phoenix contexts, controllers, plugs, and Oban workers needed for the MVP core loop: user auth, book identification, shelf management, content moderation, GDPR, and audit logging. API-only — no frontend. This is Phase 1B of the consolidated roadmap.

## User Stories
- US-1.1.x — Book upload, ISBN resolution, manual entry, duplicate detection
- US-1.6.4 — Remove book (soft delete via `removed_at`)
- GDPR right to export, right to erasure

## Goal
A working Phoenix JSON API covering registration, auth, book upload-and-identify (mocked vision sidecar), shelf CRUD, search, audit logging, and GDPR export/deletion. All Oban workers registered and testable. `mix test` passes with happy-path and error-path coverage for every context.

## Technical Requirements

See roadmap: `plans/consolidated-roadmap.md` § Phase 1B.

**1B.1 — Foundation Contexts**
- `Stacks.Accounts` — registration, auth, Guardian pipeline; first user becomes owner
- `Stacks.Audit` — append-only `log/3`; IP hashing via `:crypto`; metadata encrypted via Cloak
- `Stacks.GDPR.Consent` — `grant_consent/2`, `revoke_consent/2`, `check_consent/2`
- Plugs: `AuthPipeline`, `ConsentCheck`, `RateLimiter`, `SecurityHeaders`
- `StacksWeb.AuthController`

**1B.2 — Book Management Contexts**
- `Stacks.Books` — `upload_and_identify/2`, `create/1`, `create_from_isbn/1`, `find_existing/1`, `get_book_detail/1`, `search_books/2`; `ISBNResolver` (Open Library primary, Google Books fallback)
- `Stacks.Shelving` — `get_shelf_books/2`, `move_book/3`, `abandon_book/2`, `reread_book/1`, `remove_book/1`, `spine_data/1`
- `Stacks.Moderation` — classify_image → resolve_isbn → classify_subject → store_with_tier pipeline; BISAC lookup; `AgeGate` plug
- `Stacks.AI.BudgetTracker` GenServer — per-provider daily/monthly caps
- `Stacks.AI.Client` — Finch HTTP client with Fuse circuit breaker
- Oban workers: `IdentifyBookJob`, `EnrichBookJob`, `RecalculateWearJob`, `ImageRetentionJob`
- Controllers: `BookController`, `UploadController`, `SearchController`, `ShelfController`, `ShelfPlacementController`

**1B.3 — GDPR Contexts**
- `Stacks.GDPR.Export` — `export_user_data/2` (JSON, CSV, OPDS)
- `Stacks.GDPR.Deletion` — `delete_user_data/1` with `Ecto.Multi` cascade
- `Stacks.GDPR.ImageRetention` — `cleanup_expired_images/0`
- Oban workers: `DataExportJob`, `AccountDeletionJob`, `ConfirmDeletionJob`
- `StacksWeb.GDPRController`

**Constraints:**
- Vision sidecar must be mockable via `TEST_TARGET` env var — no real Together AI calls in tests
- `mix compile --warnings-as-errors` must pass
- `mix credo --strict` must pass
- `mix sobelow --config` must pass (no high-severity findings)
- Audit log is INSERT-only — no UPDATE/DELETE in context code

## Definition of Done
- [ ] All contexts have at least one happy-path and one error-path test
- [ ] `mix compile --warnings-as-errors` passes
- [ ] `mix credo --strict` passes
- [ ] `mix sobelow --config` passes (no high-severity findings)
- [ ] Guardian auth pipeline: register → login → access protected route → logout
- [ ] Upload flow end-to-end via API with mocked vision sidecar: upload image → identify book → place on shelf
- [ ] Shelf operations: move, abandon, re-read, remove all write correct `bookshelf_placement_history` records
- [ ] Full-text search returns results
- [ ] Audit log captures all significant actions
- [ ] GDPR export produces valid JSON with all user data
- [ ] Image retention Oban job deletes images older than 30 days
- [ ] Budget tracker rejects calls when daily limit exceeded
- [ ] `mix test` passes

## Dependencies
- Issue #000 (implicit): Phase 1A database migrations committed to `main` ✅

## Agent Assignment
- **elixir-agent** (`docs/agents/elixir-agent.md`)
- **Reviewer**: elixir-reviewer (`docs/agents/reviewers/elixir-reviewer.md`)
- **Model**: Opus 4.6 (architectural judgment required — context boundaries, Ecto.Multi, event emission)

## Progress Notes
<!-- Updated by agents during execution -->
