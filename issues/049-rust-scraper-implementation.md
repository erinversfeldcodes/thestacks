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
