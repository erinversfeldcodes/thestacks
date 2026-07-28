use anyhow::Context;
use axum::{
    Router,
    body::Body,
    extract::{Request, State},
    http::StatusCode,
    middleware::{self, Next},
    response::{IntoResponse, Json, Response},
    routing::{get, post},
};
use serde_json::{Value, json};
use stacks_scraper::{
    error::ScraperError,
    proto::generated::scraper::{ConfigReloadResponse, ScrapeRequest, ScrapeResponse},
    scraper::Engine,
    stores::StoreRegistry,
};
use std::{path::PathBuf, sync::Arc};

// ---------------------------------------------------------------------------
// Shared application state
// ---------------------------------------------------------------------------

#[derive(Clone)]
struct AppState {
    engine: Arc<Engine>,
    registry: StoreRegistry,
    scrapers_dir: PathBuf,
    // Arc<str> so Clone shares one allocation — raw secret bytes are not heap-copied per request.
    hmac_secret: Arc<str>,
}

// ---------------------------------------------------------------------------
// HMAC auth middleware
// ---------------------------------------------------------------------------

async fn hmac_auth_middleware(
    State(state): State<AppState>,
    req: Request<Body>,
    next: Next,
) -> Response {
    let method = req.method().as_str().to_uppercase();
    let path = req.uri().path().to_string();

    let token = match req.headers().get("x-internal-token") {
        Some(v) => match v.to_str() {
            Ok(s) => s.to_string(),
            Err(_) => {
                return (
                    StatusCode::UNAUTHORIZED,
                    Json(json!({"error": "invalid token header encoding"})),
                )
                    .into_response();
            }
        },
        None => {
            return (
                StatusCode::UNAUTHORIZED,
                Json(json!({"error": "missing X-Internal-Token header"})),
            )
                .into_response();
        }
    };

    if let Err(e) = stacks_scraper::auth::verify_token(&token, &method, &path, &state.hmac_secret) {
        tracing::warn!("auth failed: {}", e);
        return (
            StatusCode::UNAUTHORIZED,
            Json(json!({"error": "unauthorized"})),
        )
            .into_response();
    }

    next.run(req).await
}

// ---------------------------------------------------------------------------
// Route handlers
// ---------------------------------------------------------------------------

async fn health() -> Json<Value> {
    Json(json!({"status": "ok", "service": "scraper"}))
}

async fn scrape(State(state): State<AppState>, Json(payload): Json<ScrapeRequest>) -> Response {
    let config = match state.registry.get(&payload.store) {
        Ok(c) => c,
        Err(e) => {
            return (StatusCode::NOT_FOUND, Json(json!({"error": e.to_string()}))).into_response();
        }
    };

    // Two things are going on here, and both are deliberate.
    //
    // `scrape_auto` rather than `scrape`: it routes to the store's *observed*
    // platform API and only falls back to CSS selectors for the two targets that
    // have no product JSON API at all. Calling `scrape` here is what previously left
    // the platform adapters built but unreachable.
    //
    // And the HTTP status says whether the *service* worked while `outcome` says
    // what the scrape *concluded*. Previously every error became a 500, and the
    // caller melts a circuit breaker shared by all stores on any non-200 — so a shop
    // that permanently forbids our path via robots.txt, or simply does not stock a
    // book, took price scraping down for every other shop too.
    match state
        .engine
        .scrape_auto(&payload.isbn, &payload.store, &config)
        .await
    {
        // Reached a page and read a price.
        Ok(result) if result.price_cents.is_some() => Json(ScrapeResponse {
            isbn: result.isbn,
            store: result.store,
            price_cents: result.price_cents,
            currency: result.currency,
            in_stock: result.in_stock,
            url: result.url,
            title: result.title,
            selector_match_rate: result.selector_match_rate,
            outcome: outcome::PRICED.to_string(),
            detail: None,
        })
        .into_response(),

        // Reached a page but came away with no price. Deliberately reported as an
        // extractor failure rather than "not stocked": on a search-based config the
        // two are indistinguishable, and guessing "not stocked" would quietly
        // record false negatives instead of surfacing a broken selector.
        Ok(result) => {
            tracing::warn!(
                "scrape found no price for store={} isbn={}",
                payload.store,
                payload.isbn
            );

            Json(ScrapeResponse {
                outcome: outcome::EXTRACTOR_FAILED.to_string(),
                detail: Some("page fetched but no price could be extracted".to_string()),
                ..empty_response(&result.isbn, &result.store, &result.currency)
            })
            .into_response()
        }

        Err(e) => match outcome_for_error(&e) {
            // The service worked and reached a determination. 200, with the
            // conclusion in `outcome` — `thiserror`'s Display already reads well
            // enough to serve as the diagnostic detail.
            Some(concluded) => {
                tracing::info!(
                    "scrape concluded {} for store={} isbn={}: {}",
                    concluded,
                    payload.store,
                    payload.isbn,
                    e
                );

                Json(ScrapeResponse {
                    outcome: concluded.to_string(),
                    detail: Some(e.to_string()),
                    ..empty_response(&payload.isbn, &payload.store, config.currency())
                })
                .into_response()
            }

            None => {
                tracing::error!(
                    "scrape error for store={} isbn={}: {}",
                    payload.store,
                    payload.isbn,
                    e
                );
                (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    Json(json!({"error": e.to_string()})),
                )
                    .into_response()
            }
        },
    }
}

/// Wire values for `ScrapeOutcome`. proto3 JSON serialises enums by name, and the
/// Rust codegen maps them to `String`, so these are the contract.
mod outcome {
    pub const PRICED: &str = "SCRAPE_OUTCOME_PRICED";
    pub const NOT_STOCKED: &str = "SCRAPE_OUTCOME_NOT_STOCKED";
    pub const ROBOTS_BLOCKED: &str = "SCRAPE_OUTCOME_ROBOTS_BLOCKED";
    pub const EXTRACTOR_FAILED: &str = "SCRAPE_OUTCOME_EXTRACTOR_FAILED";
}

/// Decide whether an engine error is a *determination* or a *failure*.
///
/// `Some(outcome)` — the service did its job and arrived at an answer, so the
/// response is HTTP 200 carrying that outcome. `None` — the service or the network
/// failed, so it is a 5xx.
///
/// This is the single place that decision is made, and it matters more than it
/// looks: the caller melts a circuit breaker **shared by every store** on any
/// non-200, and that breaker opens for 15 minutes after 3 failures. Classifying a
/// permanent, expected condition (robots.txt forbids the path; the shop does not
/// carry the book) as a failure would let one store disable price scraping for all
/// of them — and, worse, would do so repeatedly, since the condition recurs on
/// every single attempt.
fn outcome_for_error(e: &ScraperError) -> Option<&'static str> {
    match e {
        // Permanent and correct until the site's rules change. Configuration is
        // retained, so it starts working again by itself if the rule is lifted.
        ScraperError::RobotsDisallowed { .. } => Some(outcome::ROBOTS_BLOCKED),

        // The shop does not carry this ISBN. A real answer worth storing, and the
        // most common one once pricing is per-edition.
        ScraperError::NotStocked { .. } => Some(outcome::NOT_STOCKED),

        // We cannot ask this store about this ISBN yet — a gap in our capability,
        // not a fact about the book. Reported as an extractor failure so it counts
        // against this store's own circuit and shows up in per-source health,
        // rather than being mistaken for "not stocked" and recorded as a price of
        // nothing.
        ScraperError::IndexRequired { .. } => Some(outcome::EXTRACTOR_FAILED),

        // We fetched a page and our selector found nothing. Our defect, but a
        // per-store one — it says nothing about the health of the service, so it
        // belongs in per-source health tracking rather than the shared breaker.
        ScraperError::PriceNotFound { .. } => Some(outcome::EXTRACTOR_FAILED),

        // Everything else is a genuine failure of the service or the network:
        // rate-limit exhaustion, an upstream HTTP error, an unreachable robots.txt,
        // a malformed config, IO. Listed explicitly rather than caught by a
        // wildcard so that adding a variant to ScraperError forces a decision here
        // instead of silently defaulting to "failure".
        ScraperError::ConfigParse(_)
        | ScraperError::ConfigNotFound(_)
        | ScraperError::InvalidConfig(_)
        | ScraperError::PriceParse(_)
        | ScraperError::SelectorParse(_)
        | ScraperError::Http(_)
        | ScraperError::RobotsFetchFailed { .. }
        | ScraperError::RateLimitExceeded { .. }
        | ScraperError::AuthFailed(_)
        | ScraperError::StoreNotFound(_)
        | ScraperError::Io(_) => None,
    }
}

/// A response carrying no price, for outcomes that are not `PRICED`. Callers fill
/// in `outcome` and `detail`.
fn empty_response(isbn: &str, store: &str, currency: &str) -> ScrapeResponse {
    ScrapeResponse {
        isbn: isbn.to_string(),
        store: store.to_string(),
        price_cents: None,
        currency: currency.to_string(),
        in_stock: None,
        url: None,
        title: None,
        selector_match_rate: None,
        outcome: String::new(),
        detail: None,
    }
}

async fn config_reload(State(state): State<AppState>) -> Response {
    match state.registry.load_from_dir(&state.scrapers_dir) {
        Ok(n) => Json(ConfigReloadResponse { loaded: n as i32 }).into_response(),
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({"error": e.to_string()})),
        )
            .into_response(),
    }
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt::init();

    let hmac_secret = std::env::var("SCRAPER_HMAC_SECRET")
        .context("SCRAPER_HMAC_SECRET environment variable is required")?;

    let port: u16 = std::env::var("SCRAPER_PORT")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(8080);

    // Resolve scrapers directory relative to the binary's working directory.
    let scrapers_dir = PathBuf::from("scrapers");

    let registry = StoreRegistry::new();
    if scrapers_dir.exists() {
        let count = registry.load_from_dir(&scrapers_dir)?;
        tracing::info!("loaded {} store configs from {:?}", count, scrapers_dir);
    } else {
        tracing::warn!(
            "scrapers directory {:?} not found — no configs loaded",
            scrapers_dir
        );
    }

    let engine = Arc::new(Engine::new().context("failed to build scrape engine")?);

    let state = AppState {
        engine,
        registry,
        scrapers_dir,
        hmac_secret: hmac_secret.into(),
    };

    let authed_routes = Router::new()
        .route("/scrape", post(scrape))
        .route("/config/reload", post(config_reload))
        .layer(middleware::from_fn_with_state(
            state.clone(),
            hmac_auth_middleware,
        ));

    let app = Router::new()
        .route("/health", get(health))
        .merge(authed_routes)
        .with_state(state);

    // Bind to [::] (dual-stack) so the scraper accepts both IPv4 and IPv6 connections.
    // Fly.io's private 6PN network routes .internal DNS to IPv6 addresses; binding to
    // 0.0.0.0 (IPv4 only) would make the scraper unreachable from other Fly machines.
    let addr = format!("[::]:{port}");
    tracing::info!("scraper listening on {}", addr);

    let listener = tokio::net::TcpListener::bind(&addr)
        .await
        .with_context(|| format!("failed to bind to {addr}"))?;

    axum::serve(listener, app)
        .await
        .context("scraper server error")?;

    Ok(())
}

// ---------------------------------------------------------------------------
// Integration tests for the HTTP routes
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use axum::{body::Body, http::Request};
    use stacks_scraper::{auth::generate_token, config::ScraperConfig};
    use tower::util::ServiceExt;

    const TEST_SECRET: &str = "test-hmac-secret";

    // The mock engine bypasses robots.txt entirely, so the handler's
    // determination-vs-failure branch cannot be reached over HTTP. These exercise
    // the classifier directly, which is where the decision actually lives.
    #[test]
    fn robots_disallow_is_a_determination_not_a_failure() {
        // The whole reason this distinction exists: a disallowed path recurs on
        // every attempt, so reporting it as a failure would melt the fuse shared by
        // all stores, over and over, and take price scraping down everywhere.
        let e = ScraperError::RobotsDisallowed {
            url: "https://exclusivebooks.co.za/search?q=9780156001311".to_string(),
        };
        assert_eq!(outcome_for_error(&e), Some(outcome::ROBOTS_BLOCKED));
    }

    #[test]
    fn not_stocked_is_a_determination() {
        // Now reachable for real: a Shopify store whose handle is the ISBN answers
        // 404 for an edition it does not carry. Measured — /products/9780156001311.js
        // returns 404 at Exclusive Books while /products/9780749397050.js returns 200
        // at R400.00.
        let e = ScraperError::NotStocked {
            store: "za/exclusive_books".to_string(),
            isbn: "9780156001311".to_string(),
        };
        assert_eq!(outcome_for_error(&e), Some(outcome::NOT_STOCKED));
    }

    #[test]
    fn needing_an_index_is_not_reported_as_not_stocked() {
        // We do not know whether the shop has the book, only that we cannot ask.
        // Reporting NOT_STOCKED here would record a false negative as though it were
        // a fact about the shop's stock.
        let e = ScraperError::IndexRequired {
            store: "za/wordsworth".to_string(),
            isbn: "9780723263661".to_string(),
        };
        let verdict = outcome_for_error(&e);
        assert_eq!(verdict, Some(outcome::EXTRACTOR_FAILED));
        assert_ne!(verdict, Some(outcome::NOT_STOCKED));
    }

    #[test]
    fn a_missing_price_is_our_bug_but_still_not_a_service_failure() {
        let e = ScraperError::PriceNotFound {
            selector: ".product-price".to_string(),
        };
        assert_eq!(outcome_for_error(&e), Some(outcome::EXTRACTOR_FAILED));
    }

    #[test]
    fn service_and_network_faults_stay_failures() {
        // These are the only cases that should count against the circuit breaker.
        for e in [
            ScraperError::RateLimitExceeded {
                domain: "example.com".to_string(),
            },
            ScraperError::RobotsFetchFailed {
                domain: "kalkbaybooks.co.za".to_string(),
                reason: "HTTP 503".to_string(),
            },
            ScraperError::InvalidConfig("no price selector".to_string()),
            ScraperError::StoreNotFound("za/nope".to_string()),
        ] {
            assert_eq!(
                outcome_for_error(&e),
                None,
                "expected {e} to be treated as a service failure"
            );
        }
    }

    fn make_test_state() -> AppState {
        let registry = StoreRegistry::new();

        // Insert a minimal in-memory store config for testing.
        let config = ScraperConfig::from_toml_str(
            r#"
[source]
name = "Test Store"
country = "ZA"
url = "https://example.com"

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
        .unwrap();
        registry.insert("za/test_store".to_string(), config);

        AppState {
            engine: Arc::new(Engine::new().expect("failed to build engine")),
            registry,
            scrapers_dir: PathBuf::from("scrapers"),
            hmac_secret: TEST_SECRET.into(),
        }
    }

    fn make_app(state: AppState) -> Router {
        let authed_routes = Router::new()
            .route("/scrape", post(scrape))
            .route("/config/reload", post(config_reload))
            .layer(middleware::from_fn_with_state(
                state.clone(),
                hmac_auth_middleware,
            ));

        Router::new()
            .route("/health", get(health))
            .merge(authed_routes)
            .with_state(state)
    }

    // ------------------------------------------------------------------
    // /health — no auth required
    // ------------------------------------------------------------------

    #[tokio::test]
    async fn test_health_returns_ok() {
        let state = make_test_state();
        let app = make_app(state);

        let req = Request::builder()
            .method("GET")
            .uri("/health")
            .body(Body::empty())
            .unwrap();

        let resp = app.oneshot(req).await.unwrap();
        assert_eq!(resp.status(), StatusCode::OK);

        let body = axum::body::to_bytes(resp.into_body(), 1024).await.unwrap();
        let json: Value = serde_json::from_slice(&body).unwrap();
        assert_eq!(json["status"], "ok");
    }

    // ------------------------------------------------------------------
    // /scrape — auth required
    // ------------------------------------------------------------------

    #[tokio::test]
    async fn test_scrape_without_token_returns_401() {
        let state = make_test_state();
        let app = make_app(state);

        let req = Request::builder()
            .method("POST")
            .uri("/scrape")
            .header("content-type", "application/json")
            .body(Body::from(
                r#"{"isbn":"9780679410232","store":"za/test_store"}"#,
            ))
            .unwrap();

        let resp = app.oneshot(req).await.unwrap();
        assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
    }

    #[tokio::test]
    async fn test_scrape_with_wrong_secret_returns_401() {
        let state = make_test_state();
        let app = make_app(state);

        let bad_token = generate_token("POST", "/scrape", "wrong-secret").unwrap();

        let req = Request::builder()
            .method("POST")
            .uri("/scrape")
            .header("content-type", "application/json")
            .header("x-internal-token", bad_token)
            .body(Body::from(
                r#"{"isbn":"9780679410232","store":"za/test_store"}"#,
            ))
            .unwrap();

        let resp = app.oneshot(req).await.unwrap();
        assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
    }

    #[tokio::test]
    async fn test_scrape_unknown_store_returns_404() {
        let state = make_test_state();
        let app = make_app(state);

        let token = generate_token("POST", "/scrape", TEST_SECRET).unwrap();

        let req = Request::builder()
            .method("POST")
            .uri("/scrape")
            .header("content-type", "application/json")
            .header("x-internal-token", token)
            .body(Body::from(
                r#"{"isbn":"9780679410232","store":"za/nonexistent"}"#,
            ))
            .unwrap();

        let resp = app.oneshot(req).await.unwrap();
        assert_eq!(resp.status(), StatusCode::NOT_FOUND);
    }

    // ------------------------------------------------------------------
    // /config/reload — auth required
    // ------------------------------------------------------------------

    #[tokio::test]
    async fn test_config_reload_without_token_returns_401() {
        let state = make_test_state();
        let app = make_app(state);

        let req = Request::builder()
            .method("POST")
            .uri("/config/reload")
            .body(Body::empty())
            .unwrap();

        let resp = app.oneshot(req).await.unwrap();
        assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
    }

    #[tokio::test]
    async fn test_config_reload_with_valid_token_returns_200() {
        let state = make_test_state();
        let app = make_app(state);

        let token = generate_token("POST", "/config/reload", TEST_SECRET).unwrap();

        let req = Request::builder()
            .method("POST")
            .uri("/config/reload")
            .header("x-internal-token", token)
            .body(Body::empty())
            .unwrap();

        let resp = app.oneshot(req).await.unwrap();
        // scrapers dir may or may not exist in the test CWD — either 200 or 500 is acceptable,
        // but the auth layer must not reject the request (which would give 401).
        assert_ne!(resp.status(), StatusCode::UNAUTHORIZED);
    }

    #[tokio::test]
    async fn test_config_reload_with_wrong_path_token_rejected() {
        let state = make_test_state();
        let app = make_app(state);

        // Token signed for /scrape — should be rejected on /config/reload.
        let bad_token = generate_token("POST", "/scrape", TEST_SECRET).unwrap();

        let req = Request::builder()
            .method("POST")
            .uri("/config/reload")
            .header("x-internal-token", bad_token)
            .body(Body::empty())
            .unwrap();

        let resp = app.oneshot(req).await.unwrap();
        assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
    }
}
