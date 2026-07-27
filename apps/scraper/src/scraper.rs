use crate::config::ScraperConfig;
use crate::error::ScraperError;
use crate::price::{extract_in_stock, extract_price, extract_text};
use crate::rate_limiter::RateLimiter;
use crate::robots::RobotsChecker;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;

/// User-agent string for HTTP requests.
const USER_AGENT: &str = "TheStacksScraper/0.1 (+https://thestacks.app/scraper)";

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
        let effective_rpm = match policy.crawl_delay_secs {
            Some(secs) if secs > 0 => {
                let robots_rpm = (60 / secs).max(1);
                robots_rpm.min(config.rate_limit.requests_per_minute)
            }
            _ => config.rate_limit.requests_per_minute,
        };

        self.rate_limiter.check_and_record(&domain, effective_rpm)?;

        let html = self.fetch_html(store_id, &search_url).await?;
        self.parse_result(isbn, store_id, config, &html, &search_url)
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
