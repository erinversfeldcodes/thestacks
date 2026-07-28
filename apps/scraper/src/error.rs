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

    // `rule` carries the `Disallow:` line that caused the refusal. Without it a caller
    // recording the block has no way to distinguish a narrow disallow (`/search`) from
    // a total one (`/`) — i.e. whether the store is permanently unscrapable or merely
    // needs a different path. See `RobotsPolicy::blocked_by`.
    #[error("robots.txt disallows scraping {url} ({rule})")]
    RobotsDisallowed { url: String, rule: String },

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

    /// The store genuinely does not carry this ISBN.
    ///
    /// Not a failure — a permanent, correct, useful answer. Shops stock whichever
    /// editions they stock, and Exclusive Books carries six ISBNs of The Name of the
    /// Rose while carrying none of the two searched for first. Previously
    /// indistinguishable from a broken extractor, because both surfaced as
    /// `PriceNotFound`; the handler maps this to `SCRAPE_OUTCOME_NOT_STOCKED`.
    #[error("{store} does not stock ISBN {isbn}")]
    NotStocked { store: String, isbn: String },

    /// This store cannot be looked up by ISBN without a local ISBN→URL index, which
    /// has not been built. Distinct from `NotStocked`: we do not know whether the
    /// shop carries the book, only that we cannot currently ask.
    #[error("{store} needs a local ISBN index before {isbn} can be looked up")]
    IndexRequired { store: String, isbn: String },

    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),
}
