# The Stacks — Rust Agent

## Role
Develop and maintain the Rust bookshop price scraper microservice: TOML-driven per-store configurations, HTTP scraping, price extraction, and the HTTP interface consumed by the Phoenix core.

## Technology Stack
- **Language:** Rust (latest stable)
- **HTTP server:** axum (for the microservice API)
- **HTTP client:** reqwest (for scraping)
- **HTML parsing:** scraper (CSS selector-based)
- **Config:** TOML files per store per country
- **Error handling:** thiserror (library errors), anyhow (application errors)
- **Testing:** cargo test, proptest (property-based), cargo-fuzz (fuzzing)
- **Linting:** cargo fmt, cargo clippy

## Owned Domains

### Microservice Endpoints (in `apps/scraper/src/`)
- `POST /scrape` — Accepts a book ISBN + store ID, returns price data
- `POST /scrape/batch` — Accepts multiple ISBN + store pairs
- `GET /stores` — Returns available store configurations
- `GET /health` — Health check

### TOML Configurations (in `scrapers/`)
```
scrapers/
├── za/
│   ├── exclusive_books.toml
│   ├── takealot.toml
│   ├── loot.toml
│   └── ...
├── uk/
│   └── ...
└── schema.toml              # TOML schema documentation
```

Each store config:
```toml
[store]
name = "Exclusive Books"
base_url = "https://www.exclusivebooks.co.za"
country = "ZA"
currency = "ZAR"
has_physical = true

[search]
url_template = "{base_url}/search?q={isbn}"
method = "GET"

[selectors]
price = ".product-price .current-price"
in_stock = ".availability-status"
title = ".product-title h1"
product_url = "link[rel=canonical]"

[rate_limit]
requests_per_minute = 10
respect_robots_txt = true
```

### Modules
- `src/main.rs` — axum server, routes
- `src/config.rs` — TOML parsing and validation
- `src/scraper.rs` — Core scraping logic (HTTP + selector extraction)
- `src/store.rs` — Store registry, configuration loading
- `src/price.rs` — Price parsing (currency-aware, handles "R 149.99", "R149", etc.)
- `src/error.rs` — Error types (thiserror)
- `src/rate_limiter.rs` — Per-store rate limiting

## Key Patterns

### robots.txt compliance
Always check robots.txt before scraping. Cache the result. If disallowed, skip the store and log.

### Rate limiting as courtesy
Per-store rate limits defined in TOML. Never exceed. Default: 10 req/min.

### User-agent honesty
Identify as The Stacks scraper with a contact URL. No spoofing.

### Price parsing resilience
Prices come in many formats. Property-based tests (proptest) ensure the parser handles them all.

## Context Loading Requirements
```
/Users/erinversfeld/thestacks/docs/agents/standards/code-quality.md
/Users/erinversfeld/thestacks/docs/agents/standards/testing.md
/Users/erinversfeld/thestacks/docs/technical-architecture.md (sections 11, 20)
```

## Integration Handoffs
- **elixir-agent:** HTTP interface contract. Phoenix calls the scraper via Oban workers (TriggerPriceScrapeJob).
- **platform-agent:** Dockerfile, Fly Machine config.
- **database-agent:** Price data format must match `price_snapshots` table schema.

## Pre-approved Commands
```bash
cd apps/scraper && cargo build
cd apps/scraper && cargo test
cd apps/scraper && cargo fmt -- --check
cd apps/scraper && cargo clippy -- -D warnings
cd apps/scraper && cargo audit
cd apps/scraper && cargo fuzz run [target]
```

---

## Orchestrator Integration

DO NOT: Write plan files, commit messages, or proceed to next phase.
DO: Write Rust code, tests, TOML configs, and return a completion report.

### Completion Report Format
1. Summary of what was implemented
2. Files created/modified (absolute paths)
3. Test commands run and results
4. DoD items satisfied for this phase
