use crate::error::ScraperError;
use serde::{Deserialize, Serialize};
use std::path::Path;

/// Top-level TOML config for a single scraper store.
#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct ScraperConfig {
    pub source: SourceConfig,
    pub search: SearchConfig,
    pub selectors: SelectorsConfig,
    pub rate_limit: RateLimitConfig,
    #[serde(default)]
    pub discovered: Option<DiscoveredConfig>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct SourceConfig {
    pub name: String,
    #[serde(rename = "type", default = "default_type")]
    pub source_type: String,
    pub country: String,
    pub url: String,
    #[serde(default)]
    pub has_physical_location: bool,
    #[serde(default)]
    pub currency: Option<String>,
}

fn default_type() -> String {
    "bookshop".to_string()
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct SearchConfig {
    pub method: String,
    pub path: String,
    pub query_param: String,
    #[serde(default = "default_query_template")]
    pub query_template: String,
}

fn default_query_template() -> String {
    "{isbn}".to_string()
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct SelectorsConfig {
    pub price: String,
    #[serde(default)]
    pub title: Option<String>,
    #[serde(default)]
    pub in_stock: Option<String>,
    /// Currency code e.g. "ZAR". Falls back to source.currency if not set.
    #[serde(default)]
    pub currency: Option<String>,
    /// Optional selector for a canonical product URL on the result page.
    #[serde(default)]
    pub product_url: Option<String>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct RateLimitConfig {
    pub requests_per_minute: u32,
    #[serde(default = "default_retry_after")]
    pub retry_after_seconds: u64,
}

fn default_retry_after() -> u64 {
    60
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct DiscoveredConfig {
    pub discovered_at: String,
    pub discovered_via: String,
    #[serde(default)]
    pub verified_by_human: bool,
}

impl ScraperConfig {
    /// Load and validate a config from a TOML file path.
    pub fn from_file(path: &Path) -> Result<Self, ScraperError> {
        let content = std::fs::read_to_string(path)?;
        let config: ScraperConfig = toml::from_str(&content)?;
        config.validate()?;
        Ok(config)
    }

    /// Load from a TOML string (useful for tests).
    pub fn from_toml_str(s: &str) -> Result<Self, ScraperError> {
        let config: ScraperConfig = toml::from_str(s)?;
        config.validate()?;
        Ok(config)
    }

    /// Validate that the config is internally consistent.
    pub fn validate(&self) -> Result<(), ScraperError> {
        if self.source.name.is_empty() {
            return Err(ScraperError::InvalidConfig(
                "source.name must not be empty".to_string(),
            ));
        }
        if self.source.url.is_empty() {
            return Err(ScraperError::InvalidConfig(
                "source.url must not be empty".to_string(),
            ));
        }
        if self.selectors.price.is_empty() {
            return Err(ScraperError::InvalidConfig(
                "selectors.price must not be empty".to_string(),
            ));
        }
        if self.rate_limit.requests_per_minute == 0 {
            return Err(ScraperError::InvalidConfig(
                "rate_limit.requests_per_minute must be > 0".to_string(),
            ));
        }
        scraper::Selector::parse(&self.selectors.price).map_err(|e| {
            ScraperError::InvalidConfig(format!(
                "selectors.price is not a valid CSS selector: {e:?}"
            ))
        })?;
        Ok(())
    }

    /// Return the effective currency for this config (selectors.currency takes priority).
    pub fn currency(&self) -> &str {
        self.selectors
            .currency
            .as_deref()
            .or(self.source.currency.as_deref())
            .unwrap_or("ZAR")
    }

    /// Build the search URL for a given ISBN (or query string).
    pub fn search_url(&self, isbn: &str) -> String {
        let base = self.source.url.trim_end_matches('/');
        let query = self
            .search
            .query_template
            .replace("{isbn}", isbn)
            .replace("{title}", isbn) // fallback: use isbn for title slot
            .replace("{author}", "");
        let query = query.trim();
        format!(
            "{}{}?{}={}",
            base,
            self.search.path,
            self.search.query_param,
            urlencoding_simple(query)
        )
    }
}

/// Minimal URL-encoding: replace spaces with + and encode a few special chars.
fn urlencoding_simple(s: &str) -> String {
    s.replace(' ', "+")
        .replace('&', "%26")
        .replace('=', "%3D")
        .replace('#', "%23")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn minimal_toml() -> &'static str {
        r#"
[source]
name = "Exclusive Books"
type = "bookshop"
country = "ZA"
url = "https://www.exclusivebooks.co.za"
has_physical_location = true

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
retry_after_seconds = 60
"#
    }

    #[test]
    fn test_parse_valid_config() {
        let config = ScraperConfig::from_toml_str(minimal_toml()).unwrap();
        assert_eq!(config.source.name, "Exclusive Books");
        assert_eq!(config.rate_limit.requests_per_minute, 10);
        assert_eq!(config.currency(), "ZAR");
    }

    #[test]
    fn test_rejects_config_without_rate_limit() {
        let toml = r#"
[source]
name = "Bad Config"
country = "ZA"
url = "https://example.com"

[search]
method = "GET"
path = "/search"
query_param = "q"

[selectors]
price = ".price"
"#;
        let result = ScraperConfig::from_toml_str(toml);
        assert!(result.is_err());
    }

    #[test]
    fn test_rejects_empty_source_name() {
        let toml = r#"
[source]
name = ""
country = "ZA"
url = "https://example.com"

[search]
method = "GET"
path = "/search"
query_param = "q"

[selectors]
price = ".price"

[rate_limit]
requests_per_minute = 5
"#;
        let result = ScraperConfig::from_toml_str(toml);
        assert!(result.is_err());
    }

    #[test]
    fn test_rejects_invalid_css_selector() {
        let toml = r#"
[source]
name = "Test"
country = "ZA"
url = "https://example.com"

[search]
method = "GET"
path = "/search"
query_param = "q"

[selectors]
price = "::invalid-selector{{{"

[rate_limit]
requests_per_minute = 5
"#;
        let result = ScraperConfig::from_toml_str(toml);
        assert!(result.is_err());
    }

    #[test]
    fn test_search_url_builds_correctly() {
        let config = ScraperConfig::from_toml_str(minimal_toml()).unwrap();
        let url = config.search_url("9780679410232");
        assert!(url.starts_with("https://www.exclusivebooks.co.za/search?q="));
        assert!(url.contains("9780679410232"));
    }

    #[test]
    fn test_currency_falls_back_to_zar() {
        let toml = r#"
[source]
name = "Test Store"
country = "ZA"
url = "https://example.com"

[search]
method = "GET"
path = "/search"
query_param = "q"

[selectors]
price = ".price"

[rate_limit]
requests_per_minute = 5
"#;
        let config = ScraperConfig::from_toml_str(toml).unwrap();
        assert_eq!(config.currency(), "ZAR");
    }
}
