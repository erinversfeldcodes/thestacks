# Issue #049: Rust Scraper Implementation

## Summary
Build the Rust bookshop price scraper from the existing skeleton. TOML-driven configuration per store, rate limiting, robots.txt compliance, HMAC auth on all endpoints.

## User Stories
US-2.2.1 (price tracking), US-2.2.2 (scraper config)

## Goal
Given an ISBN and a set of TOML store configs, the scraper fetches current prices from South African bookshops and returns structured results via its internal HTTP API.

## Technical Requirements

**Crate structure (`apps/scraper/src/`):**
- `main.rs` — Axum HTTP server with endpoints
- `config.rs` — TOML config loader, hot-reload support
- `scraper.rs` — generic scrape engine (reqwest + scraper crate)
- `stores/mod.rs` — store-specific parsers dispatched by config
- `rate_limiter.rs` — per-domain sliding window rate limiter
- `robots.rs` — robots.txt fetcher and compliance checker
- `auth.rs` — HMAC token validation (same scheme as vision service)

**Internal API:**
- `POST /scrape` — accept `{ isbns: [string], stores: [string] | "all" }`, return `[{ isbn, store, price_cents, currency, in_stock, url }]`
- `POST /config/reload` — reload TOML configs from disk
- `GET /health` — health check

**TOML configs (at least 2):**
- `scrapers/za/exclusive_books.toml`
- `scrapers/za/takealot.toml`
- Each config defines: source name, base URL, search URL pattern, CSS selectors for price/title/stock, currency, rate limits

**Constraints:**
- No `unwrap()` in production code — `thiserror`/`anyhow` for error handling
- `cargo clippy --deny warnings` must pass
- Rate limiting enforced per domain (from TOML config `requests_per_minute`)
- Check `robots.txt` before first scrape of any domain; cache result
- HMAC auth: reject requests without valid `X-Internal-Token` header

**Test infrastructure:**
- Fixture HTML files per store in `apps/scraper/tests/fixtures/`
- `MOCK_HTTP=true` env var loads HTML from fixtures instead of making HTTP requests
- Test: TOML parsing, price extraction, rate limiting, HMAC rejection

## Definition of Done
- [ ] Scraper fetches prices from at least 2 SA bookshops given an ISBN (using fixture HTML in tests)
- [ ] TOML config drives scraper behaviour (no hardcoded selectors)
- [ ] Rate limiting enforced per domain
- [ ] `robots.txt` checked before scraping
- [ ] HMAC auth rejects unsigned requests with 401
- [ ] `cargo fmt --check` passes
- [ ] `cargo clippy --deny warnings` passes
- [ ] `cargo test` passes
- [ ] `cargo audit` has no high-severity findings
- [ ] Error handling via `thiserror`/`anyhow` — no `unwrap()` in production code

## Dependencies
None — fully independent service. Can start in parallel with any Elixir task.

## Agent Assignment
rust-agent

## Progress Notes

### 2026-03-19 — Orchestrator post-implementation review complete

**Regression Gate:** PASS — cargo test 43/43, cargo clippy clean, cargo fmt clean.

**Reviewer Verdict: NEEDS_REVISION**

Library layer (config, price, rate_limiter, robots, auth, stores) is high quality and well-tested. Three blocking gaps identified:

1. **`/scrape` and `/config/reload` endpoints not wired into Axum** — `main.rs` exposes `/health` only. The HMAC auth module exists but is not applied as middleware. This is a P0 integration gap.
2. **TOML store configs missing from disk** — `scrapers/za/exclusive_books.toml` and `scrapers/za/takealot.toml` required by the issue do not exist in the repo.
3. **No HTTP request timeout on reqwest::Client** — unresponsive sites can hang threads indefinitely.

Additional non-blocking: no proptest for price parsing (project standard), no `selector_match_rate` in PriceResult (required by Issue #068 downstream).

**PE Gate:** YELLOW — library internals are clean; integration layer is incomplete. Follow-up issues are required before Issue #050 can integrate against a real scraper endpoint.

See `plans/049-rust-scraper-mvp-complete.md` for full detail and follow-up issue list.
