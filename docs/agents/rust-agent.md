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
DO: Write Rust code, tests, TOML configs, and return a completion report. Call `mcp__project-tools__update_progress(number, note)` to append progress notes — do not edit the issue file directly.

### Challenge the Brief

Before writing any code, read the phase plan carefully and identify anything that seems:
- **Underspecified:** scraper selector logic, price parsing edge cases, or API response shapes that are ambiguous or missing detail
- **Risky:** assumptions about store HTML structure stability, robots.txt compliance, or rate limit values that may be wrong or legally sensitive
- **Suboptimal:** a better Rust crate, axum pattern, or CSS selector strategy exists for this specific problem
- **Inconsistent:** the plan conflicts with existing TOML config schema, the `thiserror`/`anyhow` error handling pattern, or the robots.txt compliance requirement

Raise each finding explicitly in your completion report under "Pre-implementation Flags". If no flags, state "None". Do not block on flags — implement as planned, but flag first.

### Self-Verification

Before submitting your completion report:
1. Run `cargo test` and confirm it passes. Record the exact output (test count, any skips).
2. Run `cargo clippy -- -D warnings` and confirm no warnings.
3. Run `cargo fmt -- --check` and confirm no formatting issues.
4. If the work includes a new scraper or endpoint, exercise it with a realistic ISBN and store config and confirm the output price data looks correct and matches the `price_snapshots` schema.
5. If any step fails, fix it before submitting.

Do not submit a completion report with failing tests, clippy warnings, or an untested scraper path.

### Test-First Protocol

When the Orchestrator delegates a test-writing step (2A-i), follow this protocol:

1. **Read the phase DoD items** and translate each into one or more test cases
2. **Write tests only** — no production code, no stubs, no mock implementations
3. **Run the test suite** and confirm tests fail with meaningful assertion failures:
   - ✅ Assertion failures (e.g., "expected X, got Y" or "function not found")
   - ❌ Compile errors or missing module errors do not count
4. **Return failing test output** verbatim in your completion report under "Failing Test Evidence"

Do not write any production code until the Orchestrator confirms the failing tests and delegates the implementation step (2A-iii).

**Test command:** `cargo test`

### Self-Review

Before submitting your completion report, load `docs/agents/reviewers/rust-reviewer.md` and self-check the following mechanical axes:

| Check | How to verify |
|-------|---------------|
| `cargo fmt --check` | Run and confirm no formatting issues |
| `cargo clippy -- -D warnings` | Run and confirm zero warnings |
| Error handling | `thiserror` for library errors, `anyhow` for application errors; no `unwrap()` in library code |
| Type system | Newtypes for domain concepts (ISBN, Price); enums for variants |
| TOML config validation | Config structs validate on load; invalid configs fail fast |
| HMAC auth | All requests to/from core validate HMAC signatures |
| Tests passing | `cargo test` passes with zero failures |

Fix any failures before submitting. Include a **Self-Review** section in your completion report (see Completion Report Format below).

A missing or empty Self-Review section is a reviewer blocker.

### Completion Report Format
1. Summary of what was implemented
2. Files created/modified (absolute paths)
3. **Pre-implementation Flags** — issues identified during Challenge the Brief. "None" if clean.
4. **Spec Coverage Matrix** — enumerate every endpoint, module, and TOML config named in the
   Technical Requirements section of the issue. For each item, record:

   | Item | Implemented | Tested (happy + error path) | Notes |
   |------|-------------|----------------------------|-------|
   | POST /scrape | ✅ | ❌ | deferred — reason here |

   Any row with ❌ in either column **must** have an explicit justification. A row with ❌ and
   no justification is a blocker — do not submit.

5. **Test Results** — verbatim output from self-verification:
   ```
   $ cargo test
   ...XX tests passed
   $ cargo clippy -- -D warnings
   ...no issues
   $ cargo fmt -- --check
   ...
   ```
   Include happy-path exercise result if a scraper or endpoint was exercised with real input.
6. DoD items satisfied — cite file:line evidence for each checked item.
7. **Self-Review** — mechanical axes checked before submission:
   | Axis | Result | Notes |
   |------|--------|-------|
   A missing or empty self-review table is a reviewer blocker.
