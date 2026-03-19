# Plan: Issue #049 — Rust Scraper Implementation
**Issue**: #049
**Created**: 2026-03-19
**Status**: Complete (with open follow-up items)

## Context

Issue #049 delivered the Rust bookshop price scraper from scratch. The scraper is an internal service that fetches current prices from South African bookshops given an ISBN, using TOML-driven configuration, rate limiting, robots.txt compliance, and HMAC authentication. It feeds Issue #050 (Broadway enrichment pipelines in Elixir).

## What Was Delivered

### Modules Implemented (`apps/scraper/src/`)

| Module | Status | Notes |
|--------|--------|-------|
| `main.rs` | Partial | Axum server wired; `/health` only — `/scrape` and `/config/reload` NOT wired |
| `config.rs` | Complete | TOML deserialization, validation at startup, CSS selector validation |
| `scraper.rs` | Complete | Mock/real HTTP engine, rate limiting, robots.txt integration |
| `stores/mod.rs` | Complete | StoreRegistry with recursive TOML loading, hot-reload-ready |
| `rate_limiter.rs` | Complete | Sliding-window per-domain limiter using DashMap |
| `robots.rs` | Complete | Inline parser, domain cache, lenient-by-default on unavailability |
| `auth.rs` | Complete | HMAC-SHA256 verify_token/generate_token, constant-time comparison |
| `price.rs` | Complete | ZAR price parsing (R, ZAR prefix), currency mismatch detection |
| `error.rs` | Complete | thiserror enum covering all error variants |
| `lib.rs` | Complete | Module re-exports |

### Test Results
- `cargo test`: 43 passed, 0 failed
- `cargo clippy -- -D warnings`: clean
- `cargo fmt --check`: clean

### Gaps Identified by Reviewer

**Blockers (must be resolved before Issue #050 integration):**

1. **`/scrape` endpoint missing from `main.rs`** — The Axum server only exposes `/health`. The `POST /scrape` and `POST /config/reload` endpoints defined in the Technical Requirements are not wired up. The auth library exists but is not applied as middleware. The scraper library is functionally complete — only the HTTP layer connecting them is absent.

2. **No TOML store configs on disk** — `scrapers/za/exclusive_books.toml` and `scrapers/za/takealot.toml` are required by the issue but do not exist. The StoreRegistry can load them, but there is nothing to load. The DoD item "TOML config drives scraper behaviour" is partially satisfied (the library works; the actual config files are not committed).

3. **No HTTP request timeout on `reqwest::Client`** — The client is built without `timeout()`. An unresponsive bookshop site can hang a thread indefinitely. This is a security requirement.

**Required Revisions (NEEDS_REVISION — do not block further, fix in follow-up):**

4. **No proptest for price parsing or ISBN validation** — The project standards and rust-reviewer both mandate `proptest` for these high-value fuzz targets. Only deterministic unit tests are present.

5. **No `wiremock` (or equivalent) for HTTP isolation** — The real `reqwest::Client` is created in the mock engine. Tests avoid making real requests only because fixtures bypass the client. A future test that exercises the real HTTP path would make live network calls.

6. **`POST /config/reload` not implemented** — Required by Technical Requirements.

### Non-Blocking Observations

- `expect("RwLock poisoned")` and `expect("failed to build mock reqwest client")` in production paths (`stores/mod.rs:69,75,84,90` and `scraper.rs:58,167`). RwLock poisoning is recoverable; these should return errors rather than panic. The mock engine `expect` is acceptable for test paths only.
- `Default` impl for `Engine` calls `expect` (`scraper.rs:167`) — if this is used in production (e.g., `Engine::default()` somewhere), it will panic on client build failure rather than return an error.
- `resp.text().await.unwrap_or_default()` in `robots.rs:45` silently discards text-decode errors — acceptable given the lenient robots.txt semantics.
- No `cargo audit` in CI pipeline — should be added.
- `selector_match_rate` not returned in scrape response (required by Issue #068 downstream).

## Follow-up Issues Required

| Issue | Description | Priority | Agent |
|-------|-------------|----------|-------|
| #049-follow-1 | Wire `/scrape` and `/config/reload` endpoints into Axum server + HMAC middleware | P0 | rust-agent |
| #049-follow-2 | Create `scrapers/za/exclusive_books.toml` and `scrapers/za/takealot.toml` | P0 | rust-agent |
| #049-follow-3 | Add `timeout()` to reqwest::Client builder | P0 | rust-agent |
| #049-follow-4 | Add proptest for price parsing and ISBN validation | P1 | rust-agent |
| #049-follow-5 | Add `selector_match_rate` to PriceResult response (required by Issue #068) | P1 | rust-agent |

## Forward Compatibility Assessment

- **Issue #050** (Broadway enrichment) needs `POST /scrape` to exist and return `[{ isbn, store, price_cents, currency, in_stock, url }]`. The `PriceResult` struct is defined correctly. The endpoint is missing — Issue #050 must mock the scraper until the follow-up is complete.
- **Issue #068** (source health monitoring) needs `selector_match_rate` in the scrape response. Not present — gap recorded.

## Retrospective

**What worked well:** The library layer (config, price parsing, rate limiting, robots.txt, HMAC auth) is high quality, well-tested, and well-structured. The sliding-window rate limiter is correct. The constant-time HMAC comparison prevents timing attacks. CSS selector validation at config parse time is a good design choice.

**What caused friction:** The specialist built an excellent library but did not wire it into the Axum HTTP server. This is the most common class of gap in single-phase implementations: the internals work but the integration layer is absent. The issue's Technical Requirements were clear about the three required endpoints, but they were not implemented.

**What should change:** The rust-agent prompt and rust-reviewer prompt should both add an explicit check: "For every endpoint listed in Technical Requirements, verify it is registered in main.rs's Router." This would catch the gap mechanically.
