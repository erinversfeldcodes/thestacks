use crate::config::ScraperConfig;
use crate::error::ScraperError;
use crate::platform::{self, Capability, LookupMode, PriceSource};
use crate::price::{extract_in_stock, extract_price, extract_text};
use crate::rate_limiter::RateLimiter;
use crate::robots::RobotsChecker;
use crate::sitemap::{self, CrawlBudget, Spend};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::time::Instant;

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

/// Build a `PriceResult` from an extracted price. One place, so the URL shape and the
/// deliberately-absent `selector_match_rate` cannot drift between call sites.
fn price_result(
    isbn: &str,
    store_id: &str,
    config: &ScraperConfig,
    price: platform::ProductPrice,
) -> PriceResult {
    let base = config.source.url.trim_end_matches('/');

    PriceResult {
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
        // Meaningless without selectors: nothing was matched by CSS. Left None rather
        // than a fabricated 1.0, which would report perfect extraction health for a
        // path that has no selectors to match.
        selector_match_rate: None,
    }
}

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

/// How long to wait between the documents of one walk.
///
/// ⚠️ **`Crawl-delay` is a SPACING, not a rate, and we were honouring only the rate.**
/// `effective_rpm` turns `Crawl-delay: 10` into 6 requests/minute, and `check_and_record` enforces
/// that with a sliding *window* — which happily permits all six inside two seconds and then nothing
/// for the rest of the minute. That passes the limiter while doing precisely what the shop asked us
/// not to: exclusivebooks.co.za declares `Crawl-delay: 10`, and a four-document walk at the old fixed
/// 500 ms spacing would have burst all four at it in under two seconds.
///
/// `RateLimiter::min_delay` — the spacer this needs — already existed, had tests, and was **called by
/// no production code at all**. Another built-and-not-wired instance; this is the call site it was
/// waiting for.
///
/// Takes whichever is longer: our own courtesy floor, or what the shop asked for. Never shorter than
/// the shop's request, because that is the whole point.
fn document_spacing(
    policy: &crate::robots::RobotsPolicy,
    effective_rpm: u32,
) -> std::time::Duration {
    let declared = policy
        .crawl_delay_secs
        .map(|s| std::time::Duration::from_secs(s as u64))
        .unwrap_or_default();

    declared
        .max(RateLimiter::min_delay(effective_rpm))
        .max(sitemap::INTER_DOCUMENT_DELAY)
}

/// Cache validators from a previous fetch of the same path, sent so the shop can answer "unchanged".
///
/// Empty strings mean "we have none", which is the normal state for a first fetch and for any page
/// whose origin sends neither header.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Validators {
    pub if_none_match: String,
    pub if_modified_since: String,
}

/// One capped document read: what came back, and whether we hung up before the end of it.
///
/// `hung_up` exists because a byte cap that silently truncates is indistinguishable from a short
/// document. The walk sets `truncated` from it — without that, cutting an index off mid-`<loc>` yields
/// a parse with no children and a walk that ends *normally*, reporting a complete result for a
/// document it only partly read. Found by the test that drove budget exhaustion, which is exactly the
/// branch that had never been exercised.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
struct CappedBody {
    status: u16,
    body: String,
    bytes: u64,
    hung_up: bool,
}

/// One page fetch: what came back, plus the validators to send next time.
///
/// A struct rather than a widening tuple. `fetch_path` previously returned
/// `(u16, String, Vec<String>)` and adding two more members would have made every call site a
/// five-element positional puzzle in which two adjacent `String`s mean entirely different things —
/// exactly the shape where an argument-order mistake compiles.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct FetchedPage {
    pub status: u16,
    pub body: String,
    pub sitemaps: Vec<String>,
    pub etag: String,
    pub last_modified: String,
}

/// A response header as an owned String, empty when absent or not valid UTF-8.
fn header_string(response: &reqwest::Response, name: &str) -> String {
    response
        .headers()
        .get(name)
        .and_then(|v| v.to_str().ok())
        .unwrap_or_default()
        .to_string()
}

/// What one sitemap walk found, and what it deliberately did not ask for.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct SitemapHarvest {
    /// Page URLs the shop lists, de-duplicated.
    pub urls: Vec<String>,
    pub documents_fetched: u32,
    pub bytes_read: u64,
    /// Documents not fetched, each with the reason. Reported rather than dropped so that "we found
    /// nothing" can be told apart from "we declined to look" — which is the difference between a
    /// shop with no events page and a shop whose catalogue we refused to download.
    pub skipped: Vec<String>,
    /// The budget or a backoff ended the walk early, so `urls` may be incomplete. A partial result
    /// silently presented as complete is how a shop gets recorded as having no events page.
    pub truncated: bool,
}

/// One step of the walk.
enum HarvestStep {
    Read {
        bytes: u64,
        doc: sitemap::SitemapDoc,
        /// The byte cap cut this document short, so its `locs` are incomplete.
        hung_up: bool,
    },
    Skipped(String),
    /// End the whole walk — budget spent, or the shop asked us to back off.
    Stop,
}

/// Pull the next document to fetch: everything known-worthwhile first, unlabelled leftovers after.
fn next_target(queue: &mut Vec<String>, deferred: &mut Vec<String>) -> Option<String> {
    if !queue.is_empty() {
        return Some(queue.remove(0));
    }
    if !deferred.is_empty() {
        return Some(deferred.remove(0));
    }
    None
}

/// The path part of `url`, but **only if `url` is on `domain`**.
///
/// `None` means refuse. robots.txt is attacker-controlled input as far as this service goes: a
/// `Sitemap:` line naming another host would otherwise send our requests there while the robots
/// check and rate limit still applied to the configured domain — the compliant egress turned into an
/// open proxy, which is the exact hole `/fetch` guards against for its `path` parameter.
fn path_within(url: &str, domain: &str) -> Option<String> {
    let rest = url.strip_prefix(domain)?;

    match rest {
        "" => Some("/".to_string()),
        r if r.starts_with('/') => Some(r.to_string()),
        // `https://shop.test.evil.com/...` starts with `https://shop.test` as a *string* while being
        // an entirely different host. The boundary check is the whole guard.
        _ => None,
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
    /// Pre-loaded `(status, body)` keyed by **URL**, for mock-mode `fetch_capped`. Keyed by URL
    /// rather than store because a sitemap walk fetches several distinct documents per store.
    http_fixtures: HashMap<String, (u16, String)>,
    /// What mock-mode robots.txt declares under `Sitemap:`. Stated explicitly by a test rather than
    /// defaulted, because "which sitemaps did the shop declare" is the input the walk turns on — a
    /// convenient default would let a test pass without saying what it was testing.
    mock_sitemaps: Vec<String>,
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
        // One limiter, shared with the robots checker. A 429 on `/robots.txt` must pace our *page*
        // requests too — it is the same shop, and it is behind the same bot-protection front that
        // issued it. Two independent limiters would let a domain that had just refused robots.txt
        // keep taking page requests at full configured rate.
        let rate_limiter = RateLimiter::new();
        Ok(Self {
            robots: RobotsChecker::new(client.clone(), rate_limiter.clone()),
            client,
            rate_limiter,
            fixtures: HashMap::new(),
            http_fixtures: HashMap::new(),
            mock_sitemaps: Vec::new(),
            mock: false,
            capabilities: dashmap::DashMap::new(),
            indexes: dashmap::DashMap::new(),
        })
    }

    /// Create an engine serving `(status, body)` per URL — for exercising the sitemap walk.
    #[cfg(test)]
    pub fn new_mock_http(
        http_fixtures: HashMap<String, (u16, String)>,
        declared_sitemaps: Vec<String>,
    ) -> Self {
        let mut engine = Self::new_mock(HashMap::new());
        engine.http_fixtures = http_fixtures;
        engine.mock_sitemaps = declared_sitemaps;
        engine
    }

    /// Create an engine that serves HTML from a pre-loaded fixture map.
    #[cfg(test)]
    pub fn new_mock(fixtures: HashMap<String, String>) -> Self {
        // Mock engine never makes real HTTP requests; use a minimal client for RobotsChecker API compat.
        let client = reqwest::Client::new();
        let rate_limiter = RateLimiter::new();
        Self {
            robots: RobotsChecker::new(client.clone(), rate_limiter.clone()),
            client,
            rate_limiter,
            fixtures,
            http_fixtures: HashMap::new(),
            mock_sitemaps: Vec::new(),
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
            crate::robots::RobotsPolicy::unrestricted()
        } else {
            // Normalise the base URL before stripping so a trailing slash doesn't
            // cause strip_prefix to fail (e.g. "https://store.com/" vs "/search?q=…").
            let base = config.source.url.trim_end_matches('/');
            let path = search_url.strip_prefix(base).ok_or_else(|| {
                ScraperError::InvalidConfig(format!(
                    "search URL '{search_url}' does not begin with source URL '{base}'"
                ))
            })?;
            self.robots
                .policy(
                    &config.source.url,
                    path,
                    config.rate_limit.retry_after_seconds,
                )
                .await?
        };

        if !policy.allowed {
            // Stop here. Per the owner's rule the store's configuration stays in
            // place, so if the disallow is ever lifted this simply starts working
            // again — we do not fall back to another path or another tier.
            return Err(ScraperError::RobotsDisallowed {
                url: search_url.clone(),
                rule: policy.blocked_by.clone().unwrap_or_default(),
                sitemaps: policy.sitemaps.clone(),
            });
        }

        // A declared `Crawl-delay` wins whenever it is stricter than our own
        // configured rate. Previously it was parsed and discarded on the grounds
        // that the TOML's `requests_per_minute` was authoritative — but that let a
        // config out-request what the site asked for. Exclusive Books declares
        // `Crawl-delay: 10`, i.e. 6 req/min, while its TOML asks for 10.
        let effective_rpm = effective_rpm(&policy, config.rate_limit.requests_per_minute);

        self.rate_limiter.check_and_record(&domain, effective_rpm)?;

        let html = self.fetch_html(store_id, &search_url, config).await?;
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
        product_path: Option<&str>,
    ) -> Result<PriceResult, ScraperError> {
        let capability = self.capability_for(store_id, config).await?;

        match capability.price_source {
            // A supplied path still needs the platform parser, so it takes priority
            // over the legacy fallback even where no product API was detected.
            PriceSource::None if product_path.is_none() => {
                self.scrape(isbn, store_id, config).await
            }

            _ => {
                self.scrape_via_platform(isbn, store_id, config, &capability, product_path)
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
        product_path: Option<&str>,
    ) -> Result<PriceResult, ScraperError> {
        // A caller-supplied path short-circuits ISBN resolution entirely. This is the
        // only way to price the two shops that carry no ISBN on any product: the
        // caller matched a title against its own catalogue and is telling us where to
        // look. We do not second-guess it — the match was made with information this
        // service does not have.
        if let Some(path) = product_path {
            // No validators: this is a price lookup, and a stale price is worse than a redundant
            // transfer. Conditional requests are for pages we re-read on a schedule and expect to be
            // unchanged, which a product's price emphatically is not.
            let page = self
                .fetch_path(config, &format!("{path}.js"), Validators::default())
                .await?;
            let body = page.body;

            return match page.status {
                200 => {
                    let price = platform::shopify_product_js(&body, config.currency())?;
                    Ok(price_result(isbn, store_id, config, price))
                }
                404 => Err(ScraperError::NotStocked {
                    store: store_id.to_string(),
                    isbn: isbn.to_string(),
                }),
                other => Err(ScraperError::PriceParse(format!(
                    "unexpected HTTP {other} from {path}.js"
                ))),
            };
        }

        let price = match (capability.price_source, capability.lookup_mode) {
            // The handle *is* the ISBN, so one request addresses the product and a
            // 404 is the store telling us it does not carry this edition.
            (PriceSource::ShopifyProductsJson, LookupMode::Direct) => {
                let page = self
                    .fetch_path(
                        config,
                        &format!("/products/{isbn}.js"),
                        Validators::default(),
                    )
                    .await?;
                let (status, body) = (page.status, page.body);

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
                let page = self
                    .fetch_path(
                        config,
                        &format!("/wp-json/wc/store/v1/products?search={isbn}"),
                        Validators::default(),
                    )
                    .await?;
                let (status, body) = (page.status, page.body);

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
                        let page = self
                            .fetch_path(config, &format!("{path}.js"), Validators::default())
                            .await?;
                        let (status, body) = (page.status, page.body);

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

        Ok(price_result(isbn, store_id, config, price))
    }

    /// List products that carry no extractable ISBN, with their titles.
    ///
    /// The residual for shops where no ISBN appears on any product, so title matching
    /// is the only path. Returns paths and titles only — the caller matches against
    /// its own catalogue and keeps just the pointer, so no copy of the shop's
    /// catalogue exists anywhere.
    pub async fn catalogue_titles(
        &self,
        config: &ScraperConfig,
    ) -> Result<Vec<(String, String)>, ScraperError> {
        let mut out = Vec::new();

        for page in 1..=MAX_INDEX_PAGES {
            let path = format!("/products.json?limit=250&page={page}");

            // Bulk sweep: waits on the rate limit rather than failing, as the index
            // build does and for the same reason.
            let page_result = loop {
                match self.fetch_path(config, &path, Validators::default()).await {
                    Ok(response) => break response,
                    Err(ScraperError::RateLimitExceeded { .. }) => {
                        tokio::time::sleep(std::time::Duration::from_secs(RATE_LIMIT_BACKOFF_SECS))
                            .await;
                    }
                    Err(e) => return Err(e),
                }
            };
            let (status, body) = (page_result.status, page_result.body);

            if status != 200 {
                break;
            }

            let listings = platform::shopify_products_json(&body)?;

            if listings.is_empty() {
                break;
            }

            out.extend(platform::unmatched_titles(&listings));

            if listings.len() != 250 {
                break;
            }
        }

        Ok(out)
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
            let page_result = loop {
                match self.fetch_path(config, &path, Validators::default()).await {
                    Ok(response) => break response,
                    Err(ScraperError::RateLimitExceeded { .. }) => {
                        tokio::time::sleep(std::time::Duration::from_secs(RATE_LIMIT_BACKOFF_SECS))
                            .await;
                    }
                    Err(e) => return Err(e),
                }
            };
            let (status, body) = (page_result.status, page_result.body);

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
        let shopify = self
            .fetch_path(config, "/products.json?limit=50", Validators::default())
            .await?;
        let (shopify_status, shopify_body) = (shopify.status, shopify.body);

        if shopify_status == 200 {
            if let Ok(listings) = platform::shopify_products_json(&shopify_body) {
                if !listings.is_empty() {
                    return Ok(platform::classify_shopify(&listings));
                }
            }
        }

        let woo = self
            .fetch_path(
                config,
                "/wp-json/wc/store/v1/products?per_page=30",
                Validators::default(),
            )
            .await?;
        let (woo_status, woo_body) = (woo.status, woo.body);

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
    /// Fetch one path through the compliant egress.
    ///
    /// Returns the status, the body, and the **`Sitemap:` URLs the shop declared** — the last of
    /// which is free: robots.txt is already fetched here for compliance, so the declaration is
    /// in hand. Returning it is what lets a caller find a real page instead of guessing at one,
    /// and a guess is not cheap for the shop (a Shopify 404 is a *styled* page — measured at
    /// 249,540 bytes — while a sitemap index is ~10 KB).
    pub async fn fetch_path(
        &self,
        config: &ScraperConfig,
        path: &str,
        validators: Validators,
    ) -> Result<FetchedPage, ScraperError> {
        let base = config.source.url.trim_end_matches('/');
        let url = format!("{base}{path}");
        let domain =
            extract_domain(&config.source.url).unwrap_or_else(|| config.source.url.clone());

        // robots.txt first, then the rate limit — see `scrape` for why that order
        // matters and why there is no flag to skip it.
        let policy = if self.mock {
            crate::robots::RobotsPolicy::unrestricted()
        } else {
            self.robots
                .policy(
                    &config.source.url,
                    path,
                    config.rate_limit.retry_after_seconds,
                )
                .await?
        };

        if !policy.allowed {
            return Err(ScraperError::RobotsDisallowed {
                url,
                rule: policy.blocked_by.clone().unwrap_or_default(),
                sitemaps: policy.sitemaps.clone(),
            });
        }

        let effective_rpm = effective_rpm(&policy, config.rate_limit.requests_per_minute);

        self.rate_limiter.check_and_record(&domain, effective_rpm)?;

        let mut request = self.client.get(&url);

        // Conditional headers, when the caller has validators from last time. This is the cheapest
        // courtesy available: the shop answers 304 with no body instead of rendering and transmitting
        // a page we already hold.
        //
        // Sent exactly as received. An ETag is an opaque byte string — weak (`W/"..."`), quoted, or
        // whatever the origin chose — so any normalisation here would make it stop matching, and the
        // failure is invisible: everything keeps working, just at full cost.
        if !validators.if_none_match.is_empty() {
            request = request.header("if-none-match", &validators.if_none_match);
        }
        if !validators.if_modified_since.is_empty() {
            request = request.header("if-modified-since", &validators.if_modified_since);
        }

        let response = request.send().await.map_err(ScraperError::Http)?;

        let status = response.status().as_u16();
        let etag = header_string(&response, "etag");
        let last_modified = header_string(&response, "last-modified");

        // Before the body, and that order matters: a 429 body is a styled challenge page (9 KB from
        // both target shops) and reading it would both cost the transfer and hand a caller something
        // that parses cleanly and means nothing.
        if let Some(err) = self.note_pacing(
            &domain,
            status,
            response
                .headers()
                .get("retry-after")
                .and_then(|v| v.to_str().ok()),
            config.rate_limit.retry_after_seconds,
        ) {
            return Err(err);
        }

        // 304 carries no body by definition, and asking for one would be reading a body the origin
        // deliberately did not send. Returned with the validators echoed so a caller can refresh them
        // if the origin rotated them alongside a 304.
        if status == 304 {
            return Ok(FetchedPage {
                status,
                body: String::new(),
                sitemaps: policy.sitemaps,
                etag: if etag.is_empty() {
                    validators.if_none_match
                } else {
                    etag
                },
                last_modified: if last_modified.is_empty() {
                    validators.if_modified_since
                } else {
                    last_modified
                },
            });
        }

        let body = response.text().await.map_err(ScraperError::Http)?;

        Ok(FetchedPage {
            status,
            body,
            sitemaps: policy.sitemaps,
            etag,
            last_modified,
        })
    }

    /// Enumerate a shop's pages from its own sitemap, instead of guessing at paths.
    ///
    /// The polite alternative to path-guessing, and cheaper for both sides — see the `sitemap`
    /// module docs for the measured comparison. Every request here goes through the same robots
    /// check, rate limiter and pacing observation as any other, plus a `CrawlBudget` that bounds
    /// what one discovery run can cost the shop in **requests and bytes**.
    ///
    /// The walk: robots.txt has already told us where the index is → fetch it → if it is an index,
    /// fetch only the children that name themselves as *pages*, never products or collections →
    /// return the page URLs. `skipped` reports the children we deliberately did not ask for, so the
    /// politeness decision is observable rather than implicit.
    pub async fn sitemap_urls(
        &self,
        config: &ScraperConfig,
    ) -> Result<SitemapHarvest, ScraperError> {
        self.sitemap_urls_with_budget(config, CrawlBudget::for_discovery())
            .await
    }

    /// As `sitemap_urls`, with the budget supplied.
    ///
    /// A parameter so budget *exhaustion* can be driven by a tiny cap rather than a multi-megabyte
    /// fixture. Production always calls `sitemap_urls`, which supplies `for_discovery()` — the budget
    /// is not a per-caller knob and callers do not get to raise it.
    pub async fn sitemap_urls_with_budget(
        &self,
        config: &ScraperConfig,
        mut budget: CrawlBudget,
    ) -> Result<SitemapHarvest, ScraperError> {
        let base = config.source.url.trim_end_matches('/').to_string();
        let domain = extract_domain(&config.source.url).unwrap_or_else(|| base.clone());
        let mut harvest = SitemapHarvest::default();

        // robots.txt is read for compliance anyway, and it is what declares the index. Permission is
        // checked for the sitemap path itself, not for "/" — a shop may disallow one and not the
        // other, and assuming otherwise is how a compliance check becomes decorative.
        let policy = self.policy_for(&base, "/robots.txt", config).await?;

        if policy.sitemaps.is_empty() {
            return Ok(harvest);
        }

        // Every declared index, then every page-type child of each. `Unlabelled` children are
        // deferred to the end of the queue: whatever budget remains goes to the children we *know*
        // are worth reading before the ones we are merely unsure about.
        let mut queue: Vec<String> = policy.sitemaps.clone();
        let mut deferred: Vec<String> = Vec::new();
        let mut seen: Vec<String> = Vec::new();

        while let Some(url) = next_target(&mut queue, &mut deferred) {
            if seen.contains(&url) {
                continue;
            }
            seen.push(url.clone());

            // ⚠️ Cross-host sitemaps are refused, not followed. robots.txt is attacker-controlled
            // input as far as this service is concerned — a `Sitemap:` line naming another host would
            // otherwise steer our egress at it while the robots check and rate limit still applied to
            // the *configured* domain. The same hole `/fetch` guards against for `path`.
            let Some(path) = path_within(&url, &domain) else {
                harvest.skipped.push(format!("{url} (not on {domain})"));
                continue;
            };

            match self
                .harvest_one(config, &domain, &path, &url, &mut budget)
                .await
            {
                HarvestStep::Stop => {
                    harvest.truncated = true;
                    break;
                }
                HarvestStep::Skipped(why) => harvest.skipped.push(why),
                HarvestStep::Read {
                    bytes,
                    doc,
                    hung_up,
                } => {
                    harvest.documents_fetched += 1;
                    harvest.bytes_read += bytes;

                    // A document we only partly read cannot yield a complete answer, whether or not
                    // the walk later runs out of requests.
                    if hung_up {
                        harvest.truncated = true;
                    }

                    match doc.kind {
                        sitemap::DocKind::Index => {
                            for child in doc.locs {
                                match sitemap::classify_child(&child) {
                                    sitemap::ChildKind::Page => queue.push(child),
                                    sitemap::ChildKind::Unlabelled => deferred.push(child),
                                    sitemap::ChildKind::Excluded => harvest
                                        .skipped
                                        .push(format!("{child} (catalogue-sized, not pages)")),
                                }
                            }
                        }
                        sitemap::DocKind::UrlSet => {
                            for page in doc.locs {
                                if !harvest.urls.contains(&page) {
                                    harvest.urls.push(page);
                                }
                            }
                        }
                        // Not a sitemap at all — a challenge page, an HTML 404, a redirect body.
                        // Recorded rather than treated as "this shop has no pages", which is a false
                        // negative that would never be revisited.
                        sitemap::DocKind::Unknown => harvest
                            .skipped
                            .push(format!("{url} (response was not a sitemap)")),
                    }
                }
            }
        }

        Ok(harvest)
    }

    /// One document of the walk: budget, robots, rate limit, fetch, parse.
    async fn harvest_one(
        &self,
        config: &ScraperConfig,
        domain: &str,
        path: &str,
        url: &str,
        budget: &mut CrawlBudget,
    ) -> HarvestStep {
        // The budget is asked FIRST, and it is what yields the byte ceiling — so there is no way to
        // reach the fetch below without having been given an allowance for it.
        let byte_limit = match budget.spend() {
            Spend::Allowed { byte_limit } => byte_limit,
            Spend::Exhausted => return HarvestStep::Stop,
        };

        // The match YIELDS the spacing rather than assigning into a pre-declared binding: every other
        // arm returns, so an initial value would be dead code.
        let spacing = match self.policy_for(domain, path, config).await {
            Ok(policy) if !policy.allowed => {
                return HarvestStep::Skipped(format!(
                    "{url} ({})",
                    policy.blocked_by.unwrap_or_else(|| "disallowed".into())
                ));
            }
            Ok(policy) => {
                let rpm = effective_rpm(&policy, config.rate_limit.requests_per_minute);
                if let Err(e) = self.rate_limiter.check_and_record(domain, rpm) {
                    // Includes a cooldown the shop asked for. Stopping the whole walk rather than
                    // skipping this one document is the point: the next fetch would be refused too,
                    // and a walk that keeps asking during a backoff is not a polite walk.
                    tracing::info!("sitemap walk stopping at {}: {}", url, e);
                    return HarvestStep::Stop;
                }
                document_spacing(&policy, rpm)
            }
            Err(e) => {
                tracing::info!("sitemap walk stopping at {}: {}", url, e);
                return HarvestStep::Stop;
            }
        };

        tokio::time::sleep(spacing).await;

        match self.fetch_capped(url, byte_limit).await {
            Ok(read) => {
                budget.charge_bytes(read.bytes);

                // Only a 2xx body is parsed. A 404 is data about the shop; a 429 is a challenge page
                // that would parse cleanly and mean nothing.
                if !(200..300).contains(&read.status) {
                    return HarvestStep::Skipped(format!("{url} (HTTP {})", read.status));
                }
                HarvestStep::Read {
                    bytes: read.bytes,
                    doc: sitemap::parse(&read.body),
                    hung_up: read.hung_up,
                }
            }
            Err(e) => {
                tracing::warn!("sitemap fetch failed for {}: {}", url, e);
                HarvestStep::Skipped(format!("{url} ({e})"))
            }
        }
    }

    /// GET a URL, reading at most `byte_limit` bytes of the body.
    ///
    /// Streamed chunk by chunk rather than `response.text()`, because `text()` reads whatever the
    /// server sends — and the documents this guards against are exactly the ones that are too big.
    /// A cap enforced after the transfer is not a cap; the shop has already paid for it.
    ///
    /// Returns the bytes actually transferred, so the budget is charged for what happened rather
    /// than for what was permitted. The body may be truncated mid-element; `sitemap::parse` is built
    /// to return what it had rather than fail, and there is a test for that shape.
    async fn fetch_capped(&self, url: &str, byte_limit: u64) -> Result<CappedBody, ScraperError> {
        // Mock mode serves documents from `http_fixtures`, keyed by URL. This is the seam that makes
        // the *assembly* of the walk testable — queue refill, budget threading, `Stop` propagation —
        // rather than only its pieces. The cap applies to fixtures too, so budget exhaustion is
        // drivable without a huge fixture.
        if self.mock {
            let (status, body) = self
                .http_fixtures
                .get(url)
                .cloned()
                .unwrap_or((404, String::new()));

            let capped: Vec<u8> = body.bytes().take(byte_limit as usize).collect();
            let hung_up = capped.len() < body.len();

            return Ok(CappedBody {
                status,
                bytes: capped.len() as u64,
                body: String::from_utf8_lossy(&capped).into_owned(),
                hung_up,
            });
        }

        let mut response = self
            .client
            .get(url)
            .send()
            .await
            .map_err(ScraperError::Http)?;

        let status = response.status().as_u16();
        let mut body = Vec::new();
        let mut hung_up = false;

        while let Some(chunk) = response.chunk().await.map_err(ScraperError::Http)? {
            body.extend_from_slice(&chunk);
            if body.len() as u64 >= byte_limit {
                hung_up = true;
                tracing::info!(
                    "hung up on {} at {} bytes (budget {})",
                    url,
                    body.len(),
                    byte_limit
                );
                break;
            }
        }

        // Lossy rather than an error: a sitemap is XML and should be UTF-8, but a body truncated
        // mid-codepoint by the cap above is normal, not a defect worth failing the walk over.
        Ok(CappedBody {
            status,
            bytes: body.len() as u64,
            body: String::from_utf8_lossy(&body).into_owned(),
            hung_up,
        })
    }

    /// robots.txt policy for a path, honouring mock mode.
    ///
    /// ⚠️ Extracted because two call sites had the `if self.mock` guard and **two did not**:
    /// `sitemap_urls` and `harvest_one` went straight to `RobotsChecker`, so `Engine::new_mock` —
    /// whose entire contract is "never touches the network" — would have issued live requests for
    /// robots.txt. That is a broken guarantee, and it is also why the sitemap walk had no test at
    /// all: it could not be run without a network.
    ///
    /// A guard each new egress path must remember is a guard that will be forgotten. One way to ask.
    async fn policy_for(
        &self,
        base_url: &str,
        path: &str,
        config: &ScraperConfig,
    ) -> Result<crate::robots::RobotsPolicy, ScraperError> {
        if self.mock {
            return Ok(crate::robots::RobotsPolicy {
                sitemaps: self.mock_sitemaps.clone(),
                ..crate::robots::RobotsPolicy::unrestricted()
            });
        }

        self.robots
            .policy(base_url, path, config.rate_limit.retry_after_seconds)
            .await
    }

    /// Turn a pacing response into the determination it is, recording the cooldown on the way.
    ///
    /// Returns `Some(err)` when the shop is telling us to wait — 429, or a 503 (which for a shop
    /// behind bot protection is usually the same message in a different envelope).
    ///
    /// Takes the status and header **by value rather than a `&Response`** so the decision is
    /// unit-testable without a network or a mock HTTP server — the same reason `classify_status` was
    /// split out of the robots fetch. Every egress path in this file routes through it, which is
    /// what makes honouring the signal a property of the service rather than of whoever remembered.
    fn note_pacing(
        &self,
        domain: &str,
        status: u16,
        retry_after: Option<&str>,
        default_retry_after_secs: u64,
    ) -> Option<ScraperError> {
        if !matches!(status, 429 | 503) {
            return None;
        }

        let wait = RateLimiter::retry_after(retry_after, default_retry_after_secs);
        self.rate_limiter.back_off(domain, Instant::now() + wait);

        tracing::info!(
            "{} answered {}; backing off {}s",
            domain,
            status,
            wait.as_secs()
        );

        Some(ScraperError::UpstreamBackoff {
            domain: domain.to_string(),
            seconds_remaining: wait.as_secs(),
        })
    }

    /// Fetch HTML — either from fixtures (mock mode) or real HTTP.
    async fn fetch_html(
        &self,
        store_id: &str,
        url: &str,
        config: &ScraperConfig,
    ) -> Result<String, ScraperError> {
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

        // Pacing is checked before `error_for_status`, because that call would fold a 429 into a
        // generic `ScraperError::Http` — which `outcome_for_error` classifies as a *failure*, and a
        // failure melts the fuse shared by every store. So a single shop pacing us used to take
        // price scraping down everywhere, repeatedly, since a 429 recurs on every attempt.
        let domain =
            extract_domain(&config.source.url).unwrap_or_else(|| config.source.url.clone());
        if let Some(err) = self.note_pacing(
            &domain,
            response.status().as_u16(),
            response
                .headers()
                .get("retry-after")
                .and_then(|v| v.to_str().ok()),
            config.rate_limit.retry_after_seconds,
        ) {
            return Err(err);
        }

        // Surface remaining HTTP 4xx/5xx as errors so they don't silently produce empty results.
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

    // ------------------------------------------------------------------
    // Pacing — the shop's 429 reaching our limiter
    // ------------------------------------------------------------------

    #[test]
    fn a_429_records_a_cooldown_the_next_request_actually_observes() {
        // The end-to-end wiring assertion, and the one worth having: it is not enough for
        // `note_pacing` to *return* the determination. It has to write the cooldown into the very
        // limiter the next egress consults, under the very same key. A mismatched domain key here
        // would leave every test passing and the backoff a silent no-op — this project's dominant
        // defect class.
        let engine = Engine::new_mock(HashMap::new());
        let config = exclusive_books_config();
        let domain = extract_domain(&config.source.url).unwrap();

        // Nothing is in force to begin with, so a refusal below cannot be a pre-existing condition.
        assert!(
            engine.rate_limiter.check_and_record(&domain, 10).is_ok(),
            "the domain was already paced before the 429 — the test would pass vacuously"
        );

        let err = engine
            .note_pacing(&domain, 429, Some("120"), 60)
            .expect("a 429 was not recognised as the shop pacing us");
        assert!(matches!(err, ScraperError::UpstreamBackoff { .. }));

        match engine.rate_limiter.check_and_record(&domain, 10) {
            Err(ScraperError::UpstreamBackoff {
                seconds_remaining, ..
            }) => assert!(
                (110..=120).contains(&seconds_remaining),
                "the cooldown was recorded but not for the 120s asked for: {seconds_remaining}s"
            ),
            other => panic!("the 429 left no cooldown the next request could see: {other:?}"),
        }
    }

    // ------------------------------------------------------------------
    // The sitemap walk's own two decisions
    // ------------------------------------------------------------------

    // ------------------------------------------------------------------
    // The sitemap walk, END TO END — the assembly, not its pieces
    // ------------------------------------------------------------------
    //
    // ⛔ Every piece of `sitemap_urls` was unit-tested and the loop joining them had **never run
    // once**: queue refill from a parsed index, budget threading, robots/rate-limit ordering, and
    // `Stop` becoming `truncated`. That is exactly the defect #307 exists to fix — stages that each
    // pass while the chain does nothing — reproduced one layer above it.
    //
    // These run through `Engine::new_mock_http`, which serves `(status, body)` per URL, so the whole
    // walk executes with no network.

    fn walk_engine(pairs: Vec<(&str, u16, &str)>, declared: &[&str]) -> Engine {
        Engine::new_mock_http(
            pairs
                .into_iter()
                .map(|(url, status, body)| (url.to_string(), (status, body.to_string())))
                .collect(),
            declared.iter().map(|s| s.to_string()).collect(),
        )
    }

    fn walk_config() -> ScraperConfig {
        ScraperConfig::from_toml_str(
            r#"
[source]
name = "Walk Test"
country = "ZA"
url = "https://shop.test"

[search]
method = "GET"
path = "/search"
query_param = "q"
query_template = "{isbn}"

[selectors]
price = ".price"
currency = "ZAR"

[rate_limit]
requests_per_minute = 60
"#,
        )
        .unwrap()
    }

    const INDEX: &str = r#"<sitemapindex>
        <sitemap><loc>https://shop.test/sitemap_pages_1.xml</loc></sitemap>
        <sitemap><loc>https://shop.test/sitemap_products_1.xml</loc></sitemap>
      </sitemapindex>"#;

    const PAGES: &str = r#"<urlset>
        <url><loc>https://shop.test/pages/events</loc></url>
        <url><loc>https://shop.test/pages/about</loc></url>
      </urlset>"#;

    #[test]
    fn a_declared_crawl_delay_spaces_the_walk_rather_than_only_rate_limiting_it() {
        // ⛔ `Crawl-delay` is a SPACING and we honoured only the rate. `effective_rpm` turns
        // `Crawl-delay: 10` into 6/min, and `check_and_record`'s sliding *window* permits all six
        // inside two seconds — which passes the limiter while doing exactly what the shop asked us not
        // to. Measured against the real file: exclusivebooks.co.za declares `Crawl-delay: 10`, and a
        // four-document walk at the old fixed 500 ms would have burst all four at it in under 2s.
        //
        // `RateLimiter::min_delay` already existed with tests and was called by NO production code.
        let asks_for_ten = crate::robots::RobotsPolicy {
            crawl_delay_secs: Some(10),
            ..crate::robots::RobotsPolicy::unrestricted()
        };
        assert_eq!(
            document_spacing(&asks_for_ten, 6),
            std::time::Duration::from_secs(10),
            "a declared Crawl-delay was not honoured as spacing between documents"
        );

        // No declared delay: the spacing implied by our own rate, never below the courtesy floor.
        // 60/min is one second apart, which already exceeds the 500 ms floor — so the floor only binds
        // for rates above 120/min, which no store config sets.
        let silent = crate::robots::RobotsPolicy::unrestricted();
        assert_eq!(
            document_spacing(&silent, 60),
            std::time::Duration::from_secs(1)
        );
        assert!(
            document_spacing(&silent, 600) >= sitemap::INTER_DOCUMENT_DELAY,
            "a high configured rate must not drop the spacing below our own floor"
        );

        // A very low rate implies wide spacing even with no Crawl-delay line — 1/min is 60s apart.
        assert_eq!(
            document_spacing(&silent, 1),
            std::time::Duration::from_secs(60)
        );

        // Never SHORTER than what the shop asked for, whatever our own numbers say.
        let asks_for_thirty = crate::robots::RobotsPolicy {
            crawl_delay_secs: Some(30),
            ..crate::robots::RobotsPolicy::unrestricted()
        };
        assert!(
            document_spacing(&asks_for_thirty, 600) >= std::time::Duration::from_secs(30),
            "our configured rate was allowed to talk the shop down from its declared delay"
        );
    }

    #[tokio::test]
    async fn the_walk_follows_an_index_to_its_page_child_and_refuses_the_catalogue() {
        // The whole feature in one assertion: index → page child → URLs, catalogue never requested.
        // A broken queue refill leaves the page child unread; a bypassed classification fetches the
        // catalogue.
        let engine = walk_engine(
            vec![
                ("https://shop.test/sitemap.xml", 200, INDEX),
                ("https://shop.test/sitemap_pages_1.xml", 200, PAGES),
                ("https://shop.test/sitemap_products_1.xml", 200, "<urlset/>"),
            ],
            &["https://shop.test/sitemap.xml"],
        );

        let mut harvest = engine.sitemap_urls(&walk_config()).await.unwrap();
        harvest.urls.sort();

        assert_eq!(
            harvest.urls,
            vec![
                "https://shop.test/pages/about",
                "https://shop.test/pages/events"
            ],
            "the index was fetched but its page child was never followed"
        );
        assert_eq!(harvest.documents_fetched, 2);
        assert!(
            harvest
                .skipped
                .iter()
                .any(|s| s.contains("sitemap_products_1.xml")),
            "the catalogue child was not reported as skipped: {:?}",
            harvest.skipped
        );
        assert!(!harvest.truncated);
        assert!(harvest.bytes_read > 0, "no bytes charged for two documents");
    }

    #[tokio::test]
    async fn an_exhausted_budget_reports_truncated_rather_than_looking_complete() {
        // ⛔ `truncated` was set in the code and asserted nowhere, and writing this test found a real
        // defect: a byte cap that cut a document short did NOT set it. The index was truncated
        // mid-`<loc>`, parsed to zero children, and the walk ended *normally* — reporting a complete
        // result for a document it had only partly read.
        let engine = walk_engine(
            vec![
                ("https://shop.test/sitemap.xml", 200, INDEX),
                ("https://shop.test/sitemap_pages_1.xml", 200, PAGES),
            ],
            &["https://shop.test/sitemap.xml"],
        );

        let harvest = engine
            .sitemap_urls_with_budget(&walk_config(), CrawlBudget::new(1, 64))
            .await
            .unwrap();

        assert!(
            harvest.truncated,
            "the walk read a partial document but reported a complete result"
        );
        assert_eq!(harvest.documents_fetched, 1);
    }

    #[tokio::test]
    async fn a_cross_host_sitemap_line_is_skipped_by_the_walk_itself() {
        // `path_within` is unit-tested; this proves the WALK consults it. A guard that exists and is
        // never called is the same as no guard.
        let engine = walk_engine(
            vec![(
                "https://evil.test/sitemap.xml",
                200,
                "<urlset><url><loc>https://evil.test/x</loc></url></urlset>",
            )],
            &["https://evil.test/sitemap.xml"],
        );

        let harvest = engine.sitemap_urls(&walk_config()).await.unwrap();

        assert!(
            harvest.urls.is_empty(),
            "a sitemap on another host was followed: {:?}",
            harvest.urls
        );
        assert!(
            harvest.skipped.iter().any(|s| s.contains("not on")),
            "the refusal was not reported: {:?}",
            harvest.skipped
        );
    }

    #[tokio::test]
    async fn a_response_that_is_not_a_sitemap_is_reported_not_treated_as_empty() {
        // The 429 bot-challenge case, end to end. Reporting it as "the shop lists no pages" is the
        // false negative that never re-checks.
        let engine = walk_engine(
            vec![(
                "https://shop.test/sitemap.xml",
                200,
                "<!DOCTYPE html><html><title>Verifying your connection...</title></html>",
            )],
            &["https://shop.test/sitemap.xml"],
        );

        let harvest = engine.sitemap_urls(&walk_config()).await.unwrap();

        assert!(harvest.urls.is_empty());
        assert!(
            harvest.skipped.iter().any(|s| s.contains("not a sitemap")),
            "a challenge page was counted as a sitemap listing nothing: {:?}",
            harvest.skipped
        );
    }

    #[tokio::test]
    async fn a_non_2xx_child_is_skipped_rather_than_parsed() {
        let engine = walk_engine(
            vec![
                ("https://shop.test/sitemap.xml", 200, INDEX),
                ("https://shop.test/sitemap_pages_1.xml", 503, "server error"),
            ],
            &["https://shop.test/sitemap.xml"],
        );

        let harvest = engine.sitemap_urls(&walk_config()).await.unwrap();

        assert!(harvest.urls.is_empty());
        assert!(
            harvest.skipped.iter().any(|s| s.contains("HTTP 503")),
            "a 503 body was parsed as a sitemap: {:?}",
            harvest.skipped
        );
    }

    #[test]
    fn a_sitemap_on_another_host_is_refused_not_followed() {
        // ⛔ robots.txt is attacker-controlled input as far as this service is concerned. A
        // `Sitemap:` line naming another host would send our requests there while the robots check
        // and rate limit still applied to the CONFIGURED domain — the compliant egress turned into an
        // open proxy. `/fetch` already guards its `path` parameter against exactly this; the sitemap
        // list is a second door into the same room.
        let domain = "https://shop.test";

        assert_eq!(
            path_within("https://shop.test/sitemap.xml", domain),
            Some("/sitemap.xml".to_string())
        );
        assert_eq!(
            path_within("https://shop.test", domain),
            Some("/".to_string())
        );

        for hostile in [
            // The prefix-match trap: a string that begins with the domain and is a different host.
            "https://shop.test.evil.com/sitemap.xml",
            "https://shop.testevil.com/sitemap.xml",
            "https://evil.com/sitemap.xml",
            // Scheme downgrade is a different origin too.
            "http://shop.test/sitemap.xml",
        ] {
            assert_eq!(
                path_within(hostile, domain),
                None,
                "our egress would have been steered at: {hostile}"
            );
        }
    }

    #[test]
    fn known_page_sitemaps_are_read_before_unlabelled_ones() {
        // The budget is finite, so ordering IS allocation: spending the last request on a sitemap we
        // merely could not classify, while a known pages sitemap waits, is how a walk comes back
        // empty from a shop that told us exactly where its pages were.
        let mut queue = vec!["pages-a".to_string(), "pages-b".to_string()];
        let mut deferred = vec!["unlabelled".to_string()];

        assert_eq!(
            next_target(&mut queue, &mut deferred).as_deref(),
            Some("pages-a")
        );
        assert_eq!(
            next_target(&mut queue, &mut deferred).as_deref(),
            Some("pages-b")
        );
        assert_eq!(
            next_target(&mut queue, &mut deferred).as_deref(),
            Some("unlabelled")
        );
        assert_eq!(next_target(&mut queue, &mut deferred), None);
    }

    #[test]
    fn a_child_queued_mid_walk_still_precedes_the_deferred_ones() {
        // The queue is refilled as an index is parsed, so this is the real shape rather than a
        // static list: a pages child discovered on the second document must still outrank an
        // unlabelled one discovered on the first.
        let mut queue = vec!["index".to_string()];
        let mut deferred = vec!["unlabelled-from-index".to_string()];

        assert_eq!(
            next_target(&mut queue, &mut deferred).as_deref(),
            Some("index")
        );
        queue.push("pages-from-index".to_string());

        assert_eq!(
            next_target(&mut queue, &mut deferred).as_deref(),
            Some("pages-from-index"),
            "an unlabelled leftover was read before a pages child found later in the walk"
        );
    }

    #[test]
    fn an_ordinary_status_is_not_treated_as_pacing() {
        // The other half, without which the test above is satisfied by a function that backs off on
        // everything. A 200 and a 404 are both perfectly ordinary answers.
        let engine = Engine::new_mock(HashMap::new());

        for status in [200, 301, 404, 418, 500] {
            assert!(
                engine
                    .note_pacing("https://example.com", status, Some("120"), 60)
                    .is_none(),
                "HTTP {status} was mistaken for a pacing signal"
            );
        }
        assert!(
            engine
                .rate_limiter
                .check_and_record("https://example.com", 10)
                .is_ok(),
            "an ordinary response left a cooldown behind"
        );
    }

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
