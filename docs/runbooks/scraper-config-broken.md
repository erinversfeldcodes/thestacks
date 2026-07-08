# Runbook: Scraper Config Broken (Price Data Gap)

**Severity:** P3 (enrichment quality degradation — no user-visible errors)
**Owner:** Platform operator
**Last reviewed:** 2026-06-10

**See also:** `docs/agents/rust-agent.md` (scraper architecture), `docs/decisions/011-broadway-for-price-enrichment.md` (price pipeline).

---

## Symptoms

**User sees:**
- "No prices found" or stale price data on book detail overlay for books from a specific store
- Price sparklines showing a gap or flat line for a specific bookshop

**Operator sees:**
- `price_snapshots` table: no new rows for a specific `store_id` in the last 24–48 hours
- Oban `price_scrape` queue: jobs completing without errors but not producing price data
- Metrics dashboard: "data freshness" for prices showing yellow/red for specific stores
- Source health dashboard (if implemented): HTML structure change detected for a scraper target

**Subtle indicator:** The Rust scraper returns successfully (HTTP 200 to Oban) but with an empty prices list, or prices that are all `R0.00` or clearly wrong values. This is the most dangerous pattern — silent data corruption rather than an obvious failure.

---

## Impact

**Broken / Degraded:**
- Price tracking for the affected bookshop(s)
- Price alerts for WishList books (if a target price can't be checked)
- Marketplace price guidance (prices from affected stores missing from "compare" view)

**Still working:**
- All other bookshop prices (each store has its own scraper config)
- All other platform features
- Prices from unaffected stores continue updating normally

---

## Diagnosis

### Step 1: Identify which stores are affected

```sql
-- Find stores with no price snapshots in the last 48 hours
SELECT bs.name, bs.id, MAX(ps.scraped_at) as last_scraped, COUNT(ps.id) as total_snapshots
FROM bookstores bs
LEFT JOIN price_snapshots ps ON ps.store_id = bs.id
GROUP BY bs.name, bs.id
HAVING MAX(ps.scraped_at) < NOW() - INTERVAL '48 hours'
   OR MAX(ps.scraped_at) IS NULL
ORDER BY last_scraped ASC NULLS FIRST;
```

### Step 2: Check Oban scraper jobs for the affected store

The `TriggerPriceScrapeJob` worker runs on the `:scraper` Oban queue (see `apps/core/lib/stacks/workers/trigger_price_scrape_job.ex`).

```sql
-- Recent price scrape jobs
SELECT id, args, state, attempt, errors, completed_at
FROM oban_jobs
WHERE queue = 'scraper'
  AND worker = 'Stacks.Workers.TriggerPriceScrapeJob'
ORDER BY inserted_at DESC LIMIT 20;
```

Look at:
- `state`: `completed` but no prices → config mismatch (selector not finding elements)
- `state`: `discarded` → network failure or scraper crash
- `errors`: HTTP error codes, parsing failures

Also check the `:scraper_fuse` circuit breaker — if the scraper has been failing repeatedly the fuse blows for 15 minutes and core stops calling it. See `Stacks.CircuitBreakers` (`apps/core/lib/stacks/circuit_breakers.ex`).

### Step 3: Check the Rust scraper logs

```bash
fly logs -a thestacks-scraper | grep -i "<store_name>\|price\|selector" | tail -100
```

The scraper runs in region `jnb` (see `deploy/fly.scraper.toml`).

Or if the Rust scraper is called via HTTP from the Elixir core:
```bash
fly logs -a thestacks-core | grep -i "scraper\|TriggerPriceScrapeJob" | tail -50
```

Common error signatures:
- `"selector '.price-tag' returned 0 elements"` — the bookshop updated their HTML structure
- `"HTTP 403 Forbidden"` — the bookshop has blocked the scraper
- `"HTTP 429 Too Many Requests"` — rate limit hit
- `"Failed to parse price: 'R-1.00'"` — currency or format change

### Step 4: Exercise the scraper directly via HTTP

The scraper is TOML-driven. Configs live at `apps/scraper/scrapers/<country_code>/<store_name>.toml` (currently `za/exclusive_books.toml` and `za/takealot.toml`).

The binary is an axum HTTP server with no CLI subcommands — to test a config, exercise `POST /scrape` with an HMAC-signed `X-Internal-Token` (see `apps/scraper/src/auth.rs`, signed over `METHOD + path` using `SCRAPER_HMAC_SECRET`).

```bash
# Run the scraper locally with the project's scrapers/ directory as cwd
cd apps/scraper
SCRAPER_HMAC_SECRET=local-dev cargo run

# In another shell, generate a token and hit /scrape
TOKEN=$(echo -n "POST/scrape" | openssl dgst -sha256 -hmac "local-dev" -hex | awk '{print $2}')
curl -sX POST http://localhost:8080/scrape \
  -H "x-internal-token: $TOKEN" \
  -H "content-type: application/json" \
  -d '{"isbn":"9780008442323","store":"za/exclusive_books"}'

# Expected: JSON with price_cents, currency, url
# 404 → store key not loaded; 500 with selector miss → config is broken
```

If this is a Fly.io production issue, hit the scraper from the core machine over the private 6PN network:
```bash
fly ssh console -a thestacks-core
# from the core shell:
curl http://thestacks-scraper.internal:8080/health
```

To force a config reload after editing TOML without redeploying:
```bash
# Sign POST /config/reload, then call it (HMAC auth required)
curl -sX POST http://thestacks-scraper.internal:8080/config/reload \
  -H "x-internal-token: $TOKEN"
# Response: {"loaded": N}
```

### Step 5: Inspect the bookshop's HTML manually

Open the bookshop's website in a browser and inspect the element that should contain the price:

```bash
# Use curl to check the page structure
curl -s "https://www.exclusivebooks.co.za/product/9780008442323" | \
  grep -A2 -B2 "price\|Price\|R[0-9]" | head -50
```

Compare the HTML structure against the selectors in the TOML config:
```toml
# apps/scraper/scrapers/za/exclusive_books.toml
[selectors]
price = ".product-price, .price"   # comma-separated CSS selectors; may need updating
title = ".product-name, .product-title"
in_stock = ".availability, .stock-status"
currency = "ZAR"
```

---

## Response

### If the bookshop changed their HTML structure

This is the most common cause. The scraper config needs a selector update.

1. Open the bookshop's website and find the current CSS selector for the price element using browser dev tools (right-click price → Inspect).

2. Update the TOML config:
   ```toml
   # apps/scraper/scrapers/za/exclusive_books.toml
   [selectors]
   price = ".new-price-class .amount, .product-price"   # comma-separated fallbacks
   ```

3. Test locally by running the scraper and hitting `POST /scrape` as in Diagnosis Step 4.

4. Either hot-reload configs in production (no redeploy):
   ```bash
   # signed POST /config/reload — see Step 4
   curl -sX POST http://thestacks-scraper.internal:8080/config/reload \
     -H "x-internal-token: $TOKEN"
   ```

   Or commit and redeploy:
   ```bash
   fly deploy -c deploy/fly.scraper.toml
   ```

5. Trigger a fresh scrape by enqueuing the worker:
   ```bash
   fly ssh console -a thestacks-core
   ```
   ```elixir
   iex> %{"isbn" => "9780008442323", "book_id" => book_id}
   ...> |> Stacks.Workers.TriggerPriceScrapeJob.new()
   ...> |> Oban.insert()
   ```

### If the bookshop is blocking the scraper (HTTP 403)

The bookshop may have detected automated requests. Options:

1. **Check robots.txt:** Ensure the scraper respects `robots.txt`. If the bookshop has added a disallow rule, the scraper must comply.
   ```bash
   curl https://www.exclusivebooks.co.za/robots.txt
   ```

2. **Add a polite delay:** Lower `requests_per_minute` in the `[rate_limit]` block of the TOML config.

3. **Review the User-Agent string:** Some sites block default scraper user agents. The default UA is set in `apps/scraper/src/scraper.rs` (`Engine`); identify as The Stacks scraper with a contact URL per `docs/agents/rust-agent.md`.

4. **Consider the legal implications:** Check `docs/technical-architecture.md` section 20 (Legal & Compliance). If the bookshop's terms of service prohibit scraping, the store may need to be disabled.

5. **Contact the bookshop directly:** Frame as a partnership opportunity. If the bookshop is interested, they can become a partner and push inventory via the Partner API (Phase 2) — more reliable than scraping.

### If the bookshop is rate-limiting (HTTP 429)

Lower `requests_per_minute` in the `[rate_limit]` block and lengthen `retry_after_seconds`:
```toml
[rate_limit]
requests_per_minute = 3       # was 10
retry_after_seconds = 120     # was 60
respect_robots_txt = true
```

### If the price format changed (currency, decimal separator)

Price parsing lives in `apps/scraper/src/price.rs`; the per-store TOML only sets the currency code. If the bookshop changes its display format (e.g. "R 299,00" instead of "R299.00") and the existing parser can't cope, the fix is in Rust, not in the TOML. Open an issue and ping rust-agent.

```toml
[selectors]
currency = "ZAR"
```

---

## Recovery

**Verify prices are flowing again:**
```sql
-- Check for new price snapshots after the fix
SELECT bs.name, COUNT(ps.id) as new_prices, MAX(ps.scraped_at) as latest
FROM price_snapshots ps
JOIN bookstores bs ON bs.id = ps.store_id
WHERE ps.scraped_at > NOW() - INTERVAL '2 hours'
GROUP BY bs.name
ORDER BY latest DESC;
```

**Verify a specific book's prices in the UI:**
Navigate to a book detail overlay and check that prices appear for the fixed store.

**Backfill missing price history:**
There is no automated backfill. Missing price snapshots during the outage period are simply a gap in the historical data. This is expected — price history is a best-effort time-series, not an audit-grade record.

---

## Post-Incident

- If the HTML structure change was not detected proactively: consider implementing HTML structure change detection (flagged in Issue #068 — source health monitoring). This would detect the change before users notice missing prices.
- If this is the second time the same store's config broke: consider marking the store as "fragile" in the TOML metadata and increasing monitoring frequency.
- Commit the updated TOML config with a comment explaining what changed and when:
  ```toml
  # Updated 2026-06-10: Exclusive Books redesigned their product page.
  # Old: price = ".product-price, .price"
  # New: price = ".purchase-block .display-price, .product-price"
  [selectors]
  price = ".purchase-block .display-price, .product-price"
  ```
- If the bookshop added scraping restrictions: file a partnership enquiry and document the outcome.
