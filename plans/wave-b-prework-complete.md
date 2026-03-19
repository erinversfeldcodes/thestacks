# Phase 3 Completion: Wave B Pre-work

**Completed**: 2026-03-19
**Status**: APPROVED (both Rust and Elixir reviewers, no revisions)
**Elixir tests**: 424 tests, 0 failures (+10 from baseline)
**Rust tests**: 55 tests, 0 failures (+5 from baseline)
**Credo**: Clean. Clippy: Clean. Fmt: Clean.

---

## What Was Built

### Task A — Rust: `selector_match_rate` (#049-follow-5)

**Files:** `apps/scraper/src/scraper.rs`, `apps/scraper/src/main.rs`

- `selector_match_rate: Option<f64>` added to `PriceResult` and `ScrapeResponse`
- Private `selector_matches_any(html, selector_str) -> bool` helper — uses `scraper::Html::parse_document`, handles unparseable selectors gracefully (returns `false`, no panic)
- `parse_result` computes rate: `matched / total` where `price` is always counted, optional selectors (`title`, `in_stock`, `product_url`) counted only when configured
- Result is always `Some` (denominator ≥ 1); range [0.0, 1.0]
- 5 new tests: all-match (1.0), partial (0.5), price-only match (1.0), price-only no-match (0.0), four-defined two-match (0.5)
- `Dockerfile.scraper` also fixed in this session: `scrapers/` dir now copied into image; port corrected from 3000 → 8080

### Task B — Elixir: `AI.Client` additions (deferred #072 work, required by #046)

**Files:** `lib/stacks/ai/client.ex`, `lib/stacks/ai/mock_client.ex`, `test/stacks/ai/client_test.exs`

- Explicit `endpoint_path("associate")` clause before passthrough
- `associate_isbn/4` — POSTs `{isbn, book_id, edition_id, cover_url}` to `/associate`; returns `{:ok, job_id}` or `{:error, {:unexpected_response, _}}` or `{:error, reason}`
- `extract_from_url/1` — reuses `"extract_isbn"` path, passes `%{image_url: url}`; returns `{:ok, result}`
- MockClient: `call_vision("associate", ...)` clause returns `{:ok, %{"job_id" => "mock-job-#{isbn}-#{edition_id}"}}`
- 3 new tests

### Task C — Elixir: `Books.confirm_cover_association/2` + `InternalController` (required by #046)

**Files:** `lib/stacks/books.ex`, `lib/stacks_web/controllers/internal_controller.ex`, router, `test/stacks_web/internal_controller_test.exs`, `test/stacks/books_test.exs`

- `confirm_cover_association(edition_id, cover_url)` — gets edition, updates `cover_image_url` via changeset, emits `book.cover_confirmed` event; returns `{:error, :not_found}` on missing edition
- `InternalController.vision_associate/2` — timestamp-based HMAC (mirrors `AI.Client.auth_token/2` exactly: `"<ts>.POST.<path>"`), ±60s replay window, `Plug.Crypto.secure_compare/2`; always 200 after auth passes; confirmed → `confirm_cover_association/2`; rejected → log + 200
- Route: `/api/internal/vision/associate` — `:api` pipeline only, no auth plug, no rate limiter
- 7 new tests: confirmed (DB updated), rejected (no change), missing HMAC (401), tampered HMAC (401), non-existent edition (200), plus 2 unit tests for `confirm_cover_association/2`

---

## Why This Matters for Wave B

| Unblocked capability | Required by |
|---|---|
| `selector_match_rate` in scrape response | Issue #068 (source health monitoring) |
| `associate_isbn/4` on `AI.Client` | Issue #046 DoD item |
| `extract_from_url/1` on `AI.Client` | Issue #046 DoD item |
| `InternalController` HMAC callback receiver | Issue #046 DoD item |
| `Books.confirm_cover_association/2` | Issue #046 DoD item |

Issue #046 can now proceed without deferring any of these items.
