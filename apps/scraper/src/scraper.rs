use crate::config::ScraperConfig;
use crate::error::ScraperError;
use crate::platform::{self, Capability, LookupMode, PriceSource};
use crate::price::{extract_in_stock, extract_price, extract_text};
use crate::rate_limiter::RateLimiter;
use crate::robots::RobotsChecker;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;

/// User-agent string for HTTP requests.
const USER_AGENT: &str = "TheStacksScraper/0.1 (+https://thestacks.app/scraper)";

/// How long to wait when a bulk sweep hits a store's rate limit.
///
/// The limiter uses a sliding 60-second window, so a wait shorter than the window
/// risks spinning. Only the index build waits; a price lookup surfaces the limit to
/// its caller instead of holding a request open.
const RATE_LIMIT_BACKOFF_SECS: u64 = 7;

/// Most pages of `/products.json` to walk when building a store's ISBN index.
///
/// At 250 products per page this covers 5,000 titles, which is comfortably above the
/// independent bookshops on the target list. The cap exists so a shop with an
/// unexpectedly enormous catalogue costs a known maximum instead of an open-ended
/// sweep; a store that needs more than this is a decision, not a default.
const MAX_INDEX_PAGES: u32 = 20;

/// Requests per minute to actually use: the stricter of what robots.txt asks for
/// and what the store config declares.
///
/// A declared `Crawl-delay` wins whenever it is stricter — Exclusive Books asks for
/// 10 s (6/min) while its config asks for 10/min. Shared by every fetch path so the
/// two cannot drift apart.
fn effective_rpm(policy: &crate::robots::RobotsPolicy, configured: u32) -> u32 {
    match policy.crawl_delay_secs {
        Some(secs) if secs > 0 => (60 / secs).max(1).min(configured),
        _ => configured,
    }
}

/// A single price result for one ISBN at one store.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct PriceResult {
    pub isbn: String,
    pub store: String,
    /// Price in smallest currency unit (cents). None if not found.
    pub price_cents: Option<i64>,
    pub currency: String,
    pub in_stock: Option<bool>,
    /// Direct URL to the product page, if extractable.
    pub url: Option<String>,
    pub title: Option<String>,
    /// Fraction of CSS selectors defined in the store config that matched at
    /// least one element in the scraped HTML. Used for source health monitoring.
    /// Always `Some` (price is always defined, so denominator ≥ 1). Range [0.0, 1.0].
    pub selector_match_rate: Option<f64>,
}

/// The scrape engine. Handles HTTP fetching, robots.txt, and rate limiting.
///
/// When `MOCK_HTTP=true` is set in the environment, HTML is loaded from
/// `tests/fixtures/<store_id>.html` instead of making real HTTP requests.
pub struct Engine {
    client: reqwest::Client,
    rate_limiter: RateLimiter,
    robots: RobotsChecker,
    /// Pre-loaded fixture HTML keyed by store ID (used when MOCK_HTTP=true).
    fixtures: HashMap<String, String>,
    /// True when running in mock mode (no real HTTP calls).
    mock: bool,
    /// Observed platform capability per store, so detection costs two requests
    /// once rather than on every scrape. Rebuilt from scratch on restart, which is
    /// deliberate: a replatformed shop gets re-observed rather than remembered
    /// wrongly.
    capabilities: dashmap::DashMap<String, Capability>,
    /// Per-store ISBN→product-path index, built on demand for stores that cannot be
    /// addressed by ISBN directly.
    ///
    /// In-process and transient: it dies with the node and is never persisted, which
    /// is what keeps it a lookup aid rather than a copy of someone's catalogue. It
    /// holds only ISBNs and paths — no titles, prices, descriptions or images.
    indexes: dashmap::DashMap<String, std::collections::HashMap<String, String>>,
}

impl Engine {
    /// Create a real (non-mock) engine.
    pub fn new() -> Result<Self, ScraperError> {
        let client = reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(30))
            .user_agent(USER_AGENT)
            .build()
            .map_err(ScraperError::Http)?;
        Ok(Self {
            robots: RobotsChecker::new(client.clone()),
            client,
            rate_limiter: RateLimiter::new(),
            fixtures: HashMap::new(),
            mock: false,
            capabilities: dashmap::DashMap::new(),
            indexes: dashmap::DashMap::new(),
        })
    }

    /// Create an engine that serves HTML from a pre-loaded fixture map.
    #[cfg(test)]
    pub fn new_mock(fixtures: HashMap<String, String>) -> Self {
        // Mock engine never makes real HTTP requests; use a minimal client for RobotsChecker API compat.
        let client = reqwest::Client::new();
        Self {
            robots: RobotsChecker::new(client.clone()),
            client,
            rate_limiter: RateLimiter::new(),
            fixtures,
            mock: true,
            capabilities: dashmap::DashMap::new(),
            indexes: dashmap::DashMap::new(),
        }
    }

    /// Scrape a single ISBN from a single store.
    pub async fn scrape(
        &self,
        isbn: &str,
        store_id: &str,
        config: &ScraperConfig,
    ) -> Result<PriceResult, ScraperError> {
        let search_url = config.search_url(isbn);
        let domain =
            extract_domain(&config.source.url).unwrap_or_else(|| config.source.url.clone());

        // robots.txt is consulted FIRST, before the rate limiter.
        //
        // The order used to be reversed, which spent a rate-limit slot on a request
        // we then refused to make — so a disallowed store could exhaust its own
        // budget without ever reaching the network. Asking permission before taking
        // a ticket is also the only order in which the returned `Crawl-delay` can
        // inform the rate-limit decision below.
        //
        // There is deliberately no config flag to skip this: compliance with
        // robots.txt is a hard rule, and a rule a TOML can switch off is not one.
        // Mock mode skips it because it never touches the network at all.
        let policy = if self.mock {
            crate::robots::RobotsPolicy {
                allowed: true,
                crawl_delay_secs: None,
            }
        } else {
            // Normalise the base URL before stripping so a trailing slash doesn't
            // cause strip_prefix to fail (e.g. "https://store.com/" vs "/search?q=…").
            let base = config.source.url.trim_end_matches('/');
            let path = search_url.strip_prefix(base).ok_or_else(|| {
                ScraperError::InvalidConfig(format!(
                    "search URL '{search_url}' does not begin with source URL '{base}'"
                ))
            })?;
            self.robots.policy(&config.source.url, path).await?
        };

        if !policy.allowed {
            // Stop here. Per the owner's rule the store's configuration stays in
            // place, so if the disallow is ever lifted this simply starts working
            // again — we do not fall back to another path or another tier.
            return Err(ScraperError::RobotsDisallowed {
                url: search_url.clone(),
            });
        }

        // A declared `Crawl-delay` wins whenever it is stricter than our own
        // configured rate. Previously it was parsed and discarded on the grounds
        // that the TOML's `requests_per_minute` was authoritative — but that let a
        // config out-request what the site asked for. Exclusive Books declares
        // `Crawl-delay: 10`, i.e. 6 req/min, while its TOML asks for 10.
        let effective_rpm = effective_rpm(&policy, config.rate_limit.requests_per_minute);

        self.rate_limiter.check_and_record(&domain, effective_rpm)?;

        let html = self.fetch_html(store_id, &search_url).await?;
        self.parse_result(isbn, store_id, config, &html, &search_url)
    }

    /// Scrape one ISBN, choosing the mechanism from the store's observed capability.
    ///
    /// This is the entry point the service calls. The cascade is deliberately the
    /// same shape as the ISBN resolver and the vision pipeline, so it inherits an
    /// idiom already maintained here:
    ///
    /// 1. **Platform API** when one was detected — structured JSON, no selectors.
    /// 2. **Legacy CSS selectors** only when no product API exists at all. That is
    ///    genuinely all there is for `loot.co.za` and `fortunatefinds.co.za`; it is
    ///    *not* a fallback for Shopify stores, whose storefront search cannot match
    ///    an ISBN in any field, so falling back there would only burn requests.
    pub async fn scrape_auto(
        &self,
        isbn: &str,
        store_id: &str,
        config: &ScraperConfig,
    ) -> Result<PriceResult, ScraperError> {
        let capability = self.capability_for(store_id, config).await?;

        match capability.price_source {
            PriceSource::None => self.scrape(isbn, store_id, config).await,
            _ => {
                self.scrape_via_platform(isbn, store_id, config, &capability)
                    .await
            }
        }
    }

    /// The store's capability, detected once and cached for the process lifetime.
    ///
    /// Cached because detection costs two requests against a shop, and store fuses
    /// exist precisely to keep request volume down. Not cached *permanently* in any
    /// durable sense: a restart re-derives it, which is the point — a replatformed
    /// shop is re-observed rather than remembered wrongly. A scheduled re-probe with
    /// a canary assertion is the remaining half of this (P3) and belongs in the
    /// Elixir side, which owns scheduling.
    pub async fn capability_for(
        &self,
        store_id: &str,
        config: &ScraperConfig,
    ) -> Result<Capability, ScraperError> {
        // Mock mode must keep exercising the legacy fixture path: detection would
        // make real requests, and the fixtures are HTML, not product JSON.
        if self.mock {
            return Ok(Capability::none());
        }

        if let Some(cached) = self.capabilities.get(store_id) {
            return Ok(cached.value().clone());
        }

        // Errors are propagated, never folded into `Capability::none()`.
        //
        // That fold was a silent-wrong-behaviour bug, observed live: a rate-limited
        // detection became "this store has no product API", which routed the scrape
        // to the legacy CSS-selector path, produced a price-parse failure against
        // HTML, melted the store's fuse, and persisted `price_source: "none"` as a
        // fact about a shop that demonstrably has a Shopify API.
        //
        // "We could not observe" and "we observed nothing" are different claims, and
        // only the second is worth recording.
        let detected = self.detect_capability(config).await?;

        self.capabilities
            .insert(store_id.to_string(), detected.clone());

        tracing::info!(
            "detected capability for store={}: source={:?} isbn_at={:?} lookup={:?}",
            store_id,
            detected.price_source,
            detected.isbn_location,
            detected.lookup_mode
        );

        Ok(detected)
    }

    /// Look up one ISBN at one store using its observed platform capability.
    ///
    /// This replaces the CSS-selector path, which cannot work on 6 of 10 targets:
    /// Shopify's storefront search does not index ISBNs in any field — proven
    /// against four stores using ISBNs they demonstrably stock — so
    /// `query_template = "{isbn}"` never matches there.
    pub async fn scrape_via_platform(
        &self,
        isbn: &str,
        store_id: &str,
        config: &ScraperConfig,
        capability: &Capability,
    ) -> Result<PriceResult, ScraperError> {
        let price = match (capability.price_source, capability.lookup_mode) {
            // The handle *is* the ISBN, so one request addresses the product and a
            // 404 is the store telling us it does not carry this edition.
            (PriceSource::ShopifyProductsJson, LookupMode::Direct) => {
                let (status, body) = self
                    .fetch_path(config, &format!("/products/{isbn}.js"))
                    .await?;

                match status {
                    200 => platform::shopify_product_js(&body, config.currency())?,
                    404 => {
                        return Err(ScraperError::NotStocked {
                            store: store_id.to_string(),
                            isbn: isbn.to_string(),
                        });
                    }
                    other => {
                        return Err(ScraperError::PriceParse(format!(
                            "unexpected HTTP {other} from /products/{isbn}.js"
                        )));
                    }
                }
            }

            // WooCommerce's Store API search matches `sku`, so no local index is
            // needed. An empty result set means not stocked.
            (PriceSource::WooStoreApi, LookupMode::NativeSearch) => {
                let (status, body) = self
                    .fetch_path(
                        config,
                        &format!("/wp-json/wc/store/v1/products?search={isbn}"),
                    )
                    .await?;

                if status != 200 {
                    return Err(ScraperError::PriceParse(format!(
                        "unexpected HTTP {status} from the Store API"
                    )));
                }

                match platform::woo_search(&body, isbn, config.currency())? {
                    Some(price) => price,
                    None => {
                        return Err(ScraperError::NotStocked {
                            store: store_id.to_string(),
                            isbn: isbn.to_string(),
                        });
                    }
                }
            }

            // The ISBN is on the product but the handle is not it, so the product
            // cannot be addressed directly. Build an ISBN→path index once, then use
            // it. Four of the six Shopify targets are in this category (Wordsworth,
            // Stellenbosch, Bridge, Clarke's).
            (PriceSource::ShopifyProductsJson, LookupMode::LocalIndex)
                if capability.isbn_location != platform::IsbnLocation::None =>
            {
                match self.index_lookup(isbn, store_id).await? {
                    Some(path) => {
                        let (status, body) = self.fetch_path(config, &format!("{path}.js")).await?;

                        match status {
                            200 => platform::shopify_product_js(&body, config.currency())?,
                            // The index said this path exists and it no longer does —
                            // the catalogue moved under us. Not "not stocked": we
                            // cannot tell, and guessing would write a false negative.
                            404 => {
                                self.indexes.remove(store_id);

                                return Err(ScraperError::IndexRequired {
                                    store: store_id.to_string(),
                                    isbn: isbn.to_string(),
                                });
                            }
                            other => {
                                return Err(ScraperError::PriceParse(format!(
                                    "unexpected HTTP {other} from {path}.js"
                                )));
                            }
                        }
                    }

                    // The whole catalogue was enumerated and this ISBN is not in it.
                    // That is a real answer: the shop does not carry this edition.
                    None => {
                        return Err(ScraperError::NotStocked {
                            store: store_id.to_string(),
                            isbn: isbn.to_string(),
                        });
                    }
                }
            }

            // No ISBN anywhere on this store's products, or no product API at all.
            // Explicitly *not* reported as "not stocked": we do not know whether the
            // shop has the book, only that we cannot ask. Fuzzy title matching is the
            // remaining path and it needs our catalogue, which this service does not
            // have — so it belongs a layer up.
            _ => {
                return Err(ScraperError::IndexRequired {
                    store: store_id.to_string(),
                    isbn: isbn.to_string(),
                });
            }
        };

        let base = config.source.url.trim_end_matches('/');

        Ok(PriceResult {
            isbn: isbn.to_string(),
            store: store_id.to_string(),
            price_cents: Some(price.price_cents),
            currency: price.currency,
            in_stock: price.in_stock,
            url: price
                .handle
                .as_deref()
                .map(|h| format!("{base}/products/{h}")),
            title: price.title,
            // Meaningless without selectors: nothing was matched by CSS. Left as
            // None rather than a fabricated 1.0, which would report perfect
            // extraction health for a path that has no selectors to match.
            selector_match_rate: None,
        })
    }

    /// Look up a product path for `isbn` in this store's index.
    ///
    /// Consults the index; never builds it. See `build_index/2` for why.
    async fn index_lookup(
        &self,
        isbn: &str,
        store_id: &str,
    ) -> Result<Option<String>, ScraperError> {
        if let Some(index) = self.indexes.get(store_id) {
            return Ok(index.get(isbn).cloned());
        }

        // No index yet, and building one here would be wrong: the sweep needs up to
        // MAX_INDEX_PAGES requests, and the per-store rate limit is 10/min — so an
        // inline build takes minutes and, worse, fails outright rather than waiting.
        // Measured against Wordsworth: capability detection plus the first index page
        // exhausted the budget and the request returned `rate limit exceeded`.
        //
        // Building belongs in `build_index/3`, driven on its own cadence. Until an
        // index exists, say so — `IndexRequired`, never `NotStocked`, because we do
        // not know whether the shop has the book.
        Err(ScraperError::IndexRequired {
            store: store_id.to_string(),
            isbn: isbn.to_string(),
        })
    }

    /// Build a store's ISBN→path index by walking `/products.json`.
    ///
    /// Separate from the lookup path on purpose: this is a bulk operation costing up
    /// to `MAX_INDEX_PAGES` requests against a shop limited to a few per minute, so it
    /// must run on its own cadence and never inside a price request.
    ///
    /// Retains only `(isbn, path)`. No titles, prices, descriptions or images, and
    /// nothing is persisted — the map lives in this process and dies with it, which is
    /// what keeps it a lookup aid rather than a copy of someone's catalogue.
    pub async fn build_index(
        &self,
        store_id: &str,
        config: &ScraperConfig,
    ) -> Result<usize, ScraperError> {
        // Paginated over /products.json, which is the only way to reach a product whose
        // handle is not its ISBN. Pagination confirmed at 250 per page.
        let mut index = std::collections::HashMap::new();

        for page in 1..=MAX_INDEX_PAGES {
            let path = format!("/products.json?limit=250&page={page}");

            // A bulk sweep must *wait* for the rate limit, not fail on it. A single
            // price lookup rightly returns an error and lets the caller back off, but
            // a 20-page walk against a shop limited to a few requests a minute will
            // hit the limit by design — treating that as failure is what made an
            // inline build impossible. Measured against Wordsworth: capability
            // detection plus one page exhausted the budget.
            let (status, body) = loop {
                match self.fetch_path(config, &path).await {
                    Ok(response) => break response,
                    Err(ScraperError::RateLimitExceeded { .. }) => {
                        tokio::time::sleep(std::time::Duration::from_secs(RATE_LIMIT_BACKOFF_SECS))
                            .await;
                    }
                    Err(e) => return Err(e),
                }
            };

            if status != 200 {
                break;
            }

            let listings = platform::shopify_products_json(&body)?;

            if listings.is_empty() {
                break;
            }

            // Retain everything *found* here, but only as (isbn → path): no titles,
            // prices or descriptions, and nothing is persisted. Filtering to ISBNs we
            // hold is impossible in this service — it does not know our catalogue —
            // so minimality is achieved by what the entry can hold, not by the filter.
            for entry in platform::index_entries(&listings, &|_| true) {
                index.insert(entry.isbn, entry.product_path);
            }

            let page_was_full = listings.len() == 250;

            if !page_was_full {
                break;
            }
        }

        tracing::info!(
            "built ISBN index for store={} with {} entries",
            store_id,
            index.len()
        );

        let size = index.len();
        self.indexes.insert(store_id.to_string(), index);

        Ok(size)
    }

    /// Observe what a store can do, with two cheap requests.
    ///
    /// Platform is derived rather than configured because bookshops replatform, and
    /// a stored `platform = "shopify"` turns that into a silent outage
    /// indistinguishable from "not stocked".
    pub async fn detect_capability(
        &self,
        config: &ScraperConfig,
    ) -> Result<Capability, ScraperError> {
        // Shopify first: it is 6 of 10 targets, so it is the likelier hit.
        //
        // A transport or rate-limit failure is propagated rather than treated as
        // "not Shopify" — concluding absence from a failed question is how a
        // rate-limited probe came to be recorded as a shop having no product API.
        // Only a genuine non-200, or a 200 with nothing usable in it, is evidence.
        let (shopify_status, shopify_body) =
            self.fetch_path(config, "/products.json?limit=50").await?;

        if shopify_status == 200 {
            if let Ok(listings) = platform::shopify_products_json(&shopify_body) {
                if !listings.is_empty() {
                    return Ok(platform::classify_shopify(&listings));
                }
            }
        }

        let (woo_status, woo_body) = self
            .fetch_path(config, "/wp-json/wc/store/v1/products?per_page=30")
            .await?;

        if woo_status == 200 {
            return Ok(platform::classify_woo(&woo_body));
        }

        // Neither API answered. Recorded as a fact about the store rather than
        // retried as a misconfiguration — loot.co.za and fortunatefinds.co.za are
        // genuinely in this category.
        Ok(Capability::none())
    }

    /// Fetch a path from a store, honouring robots.txt and the rate limit.
    ///
    /// The single compliant egress for anything this service requests from a shop.
    /// Both the legacy selector path and the platform adapters go through it, so
    /// there is one place that can be audited for the owner's robots.txt rule
    /// rather than one per call site — which is how the events job ended up
    /// scraping with no robots check at all.
    ///
    /// Returns the HTTP status alongside the body, because for the platform
    /// adapters **404 is meaningful data** (`/products/<isbn>.js` returning 404 is
    /// how a Shopify store says "we do not carry this ISBN"), not an error to
    /// propagate.
    pub async fn fetch_path(
        &self,
        config: &ScraperConfig,
        path: &str,
    ) -> Result<(u16, String), ScraperError> {
        let base = config.source.url.trim_end_matches('/');
        let url = format!("{base}{path}");
        let domain =
            extract_domain(&config.source.url).unwrap_or_else(|| config.source.url.clone());

        // robots.txt first, then the rate limit — see `scrape` for why that order
        // matters and why there is no flag to skip it.
        let policy = if self.mock {
            crate::robots::RobotsPolicy {
                allowed: true,
                crawl_delay_secs: None,
            }
        } else {
            self.robots.policy(&config.source.url, path).await?
        };

        if !policy.allowed {
            return Err(ScraperError::RobotsDisallowed { url });
        }

        let effective_rpm = effective_rpm(&policy, config.rate_limit.requests_per_minute);

        self.rate_limiter.check_and_record(&domain, effective_rpm)?;

        let response = self
            .client
            .get(&url)
            .send()
            .await
            .map_err(ScraperError::Http)?;

        let status = response.status().as_u16();
        let body = response.text().await.map_err(ScraperError::Http)?;

        Ok((status, body))
    }

    /// Fetch HTML — either from fixtures (mock mode) or real HTTP.
    async fn fetch_html(&self, store_id: &str, url: &str) -> Result<String, ScraperError> {
        if self.mock {
            return self.fixtures.get(store_id).cloned().ok_or_else(|| {
                ScraperError::ConfigNotFound(format!("no fixture for '{store_id}'"))
            });
        }

        let response = self
            .client
            .get(url)
            .send()
            .await
            .map_err(ScraperError::Http)?;

        // Surface HTTP 4xx/5xx as errors so they don't silently produce empty results.
        let response = response.error_for_status().map_err(ScraperError::Http)?;
        response.text().await.map_err(ScraperError::Http)
    }

    /// Parse a scraped HTML page into a PriceResult.
    fn parse_result(
        &self,
        isbn: &str,
        store_id: &str,
        config: &ScraperConfig,
        html: &str,
        page_url: &str,
    ) -> Result<PriceResult, ScraperError> {
        let currency = config.currency();

        let price_cents = match extract_price(html, &config.selectors.price, currency) {
            Ok(p) => Some(p.cents),
            Err(ScraperError::PriceNotFound { .. }) => None,
            Err(e) => return Err(e),
        };

        let title = if let Some(sel) = &config.selectors.title {
            extract_text(html, sel)?
        } else {
            None
        };

        let in_stock = if let Some(sel) = &config.selectors.in_stock {
            extract_in_stock(html, sel)?
        } else {
            None
        };

        let url = if let Some(sel) = &config.selectors.product_url {
            // Try to extract a canonical URL from the page.
            extract_text(html, sel)?.or_else(|| Some(page_url.to_string()))
        } else {
            Some(page_url.to_string())
        };

        // Compute selector match rate: fraction of defined selectors that
        // matched at least one element in the scraped HTML.
        let mut total: u32 = 1; // price is always defined
        let mut matched: u32 = if selector_matches_any(html, &config.selectors.price) {
            1
        } else {
            0
        };
        if let Some(sel) = &config.selectors.title {
            total += 1;
            if selector_matches_any(html, sel) {
                matched += 1;
            }
        }
        if let Some(sel) = &config.selectors.in_stock {
            total += 1;
            if selector_matches_any(html, sel) {
                matched += 1;
            }
        }
        if let Some(sel) = &config.selectors.product_url {
            total += 1;
            if selector_matches_any(html, sel) {
                matched += 1;
            }
        }
        let selector_match_rate = Some(matched as f64 / total as f64);

        Ok(PriceResult {
            isbn: isbn.to_string(),
            store: store_id.to_string(),
            price_cents,
            currency: currency.to_string(),
            in_stock,
            url,
            title,
            selector_match_rate,
        })
    }
}

#[cfg(test)]
impl Default for Engine {
    /// Convenience default for tests: mock mode with no fixtures.
    /// Prefer `Engine::new_mock(fixtures)` when fixtures are needed.
    fn default() -> Self {
        Self::new_mock(HashMap::new())
    }
}

/// Returns true if `selector_str` parses as a valid CSS selector and matches
/// at least one element in `html`. Returns false for unparseable selectors
/// rather than panicking.
fn selector_matches_any(html: &str, selector_str: &str) -> bool {
    let Ok(sel) = scraper::Selector::parse(selector_str) else {
        return false;
    };
    let document = scraper::Html::parse_document(html);
    document.select(&sel).next().is_some()
}

fn extract_domain(url: &str) -> Option<String> {
    let (scheme, rest) = url.split_once("://")?;
    let host = rest.split('/').next()?;
    Some(format!("{scheme}://{host}"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::ScraperConfig;

    fn exclusive_books_config() -> ScraperConfig {
        ScraperConfig::from_toml_str(
            r#"
[source]
name = "Exclusive Books"
country = "ZA"
url = "https://www.exclusivebooks.co.za"

[search]
method = "GET"
path = "/search"
query_param = "q"
query_template = "{isbn}"

[selectors]
price = ".product-price"
title = ".product-title"
in_stock = ".stock-status"
currency = "ZAR"

[rate_limit]
requests_per_minute = 10
"#,
        )
        .unwrap()
    }

    fn takealot_config() -> ScraperConfig {
        ScraperConfig::from_toml_str(
            r#"
[source]
name = "Takealot"
country = "ZA"
url = "https://www.takealot.com"

[search]
method = "GET"
path = "/all"
query_param = "qsearch"
query_template = "{isbn}"

[selectors]
price = ".currency.plus"
title = ".pdp-title"
in_stock = ".add-to-cart-button"
currency = "ZAR"

[rate_limit]
requests_per_minute = 10
"#,
        )
        .unwrap()
    }

    fn make_exclusive_books_html(price: &str, title: &str, stock: &str) -> String {
        format!(
            r#"<html><body>
                <h1 class="product-title">{title}</h1>
                <span class="product-price">{price}</span>
                <span class="stock-status">{stock}</span>
            </body></html>"#
        )
    }

    fn make_takealot_html(price: &str, title: &str, stock: &str) -> String {
        format!(
            r#"<html><body>
                <h1 class="pdp-title">{title}</h1>
                <span class="currency plus">{price}</span>
                <button class="add-to-cart-button">{stock}</button>
            </body></html>"#
        )
    }

    #[tokio::test]
    async fn test_scrape_exclusive_books_fixture() {
        let html = make_exclusive_books_html("R 285.00", "The Secret History", "In Stock");
        let mut fixtures = HashMap::new();
        fixtures.insert("za/exclusive_books".to_string(), html);

        let engine = Engine::new_mock(fixtures);
        let config = exclusive_books_config();
        let result = engine
            .scrape("9780679410232", "za/exclusive_books", &config)
            .await
            .unwrap();

        assert_eq!(result.isbn, "9780679410232");
        assert_eq!(result.store, "za/exclusive_books");
        assert_eq!(result.price_cents, Some(28500));
        assert_eq!(result.currency, "ZAR");
        assert_eq!(result.in_stock, Some(true));
        assert_eq!(result.title.as_deref(), Some("The Secret History"));
    }

    #[tokio::test]
    async fn test_scrape_takealot_fixture() {
        let html = make_takealot_html("R 275.00", "The Secret History", "Add to Cart");
        let mut fixtures = HashMap::new();
        fixtures.insert("za/takealot".to_string(), html);

        let engine = Engine::new_mock(fixtures);
        let config = takealot_config();
        let result = engine
            .scrape("9780679410232", "za/takealot", &config)
            .await
            .unwrap();

        assert_eq!(result.price_cents, Some(27500));
        assert_eq!(result.currency, "ZAR");
        assert_eq!(result.store, "za/takealot");
    }

    #[tokio::test]
    async fn test_scrape_out_of_stock() {
        let html = make_exclusive_books_html("R 285.00", "A Book", "Out of Stock");
        let mut fixtures = HashMap::new();
        fixtures.insert("za/exclusive_books".to_string(), html);

        let engine = Engine::new_mock(fixtures);
        let config = exclusive_books_config();
        let result = engine
            .scrape("9780679410232", "za/exclusive_books", &config)
            .await
            .unwrap();

        assert_eq!(result.in_stock, Some(false));
    }

    #[tokio::test]
    async fn test_scrape_missing_price_returns_none() {
        // HTML with no price element.
        let html = r#"<html><body><h1 class="product-title">A Book</h1></body></html>"#;
        let mut fixtures = HashMap::new();
        fixtures.insert("za/exclusive_books".to_string(), html.to_string());

        let engine = Engine::new_mock(fixtures);
        let config = exclusive_books_config();
        let result = engine
            .scrape("9780679410232", "za/exclusive_books", &config)
            .await
            .unwrap();

        assert_eq!(result.price_cents, None);
    }

    // ------------------------------------------------------------------
    // selector_match_rate tests
    // ------------------------------------------------------------------

    /// Helper: build a config with only the price selector.
    fn price_only_config() -> ScraperConfig {
        ScraperConfig::from_toml_str(
            r#"
[source]
name = "Match Rate Test Store"
country = "ZA"
url = "https://matchrate.example.com"

[search]
method = "GET"
path = "/search"
query_param = "q"

[selectors]
price = ".price"
currency = "ZAR"

[rate_limit]
requests_per_minute = 60
"#,
        )
        .unwrap()
    }

    /// Helper: build a config with price + title selectors.
    fn price_and_title_config() -> ScraperConfig {
        ScraperConfig::from_toml_str(
            r#"
[source]
name = "Match Rate Test Store"
country = "ZA"
url = "https://matchrate.example.com"

[search]
method = "GET"
path = "/search"
query_param = "q"

[selectors]
price = ".price"
title = ".title"
currency = "ZAR"

[rate_limit]
requests_per_minute = 60
"#,
        )
        .unwrap()
    }

    /// Helper: build a config with all four selectors defined.
    fn all_selectors_config() -> ScraperConfig {
        ScraperConfig::from_toml_str(
            r#"
[source]
name = "Match Rate Test Store"
country = "ZA"
url = "https://matchrate.example.com"

[search]
method = "GET"
path = "/search"
query_param = "q"

[selectors]
price = ".price"
title = ".title"
in_stock = ".in-stock"
product_url = ".product-url"
currency = "ZAR"

[rate_limit]
requests_per_minute = 60
"#,
        )
        .unwrap()
    }

    /// Test case 1: all selectors defined and all match → rate = 1.0
    #[tokio::test]
    async fn test_selector_match_rate_all_defined_all_match() {
        let html = r#"<html><body>
            <span class="price">R 100.00</span>
            <h1 class="title">A Book</h1>
            <span class="in-stock">In Stock</span>
            <a class="product-url" href="/book/123">View</a>
        </body></html>"#;

        let mut fixtures = HashMap::new();
        fixtures.insert("test/all_selectors".to_string(), html.to_string());

        let engine = Engine::new_mock(fixtures);
        let config = all_selectors_config();
        let result = engine
            .scrape("9780679410232", "test/all_selectors", &config)
            .await
            .unwrap();

        assert_eq!(
            result.selector_match_rate,
            Some(1.0),
            "all 4 selectors defined and matched → rate should be 1.0"
        );
    }

    /// Test case 2: price + title defined, price matches, title does not → rate = 0.5
    #[tokio::test]
    async fn test_selector_match_rate_two_defined_one_matches() {
        let html = r#"<html><body>
            <span class="price">R 100.00</span>
        </body></html>"#;

        let mut fixtures = HashMap::new();
        fixtures.insert("test/price_title".to_string(), html.to_string());

        let engine = Engine::new_mock(fixtures);
        let config = price_and_title_config();
        let result = engine
            .scrape("9780679410232", "test/price_title", &config)
            .await
            .unwrap();

        assert_eq!(
            result.selector_match_rate,
            Some(0.5),
            "2 selectors defined (price matched, title not) → rate should be 0.5"
        );
    }

    /// Test case 3: only price selector defined, price matches → rate = 1.0
    #[tokio::test]
    async fn test_selector_match_rate_only_price_matches() {
        let html = r#"<html><body>
            <span class="price">R 100.00</span>
        </body></html>"#;

        let mut fixtures = HashMap::new();
        fixtures.insert("test/price_only".to_string(), html.to_string());

        let engine = Engine::new_mock(fixtures);
        let config = price_only_config();
        let result = engine
            .scrape("9780679410232", "test/price_only", &config)
            .await
            .unwrap();

        assert_eq!(
            result.selector_match_rate,
            Some(1.0),
            "only price selector defined and it matched → rate should be 1.0"
        );
    }

    /// Test case 4: only price selector defined, price does NOT match → rate = 0.0
    #[tokio::test]
    async fn test_selector_match_rate_only_price_no_match() {
        let html = r#"<html><body>
            <span class="other-price">R 100.00</span>
        </body></html>"#;

        let mut fixtures = HashMap::new();
        fixtures.insert("test/price_miss".to_string(), html.to_string());

        let engine = Engine::new_mock(fixtures);
        let config = price_only_config();
        let result = engine
            .scrape("9780679410232", "test/price_miss", &config)
            .await
            .unwrap();

        assert_eq!(
            result.selector_match_rate,
            Some(0.0),
            "only price selector defined but it did not match → rate should be 0.0"
        );
    }

    /// Test case 5: all 4 selectors defined, 2 match → rate = 0.5
    #[tokio::test]
    async fn test_selector_match_rate_four_defined_two_match() {
        let html = r#"<html><body>
            <span class="price">R 100.00</span>
            <h1 class="title">A Book</h1>
        </body></html>"#;

        let mut fixtures = HashMap::new();
        fixtures.insert("test/four_two_match".to_string(), html.to_string());

        let engine = Engine::new_mock(fixtures);
        let config = all_selectors_config();
        let result = engine
            .scrape("9780679410232", "test/four_two_match", &config)
            .await
            .unwrap();

        assert_eq!(
            result.selector_match_rate,
            Some(0.5),
            "4 selectors defined, 2 matched → rate should be 0.5"
        );
    }

    #[tokio::test]
    async fn test_rate_limiter_enforced() {
        // Config with limit of 2 requests/min.
        let config = ScraperConfig::from_toml_str(
            r#"
[source]
name = "Rate Test Store"
country = "ZA"
url = "https://ratetest.example.com"

[search]
method = "GET"
path = "/search"
query_param = "q"

[selectors]
price = ".price"

[rate_limit]
requests_per_minute = 2
"#,
        )
        .unwrap();

        let html = r#"<div class="price">R 100.00</div>"#;
        let mut fixtures = HashMap::new();
        fixtures.insert("test/rate_store".to_string(), html.to_string());

        let engine = Engine::new_mock(fixtures);

        // First two requests succeed.
        engine
            .scrape("isbn1", "test/rate_store", &config)
            .await
            .unwrap();
        engine
            .scrape("isbn2", "test/rate_store", &config)
            .await
            .unwrap();

        // Third request should be rate-limited.
        let result = engine.scrape("isbn3", "test/rate_store", &config).await;
        assert!(result.is_err());
        assert!(matches!(
            result.unwrap_err(),
            ScraperError::RateLimitExceeded { .. }
        ));
    }
}
