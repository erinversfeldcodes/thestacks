use thiserror::Error;

/// Library-level errors for the scraper service.
#[derive(Debug, Error)]
pub enum ScraperError {
    #[error("config parse error: {0}")]
    ConfigParse(#[from] toml::de::Error),

    #[error("config not found: {0}")]
    ConfigNotFound(String),

    #[error("invalid config: {0}")]
    InvalidConfig(String),

    #[error("price parse error: {0}")]
    PriceParse(String),

    #[error("selector error: {0}")]
    SelectorParse(String),

    #[error("HTTP error: {0}")]
    Http(#[from] reqwest::Error),

    #[error("robots.txt disallows scraping {url}")]
    RobotsDisallowed { url: String },

    #[error("robots.txt fetch failed for {domain}: {reason}")]
    RobotsFetchFailed { domain: String, reason: String },

    #[error("rate limit exceeded for {domain}")]
    RateLimitExceeded { domain: String },

    #[error("HMAC auth failed: {0}")]
    AuthFailed(String),

    #[error("no price found at selector '{selector}' in HTML")]
    PriceNotFound { selector: String },

    #[error("store not found: {0}")]
    StoreNotFound(String),

    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),
}
