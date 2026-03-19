# Runbook: Scraper Config Broken (Price Data Gap)

**Severity:** P3 (enrichment quality degradation — no user-visible errors)
**Owner:** Platform operator
**Last reviewed:** 2026-03-19

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

### Step 2: Check Oban price_scrape jobs for the affected store

```sql
-- Recent price scrape jobs for a specific store
SELECT id, args, state, attempt, errors, completed_at
FROM oban_jobs
WHERE queue = 'price_scrape'
  AND args->>'store_id' = '<store_uuid>'
ORDER BY inserted_at DESC LIMIT 20;
```

Look at:
- `state`: `completed` but no prices → config mismatch (selector not finding elements)
- `state`: `discarded` → network failure or scraper crash
- `errors`: HTTP error codes, parsing failures

### Step 3: Check the Rust scraper logs

```bash
fly logs -a thestacks-scraper | grep -i "<store_name>\|price\|selector" | tail -100
```

Or if the Rust scraper is called via HTTP from the Elixir core:
```bash
fly logs -a thestacks-core | grep -i "scraper\|price_scrape" | tail -50
```

Common error signatures:
- `"selector '.price-tag' returned 0 elements"` — the bookshop updated their HTML structure
- `"HTTP 403 Forbidden"` — the bookshop has blocked the scraper
- `"HTTP 429 Too Many Requests"` — rate limit hit
- `"Failed to parse price: 'R-1.00'"` — currency or format change

### Step 4: Manually test the scraper config

The scraper is TOML-driven. The config for each store is in `scrapers/<country_code>/<store_name>.toml`.

```bash
# Test a scraper config manually (from project root)
cd apps/scraper
cargo run -- test-config --config ../../scrapers/za/exclusive_books.toml --isbn 9780008442323

# Expected output: a price in ZAR and a URL
# Actual output: "0 prices found" or an error → config is broken
```

If this is a Fly.io production issue, test from the scraper machine:
```bash
fly ssh console -a thestacks-scraper
./scraper test-config --config /app/scrapers/za/exclusive_books.toml --isbn 9780008442323
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
# scrapers/za/exclusive_books.toml
[price]
selector = ".product-price .price"  # This may have changed
```

---

## Response

### If the bookshop changed their HTML structure

This is the most common cause. The scraper config needs a selector update.

1. Open the bookshop's website and find the current CSS selector for the price element using browser dev tools (right-click price → Inspect).

2. Update the TOML config:
   ```toml
   # scrapers/za/exclusive_books.toml
   [price]
   selector = ".new-price-class .amount"  # Updated selector
   ```

3. Test locally:
   ```bash
   cargo run -- test-config --config scrapers/za/exclusive_books.toml --isbn 9780008442323
   ```

4. Commit and deploy:
   ```bash
   fly deploy -c deploy/fly.scraper.toml
   ```

5. Trigger a manual scrape for the affected store to verify the fix:
   ```bash
   fly ssh console -a thestacks-core
   ```
   ```elixir
   iex> Stacks.Enrichment.PricePipeline.trigger_store_refresh(store_id)
   ```

### If the bookshop is blocking the scraper (HTTP 403)

The bookshop may have detected automated requests. Options:

1. **Check robots.txt:** Ensure the scraper respects `robots.txt`. If the bookshop has added a disallow rule, the scraper must comply.
   ```bash
   curl https://www.exclusivebooks.co.za/robots.txt
   ```

2. **Add a polite delay:** Increase the `request_delay_ms` in the TOML config.

3. **Review the User-Agent string:** Some sites block default scraper user agents. The TOML config supports a custom `user_agent` field.

4. **Consider the legal implications:** Check `docs/technical-architecture.md` section 20 (Legal & Compliance). If the bookshop's terms of service prohibit scraping, the store may need to be disabled.

5. **Contact the bookshop directly:** Frame as a partnership opportunity. If the bookshop is interested, they can become a partner and push inventory via the Partner API (Phase 2) — more reliable than scraping.

### If the bookshop is rate-limiting (HTTP 429)

Increase `request_delay_ms` in the TOML config and reduce the scraping frequency:
```toml
[scraper]
request_delay_ms = 5000  # 5 seconds between requests (was 1000)
max_requests_per_hour = 20  # Reduce from default
```

### If the price format changed (currency, decimal separator)

Update the TOML config's price parsing rules:
```toml
[price]
currency = "ZAR"
decimal_separator = "."
thousands_separator = ","
strip_prefix = "R"  # "R 299.00" → 299.00
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
  # Updated 2026-03-19: Exclusive Books redesigned their product page.
  # Old selector: .product-price .price
  # New selector: .purchase-block .display-price
  ```
- If the bookshop added scraping restrictions: file a partnership enquiry and document the outcome.
