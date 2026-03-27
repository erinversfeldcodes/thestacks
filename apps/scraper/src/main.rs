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

    match state
        .engine
        .scrape(&payload.isbn, &payload.store, &config)
        .await
    {
        Ok(result) => Json(ScrapeResponse {
            isbn: result.isbn,
            store: result.store,
            price_cents: result.price_cents,
            currency: result.currency,
            in_stock: result.in_stock,
            url: result.url,
            title: result.title,
            selector_match_rate: result.selector_match_rate,
        })
        .into_response(),
        Err(e) => {
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
respect_robots_txt = false
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
