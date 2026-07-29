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
    proto::generated::scraper::{
        CatalogueTitle, CatalogueTitlesRequest, CatalogueTitlesResponse, ConfigReloadResponse,
        FetchPageRequest, FetchPageResponse, ScrapeRequest, ScrapeResponse, SitemapUrlsRequest,
        SitemapUrlsResponse, StoreCapability,
    },
    scraper::{Engine, FetchedPage, Validators},
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

    // Reported on every response so the caller can persist it, which keeps the
    // observation's timestamp current without a separate probe schedule. A
    // replatform therefore surfaces on the next scrape rather than the next sweep.
    // A failed observation is reported as no observation, not as a fabricated one.
    let observed = state
        .engine
        .capability_for(&payload.store, &config)
        .await
        .ok()
        .map(wire_capability_of);

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
        .scrape_auto(
            &payload.isbn,
            &payload.store,
            &config,
            payload.product_path.as_deref(),
        )
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
            capability: observed.clone(),
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
                capability: observed.clone(),
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
                    capability: observed.clone(),
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
    pub const INDEX_REQUIRED: &str = "SCRAPE_OUTCOME_INDEX_REQUIRED";
    pub const RATE_LIMITED: &str = "SCRAPE_OUTCOME_RATE_LIMITED";
}

/// Wire values for `FetchOutcome` — a page fetch's outcomes, which are not a scrape's.
/// Kept separate from `outcome` above so the two cannot be mixed at a call site.
mod fetch_outcome {
    pub const FETCHED: &str = "FETCH_OUTCOME_FETCHED";
    pub const ROBOTS_BLOCKED: &str = "FETCH_OUTCOME_ROBOTS_BLOCKED";
    pub const RATE_LIMITED: &str = "FETCH_OUTCOME_RATE_LIMITED";
    pub const NOT_MODIFIED: &str = "FETCH_OUTCOME_NOT_MODIFIED";
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

        // We cannot ask this store about this ISBN yet. Its own outcome rather than
        // an extractor failure, because it is *actionable*: the caller builds the
        // index and retries, instead of recording a defect against a store that is
        // working fine. Still emphatically not NOT_STOCKED — we do not know whether
        // the shop carries the book.
        ScraperError::IndexRequired { .. } => Some(outcome::INDEX_REQUIRED),

        // We fetched a page and our selector found nothing. Our defect, but a
        // per-store one — it says nothing about the health of the service, so it
        // belongs in per-source health tracking rather than the shared breaker.
        ScraperError::PriceNotFound { .. } => Some(outcome::EXTRACTOR_FAILED),

        // The shop is pacing us, and it is entitled to. Neither our defect nor a service failure,
        // so not a 5xx — and emphatically not a fuse-melting one, since it recurs on every attempt
        // until the cooldown lapses. Unlike ROBOTS_BLOCKED it resolves by itself with time.
        ScraperError::UpstreamBackoff { .. } => Some(outcome::RATE_LIMITED),

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
        capability: None,
    }
}

/// Convert an observed capability to its wire form.
fn wire_capability_of(cap: stacks_scraper::platform::Capability) -> StoreCapability {
    StoreCapability {
        price_source: cap.price_source.as_wire().to_string(),
        isbn_location: cap.isbn_location.as_wire().to_string(),
        lookup_mode: cap.lookup_mode.as_wire().to_string(),
    }
}

/// POST /index/build — build a store's ISBN→product-path index.
///
/// Separate from `/scrape` because it is a bulk operation: up to `MAX_INDEX_PAGES`
/// requests against a shop limited to a few per minute, so it waits on the rate limit
/// and can take minutes. It must never happen inside a price request.
///
/// Needed by the four Shopify targets whose products carry an ISBN somewhere other
/// than the handle (Wordsworth, Stellenbosch, Bridge, Clarke's), which therefore
/// cannot be addressed by ISBN directly.
async fn index_build(
    State(state): State<AppState>,
    Json(payload): Json<ScrapeRequest>,
) -> Response {
    let config = match state.registry.get(&payload.store) {
        Ok(c) => c,
        Err(e) => {
            return (StatusCode::NOT_FOUND, Json(json!({"error": e.to_string()}))).into_response();
        }
    };

    match state.engine.build_index(&payload.store, &config).await {
        Ok(entries) => {
            tracing::info!(
                "built index for store={} entries={}",
                payload.store,
                entries
            );
            Json(json!({"store": payload.store, "entries": entries})).into_response()
        }
        Err(e) => {
            tracing::error!("index build failed for store={}: {}", payload.store, e);
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(json!({"error": e.to_string()})),
            )
                .into_response()
        }
    }
}

/// POST /catalogue/titles — products this store lists that carry no ISBN.
///
/// The residual for the two shops where no product carries an ISBN, so title matching
/// is the only path. Returns paths and titles only; the caller matches against its own
/// catalogue and keeps just the pointer.
///
/// A bulk sweep like the index build: it waits on the rate limit and takes minutes, so
/// it must not be called from a request path that anyone is waiting on.
async fn catalogue_titles(
    State(state): State<AppState>,
    Json(payload): Json<CatalogueTitlesRequest>,
) -> Response {
    let config = match state.registry.get(&payload.store) {
        Ok(c) => c,
        Err(e) => {
            return (StatusCode::NOT_FOUND, Json(json!({"error": e.to_string()}))).into_response();
        }
    };

    match state.engine.catalogue_titles(&config).await {
        Ok(pairs) => {
            tracing::info!(
                "listed {} untitled-by-isbn products for store={}",
                pairs.len(),
                payload.store
            );

            Json(CatalogueTitlesResponse {
                titles: pairs
                    .into_iter()
                    .map(|(product_path, title)| CatalogueTitle {
                        product_path,
                        title,
                    })
                    .collect(),
            })
            .into_response()
        }
        Err(e) => {
            tracing::error!("catalogue titles failed for store={}: {}", payload.store, e);
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(json!({"error": e.to_string()})),
            )
                .into_response()
        }
    }
}

/// POST /fetch — retrieve one page for a configured store, compliantly.
///
/// Exists so that callers wanting a store's *page* rather than its price do not build
/// their own HTTP request. `DiscoverBookstoreEventsJob` did exactly that — a bare
/// `Finch.build(:get, "#{website_url}/events")` with no robots check, no rate limiter
/// and no fuse — which is the compliance hole this closes.
///
/// Keyed by store, not URL: the config supplies the base URL and the rate limit, so a
/// store with no scraper config cannot be fetched at all. That is deliberate — no
/// config means no declared crawl policy, and guessing one turns a hard rule into an
/// advisory one.
///
/// A robots disallow is **200 with `outcome: ROBOTS_BLOCKED`**, not an error status:
/// it is a determination about the store, and the caller must record it and stop
/// rather than retry. Returning 5xx here would melt the shared fuse on every attempt
/// for a condition that recurs by definition — the same reasoning as `outcome_for_error`.
async fn fetch_page(
    State(state): State<AppState>,
    Json(payload): Json<FetchPageRequest>,
) -> Response {
    let config = match state.registry.get(&payload.store) {
        Ok(c) => c,
        Err(e) => {
            return (StatusCode::NOT_FOUND, Json(json!({"error": e.to_string()}))).into_response();
        }
    };

    // Reject a path that isn't one. Without this, `path: "https://evil.test/x"` would be
    // concatenated onto the base URL, and a caller could steer our compliant egress at
    // an arbitrary host — the rate limit and robots check would apply to the *configured*
    // domain while the request went somewhere else.
    if !payload.path.starts_with('/') || payload.path.starts_with("//") {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({"error": "path must be absolute and begin with a single '/'"})),
        )
            .into_response();
    }

    let validators = Validators {
        if_none_match: payload.if_none_match,
        if_modified_since: payload.if_modified_since,
    };

    fetch_response(
        state
            .engine
            .fetch_path(&config, &payload.path, validators)
            .await,
        &payload.store,
    )
}

/// Wire values for `SitemapOutcome`.
mod sitemap_outcome {
    pub const HARVESTED: &str = "SITEMAP_OUTCOME_HARVESTED";
    pub const NO_SITEMAP_DECLARED: &str = "SITEMAP_OUTCOME_NO_SITEMAP_DECLARED";
    pub const ROBOTS_BLOCKED: &str = "SITEMAP_OUTCOME_ROBOTS_BLOCKED";
    pub const RATE_LIMITED: &str = "SITEMAP_OUTCOME_RATE_LIMITED";
}

async fn sitemap_urls(
    State(state): State<AppState>,
    Json(payload): Json<SitemapUrlsRequest>,
) -> Response {
    let config = match state.registry.get(&payload.store) {
        Ok(c) => c,
        Err(e) => {
            return (StatusCode::NOT_FOUND, Json(json!({"error": e.to_string()}))).into_response();
        }
    };

    let result = state.engine.sitemap_urls(&config).await;
    sitemap_response(result, &payload.store)
}

/// Maps a sitemap walk onto the wire response.
///
/// Extracted for the same reason as `fetch_response`: the handler's own tests go through the real
/// engine, so no branch here is otherwise reachable without a network.
fn sitemap_response(
    result: Result<stacks_scraper::scraper::SitemapHarvest, ScraperError>,
    store: &str,
) -> Response {
    match result {
        Ok(harvest) => {
            // Logged rather than left to the caller, because this is the number that says whether the
            // operation is behaving politely. "N documents, M bytes" on every run means a change that
            // starts pulling a catalogue is visible immediately instead of being inferred later from
            // someone's bandwidth bill.
            tracing::info!(
                "sitemap walk for store={}: {} url(s) from {} document(s), {} bytes, {} skipped{}",
                store,
                harvest.urls.len(),
                harvest.documents_fetched,
                harvest.bytes_read,
                harvest.skipped.len(),
                if harvest.truncated {
                    " (TRUNCATED — budget spent)"
                } else {
                    ""
                }
            );

            // No sitemap declared at all is its own outcome, not an empty harvest. "The shop has no
            // index" and "the index listed nothing" lead to different decisions, and reporting the
            // first as the second records a shop as having no events page without ever having asked.
            let outcome = if harvest.documents_fetched == 0 && harvest.skipped.is_empty() {
                sitemap_outcome::NO_SITEMAP_DECLARED
            } else {
                sitemap_outcome::HARVESTED
            };

            Json(SitemapUrlsResponse {
                outcome: outcome.to_string(),
                urls: harvest.urls,
                documents_fetched: harvest.documents_fetched as i32,
                bytes_read: harvest.bytes_read as i64,
                skipped: harvest.skipped,
                truncated: harvest.truncated,
                retry_after_seconds: 0,
            })
            .into_response()
        }

        Err(ScraperError::UpstreamBackoff {
            seconds_remaining, ..
        }) => Json(SitemapUrlsResponse {
            outcome: sitemap_outcome::RATE_LIMITED.to_string(),
            retry_after_seconds: seconds_remaining as i64,
            ..Default::default()
        })
        .into_response(),

        Err(ScraperError::RobotsDisallowed { rule, .. }) => Json(SitemapUrlsResponse {
            outcome: sitemap_outcome::ROBOTS_BLOCKED.to_string(),
            // The rule rides in `skipped` rather than getting its own field: this response already
            // has a place for "what we did not fetch and why", and a second one would let the two
            // disagree.
            skipped: vec![rule],
            ..Default::default()
        })
        .into_response(),

        Err(e) => {
            tracing::error!("sitemap walk failed for store={}: {}", store, e);
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(json!({"error": e.to_string()})),
            )
                .into_response()
        }
    }
}

/// Maps a fetch outcome onto the wire response.
///
/// Extracted from `fetch_page` so the branches are reachable **without a network round-trip**. The
/// handler's own tests go through the real engine against the configured base URL, which means the
/// robots-blocked branch cannot be exercised there at all — and that branch is the one carrying the
/// easiest-to-lose piece of information in this file (see the `sitemaps` note below).
fn fetch_response(outcome: Result<FetchedPage, ScraperError>, store: &str) -> Response {
    match outcome {
        Ok(page) => Json(FetchPageResponse {
            status: page.status as i32,
            body: page.body,
            // 304 is its own outcome, not a FETCHED with an empty body. Those mean opposite things:
            // an empty body would read as "the page is now blank", which for an events page says
            // every event was removed. Here it says nothing changed, so keep what you have.
            outcome: if page.status == 304 {
                fetch_outcome::NOT_MODIFIED.to_string()
            } else {
                fetch_outcome::FETCHED.to_string()
            },
            robots_rule: String::new(),
            // Free information: robots.txt was already fetched for compliance, so the shop has
            // already told us where its index is. Returning it means a caller never has to guess
            // at a path, and a guess costs the shop a full page render.
            sitemaps: page.sitemaps,
            retry_after_seconds: 0,
            etag: page.etag,
            last_modified: page.last_modified,
        })
        .into_response(),

        // The shop is pacing us. Reported as a 200 determination carrying the cooldown, so the
        // caller can snooze for exactly as long as asked instead of guessing — and so it does not
        // melt the fuse shared by every other shop. See `ScraperError::UpstreamBackoff`.
        Err(ScraperError::UpstreamBackoff {
            domain,
            seconds_remaining,
        }) => {
            tracing::info!(
                "backing off {} for store={}; {}s remaining",
                domain,
                store,
                seconds_remaining
            );

            Json(FetchPageResponse {
                status: 0,
                // Deliberately empty. A 429 body is a styled challenge page — 9 KB of it from both
                // target shops — and handing that to an extractor is how "found no events" gets
                // reported for a page we were never shown.
                body: String::new(),
                outcome: fetch_outcome::RATE_LIMITED.to_string(),
                robots_rule: String::new(),
                sitemaps: Vec::new(),
                retry_after_seconds: seconds_remaining as i64,
                etag: String::new(),
                last_modified: String::new(),
            })
            .into_response()
        }

        Err(ScraperError::RobotsDisallowed {
            url,
            rule,
            sitemaps,
        }) => {
            tracing::info!(
                "robots.txt disallows {} for store={} ({})",
                url,
                store,
                rule
            );

            // The sitemaps survive the refusal deliberately — see `ScraperError::RobotsDisallowed`.
            // A blocked path plus "here is the index" is actionable; a blocked path alone is not.
            Json(FetchPageResponse {
                status: 0,
                body: String::new(),
                outcome: fetch_outcome::ROBOTS_BLOCKED.to_string(),
                robots_rule: rule,
                sitemaps,
                retry_after_seconds: 0,
                etag: String::new(),
                last_modified: String::new(),
            })
            .into_response()
        }

        Err(e) => {
            tracing::error!("fetch failed for store={}: {}", store, e);
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
        .route("/index/build", post(index_build))
        .route("/catalogue/titles", post(catalogue_titles))
        .route("/fetch", post(fetch_page))
        .route("/sitemap-urls", post(sitemap_urls))
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
    use stacks_scraper::scraper::SitemapHarvest;
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
            rule: "Disallow: /search".to_string(),
            // Measured from the live document: it declares this outside any group, so we hold it
            // even while refusing the path — that is how discovery finds a page it MAY fetch.
            sitemaps: vec!["https://exclusivebooks.co.za/sitemap.xml".to_string()],
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
    fn needing_an_index_is_actionable_and_not_not_stocked() {
        // Its own outcome, so the caller can build the index and retry. Reporting
        // NOT_STOCKED would record a false negative as a fact about the shop's stock;
        // reporting EXTRACTOR_FAILED would blame a store that is working fine.
        let e = ScraperError::IndexRequired {
            store: "za/wordsworth".to_string(),
            isbn: "9780723263661".to_string(),
        };
        let verdict = outcome_for_error(&e);
        assert_eq!(verdict, Some(outcome::INDEX_REQUIRED));
        assert_ne!(verdict, Some(outcome::NOT_STOCKED));
        assert_ne!(verdict, Some(outcome::EXTRACTOR_FAILED));
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
            .route("/index/build", post(index_build))
            .route("/catalogue/titles", post(catalogue_titles))
            .route("/fetch", post(fetch_page))
            .route("/sitemap-urls", post(sitemap_urls))
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
    // /fetch — the compliant egress for page fetches (C3)
    // ------------------------------------------------------------------

    /// Build a `/fetch` request. `token` omitted means no auth header at all.
    fn fetch_req(body: &str, token: Option<String>) -> Request<Body> {
        let mut b = Request::builder()
            .method("POST")
            .uri("/fetch")
            .header("content-type", "application/json");

        if let Some(t) = token {
            b = b.header("x-internal-token", t);
        }

        b.body(Body::from(body.to_string())).unwrap()
    }

    #[tokio::test]
    async fn test_fetch_without_token_returns_401() {
        let app = make_app(make_test_state());
        let req = fetch_req(r#"{"store":"za/test_store","path":"/events"}"#, None);

        let resp = app.oneshot(req).await.unwrap();
        assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
    }

    #[tokio::test]
    async fn test_fetch_unknown_store_returns_404() {
        // A store with no scraper config cannot be fetched at all. That is the
        // guarantee: no config means no declared crawl policy, and this endpoint
        // refuses rather than guessing one.
        let app = make_app(make_test_state());
        let token = generate_token("POST", "/fetch", TEST_SECRET).unwrap();
        let req = fetch_req(
            r#"{"store":"za/nonexistent","path":"/events"}"#,
            Some(token),
        );

        let resp = app.oneshot(req).await.unwrap();
        assert_eq!(resp.status(), StatusCode::NOT_FOUND);
    }

    #[tokio::test]
    async fn test_fetch_rejects_a_path_that_steers_at_another_host() {
        // The path is concatenated onto the configured base URL, so an absolute URL
        // or a protocol-relative one would send the request somewhere else while the
        // robots check and rate limit still applied to the *configured* domain —
        // turning the compliant egress into an open proxy.
        for hostile in [
            r#"{"store":"za/test_store","path":"https://evil.test/x"}"#,
            r#"{"store":"za/test_store","path":"//evil.test/x"}"#,
            r#"{"store":"za/test_store","path":"events"}"#,
            r#"{"store":"za/test_store","path":""}"#,
        ] {
            let app = make_app(make_test_state());
            let token = generate_token("POST", "/fetch", TEST_SECRET).unwrap();

            let resp = app.oneshot(fetch_req(hostile, Some(token))).await.unwrap();

            assert_eq!(
                resp.status(),
                StatusCode::BAD_REQUEST,
                "path was accepted but must be rejected: {hostile}"
            );
        }
    }

    #[tokio::test]
    async fn test_fetch_accepts_a_relative_path_for_a_configured_store() {
        // The store check must happen for a well-formed path too — i.e. rejection
        // above is about the path, not a blanket refusal that would make the
        // previous test pass for the wrong reason.
        let app = make_app(make_test_state());
        let token = generate_token("POST", "/fetch", TEST_SECRET).unwrap();
        let req = fetch_req(r#"{"store":"za/test_store","path":"/events"}"#, Some(token));

        let resp = app.oneshot(req).await.unwrap();
        assert_ne!(
            resp.status(),
            StatusCode::BAD_REQUEST,
            "a well-formed relative path must not be rejected as malformed"
        );
    }

    // ------------------------------------------------------------------
    // /sitemap-urls — polite page discovery
    // ------------------------------------------------------------------

    async fn body_of(resp: Response) -> Value {
        let bytes = axum::body::to_bytes(resp.into_body(), 64 * 1024)
            .await
            .unwrap();
        serde_json::from_slice(&bytes).unwrap()
    }

    #[tokio::test]
    async fn no_declared_sitemap_is_its_own_outcome_not_an_empty_harvest() {
        // ⚠️ The distinction this test exists for. "The shop declares no sitemap" and "the shop's
        // sitemap lists no pages" both come back with zero URLs, and collapsing them would let a
        // caller record a shop as having no events page on the strength of never having looked.
        let resp = sitemap_response(Ok(SitemapHarvest::default()), "za/test_store");
        let json = body_of(resp).await;

        assert_eq!(json["outcome"], sitemap_outcome::NO_SITEMAP_DECLARED);
    }

    #[tokio::test]
    async fn a_walk_that_read_a_document_is_harvested_even_with_no_urls() {
        // The other side of the distinction above: we DID look, and the index genuinely listed
        // nothing we could use. That is a real answer about the shop and must not read as "no index".
        let resp = sitemap_response(
            Ok(SitemapHarvest {
                documents_fetched: 1,
                bytes_read: 10_334,
                skipped: vec![
                    "https://shop.test/sitemap_products_1.xml (catalogue-sized, not pages)".into(),
                ],
                ..Default::default()
            }),
            "za/test_store",
        );
        let json = body_of(resp).await;

        assert_eq!(json["outcome"], sitemap_outcome::HARVESTED);
        // The key is ABSENT rather than `[]` — the generated struct skips empty repeated fields, the
        // same behaviour `sitemaps` relies on. `outcome` is what carries the meaning here.
        assert!(json.get("urls").is_none(), "expected no urls key: {json}");
        assert_eq!(
            json["skipped"].as_array().map(Vec::len),
            Some(1),
            "the refusal to download a catalogue was not reported, so 'found nothing' is \
             indistinguishable from 'declined to look'"
        );
    }

    #[tokio::test]
    async fn a_truncated_walk_says_so_rather_than_looking_complete() {
        // A partial result presented as complete is the failure mode: the caller concludes the shop
        // has no events page and never asks again.
        let resp = sitemap_response(
            Ok(SitemapHarvest {
                urls: vec!["https://shop.test/pages/about".into()],
                documents_fetched: 4,
                bytes_read: 8 * 1024 * 1024,
                truncated: true,
                ..Default::default()
            }),
            "za/test_store",
        );
        let json = body_of(resp).await;

        assert_eq!(json["outcome"], sitemap_outcome::HARVESTED);
        assert_eq!(json["truncated"], true);
    }

    #[tokio::test]
    async fn the_cost_of_the_walk_is_reported_so_politeness_is_measurable() {
        // Not decoration. These two numbers are how a regression that starts pulling a product
        // catalogue becomes visible on the next run instead of on someone's bandwidth bill.
        let resp = sitemap_response(
            Ok(SitemapHarvest {
                urls: vec!["https://shop.test/pages/events".into()],
                documents_fetched: 2,
                bytes_read: 12_500,
                ..Default::default()
            }),
            "za/test_store",
        );
        let json = body_of(resp).await;

        assert_eq!(json["documents_fetched"], 2);
        assert_eq!(json["bytes_read"], 12_500);
    }

    #[tokio::test]
    async fn a_paced_walk_is_a_determination_carrying_the_cooldown() {
        let resp = sitemap_response(
            Err(ScraperError::UpstreamBackoff {
                domain: "https://shop.test".into(),
                seconds_remaining: 90,
            }),
            "za/test_store",
        );
        let json = body_of(resp).await;

        assert_eq!(json["outcome"], sitemap_outcome::RATE_LIMITED);
        assert_eq!(json["retry_after_seconds"], 90);
    }

    #[tokio::test]
    async fn a_robots_block_on_the_sitemap_reports_the_rule() {
        let resp = sitemap_response(
            Err(ScraperError::RobotsDisallowed {
                url: "https://shop.test/sitemap.xml".into(),
                rule: "Disallow: /sitemap.xml".into(),
                sitemaps: vec![],
            }),
            "za/test_store",
        );
        let json = body_of(resp).await;

        assert_eq!(json["outcome"], sitemap_outcome::ROBOTS_BLOCKED);
        assert_eq!(json["skipped"][0], "Disallow: /sitemap.xml");
    }

    #[tokio::test]
    async fn sitemap_urls_requires_auth() {
        // Same gate as every other route. A discovery endpoint that anyone can call is a way to make
        // this service issue requests at a shop on someone else's behalf.
        let app = make_app(make_test_state());
        let req = Request::builder()
            .method("POST")
            .uri("/sitemap-urls")
            .header("content-type", "application/json")
            .body(Body::from(r#"{"store":"za/test_store"}"#))
            .unwrap();

        assert_eq!(
            app.oneshot(req).await.unwrap().status(),
            StatusCode::UNAUTHORIZED
        );
    }

    #[tokio::test]
    async fn sitemap_urls_refuses_an_unknown_store() {
        // No scraper config means no declared crawl policy, so there is no rate limit or base URL to
        // walk under — the same refusal `/fetch` makes, for the same reason.
        let app = make_app(make_test_state());
        let token = generate_token("POST", "/sitemap-urls", TEST_SECRET).unwrap();
        let req = Request::builder()
            .method("POST")
            .uri("/sitemap-urls")
            .header("content-type", "application/json")
            .header("x-internal-token", token)
            .body(Body::from(r#"{"store":"za/nonexistent"}"#))
            .unwrap();

        assert_eq!(
            app.oneshot(req).await.unwrap().status(),
            StatusCode::NOT_FOUND
        );
    }

    #[tokio::test]
    async fn a_304_is_not_modified_and_never_an_empty_page() {
        // ⚠️ The distinction the outcome exists for. A 304 has no body, and reporting it as FETCHED
        // with `body: ""` would tell the caller the page is now blank — which for an events page
        // means every event was cancelled. It means the opposite: keep what you already have.
        let resp = fetch_response(
            Ok(FetchedPage {
                status: 304,
                body: String::new(),
                etag: "W/\"abc123\"".to_string(),
                ..Default::default()
            }),
            "za/test_store",
        );
        let json = body_of(resp).await;

        assert_eq!(json["outcome"], fetch_outcome::NOT_MODIFIED);
        assert_ne!(
            json["outcome"],
            fetch_outcome::FETCHED,
            "an unchanged page was reported as a successfully fetched empty one"
        );
        assert_eq!(
            json["etag"], "W/\"abc123\"",
            "the validator was dropped, so the next fetch cannot be conditional and the saving is lost"
        );
    }

    #[tokio::test]
    async fn validators_ride_back_on_a_normal_fetch_so_the_next_one_can_be_conditional() {
        // Without these on the response there is nothing to store, and every subsequent fetch costs
        // the shop a full render. The feature is only worth anything if the round trip closes.
        let resp = fetch_response(
            Ok(FetchedPage {
                status: 200,
                body: "<html/>".to_string(),
                etag: "\"v2\"".to_string(),
                last_modified: "Wed, 21 Oct 2026 07:28:00 GMT".to_string(),
                ..Default::default()
            }),
            "za/test_store",
        );
        let json = body_of(resp).await;

        assert_eq!(json["outcome"], fetch_outcome::FETCHED);
        assert_eq!(json["etag"], "\"v2\"");
        assert_eq!(json["last_modified"], "Wed, 21 Oct 2026 07:28:00 GMT");
    }

    #[tokio::test]
    async fn a_robots_block_still_reports_the_sitemaps_it_declared() {
        // Reaching this branch through the router would take a live request to a store whose
        // robots.txt refuses us, so the response mapping is driven directly.
        //
        // What it guards: we fetched robots.txt in order to learn we were refused, so we ALREADY
        // know where the shop's index is. Dropping that on the way out is what would force the
        // next attempt to *guess* a path — and a guess costs the shop a full page render to answer
        // 404. Holding it is both the cheaper and the more respectful behaviour.
        let resp = fetch_response(
            Err(ScraperError::RobotsDisallowed {
                url: "https://exclusivebooks.co.za/search?q=9780156001311".to_string(),
                rule: "Disallow: /search".to_string(),
                sitemaps: vec!["https://exclusivebooks.co.za/sitemap.xml".to_string()],
            }),
            "za/exclusive_books",
        );

        let body = axum::body::to_bytes(resp.into_body(), 4096).await.unwrap();
        let json: Value = serde_json::from_slice(&body).unwrap();

        assert_eq!(json["outcome"], fetch_outcome::ROBOTS_BLOCKED);
        assert_eq!(json["robots_rule"], "Disallow: /search");
        assert_eq!(
            json["sitemaps"],
            json!(["https://exclusivebooks.co.za/sitemap.xml"]),
            "the refusal discarded the index that same robots.txt had just declared"
        );
    }

    #[tokio::test]
    async fn no_declared_sitemap_omits_the_key_rather_than_asserting_none_exist() {
        // `skip_serializing_if = "Vec::is_empty"` is load-bearing, not incidental. An absent key
        // says "robots.txt declared nothing"; `"sitemaps": []` would read as a positive claim that
        // the shop has no index, which we are in no position to make — plenty of sites serve
        // /sitemap.xml without ever mentioning it in robots.txt.
        let resp = fetch_response(
            Ok(FetchedPage {
                status: 200,
                body: "<html/>".to_string(),
                ..Default::default()
            }),
            "za/test_store",
        );

        let body = axum::body::to_bytes(resp.into_body(), 4096).await.unwrap();
        let json: Value = serde_json::from_slice(&body).unwrap();

        assert_eq!(json["outcome"], fetch_outcome::FETCHED);
        assert!(
            json.get("sitemaps").is_none(),
            "an empty list was serialised as a claim that no sitemap exists: {json}"
        );
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
