use crate::error::ScraperError;
use crate::rate_limiter::RateLimiter;
use dashmap::DashMap;
use std::sync::Arc;
use std::time::Instant;
use tokio::sync::OnceCell;

/// The robots.txt *product token* for this crawler, lowercased.
///
/// This is deliberately NOT the full `USER_AGENT` string. RFC 9309 §2.2.1 matches
/// a bare product token, so an operator writes `User-agent: TheStacksScraper` —
/// never the version and contact URL. Comparing against the full header meant a
/// site could not address us by name at all: only `User-agent: *` ever matched,
/// so a shop that specifically wanted to block us was silently ignored.
const PRODUCT_TOKEN: &str = "thestacksscraper";

/// What robots.txt says about a path, for our product token.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RobotsPolicy {
    pub allowed: bool,
    /// `Crawl-delay` from the matching group, if declared.
    pub crawl_delay_secs: Option<u32>,
    /// The `Disallow` pattern that blocked this path — `Some` **only** when
    /// `allowed` is false, so the field means exactly one thing and cannot be
    /// misread as "the rule we matched".
    ///
    /// Carried because a block needs to be *observable state* on the store rather
    /// than a silent skip: without the rule, an operator seeing a blocked store has
    /// no way to tell whether the disallow was narrow (`/search`) or total (`/`),
    /// and therefore no way to know whether the store is permanently unscrapable or
    /// merely needs a different path.
    pub blocked_by: Option<String>,
    /// `Sitemap:` URLs declared in the document, in order.
    ///
    /// Retained for the same reason `crawl_delay_secs` is: it is not a group member
    /// (RFC 9309 §2.2.4), but it is *the shop telling us where its content index is*,
    /// and we are already paying for this fetch on every request.
    ///
    /// This is what makes polite discovery possible. Guessing a path costs the shop a
    /// full page render — measured at **249,540 bytes** for a Shopify 404 — whereas a
    /// sitemap index is ~10 KB and says exactly which pages exist. Harvesting a value
    /// we already have in hand is strictly cheaper for them than asking again.
    pub sitemaps: Vec<String>,
}

impl RobotsPolicy {
    /// The policy for "nothing restricts us" — no document, no matching group, or a
    /// 4xx on robots.txt (RFC 9309 §2.3.1.3).
    pub fn unrestricted() -> Self {
        Self {
            allowed: true,
            crawl_delay_secs: None,
            blocked_by: None,
            sitemaps: Vec::new(),
        }
    }
}

/// One `User-agent` group from a robots.txt document.
#[derive(Debug, Default)]
struct Group {
    /// True if this group is headed by `User-agent: *`.
    wildcard: bool,
    /// True if this group names our product token explicitly.
    named_us: bool,
    /// `(pattern, allowed)` rules in document order.
    rules: Vec<(String, bool)>,
    crawl_delay_secs: Option<u32>,
}

/// A robots.txt document as resolved for a domain.
#[derive(Debug, Clone)]
enum RobotsDoc {
    /// Fetched successfully — these are the rules.
    Rules(String),
    /// Server said "no robots.txt here" (4xx). RFC 9309 §2.3.1.3: allow all.
    Absent,
}

/// A cached robots.txt compliance checker.
///
/// Fetches and caches robots.txt per domain. Compliance is **not optional** — there
/// is deliberately no flag to switch it off, so no configuration can opt a store out
/// of it (owner hard rule, 2026-07-27).
///
/// Each domain key maps to an `Arc<OnceCell<...>>` so that concurrent requests
/// for the same uncached domain wait on a single in-flight HTTP fetch rather
/// than stampeding — the OnceCell guarantees exactly one initialisation.
#[derive(Debug, Clone)]
pub struct RobotsChecker {
    /// Maps domain → once-initialised robots.txt document.
    cache: Arc<DashMap<String, Arc<OnceCell<RobotsDoc>>>>,
    client: reqwest::Client,
    /// Shared with `Engine`, so a 429 seen while fetching robots.txt paces the *page* requests
    /// too. Holding it here rather than reporting upward is the point: the component that observes
    /// the signal is the one that records it, and there is no step in between for anyone to forget.
    rate_limiter: RateLimiter,
}

impl RobotsChecker {
    pub fn new(client: reqwest::Client, rate_limiter: RateLimiter) -> Self {
        Self {
            cache: Arc::new(DashMap::new()),
            client,
            rate_limiter,
        }
    }

    /// Resolve robots.txt policy for `path` on `base_url`. Fetched and cached
    /// once per domain (concurrent callers share the OnceCell — no stampede).
    /// Per RFC 9309 §2.3.1: 2xx → parse and apply; 4xx → no robots.txt, allow
    /// all; 5xx/transport error → complete disallow, surfaced as
    /// `RobotsFetchFailed` and deliberately NOT cached (`get_or_try_init` skips
    /// storing on Err), so a transient 503 blocks one attempt, not the domain.
    pub async fn policy(
        &self,
        base_url: &str,
        path: &str,
        default_retry_after_secs: u64,
    ) -> Result<RobotsPolicy, ScraperError> {
        let domain = extract_domain(base_url).ok_or_else(|| ScraperError::RobotsFetchFailed {
            domain: base_url.to_string(),
            reason: "cannot extract domain from URL".to_string(),
        })?;

        let cell: Arc<OnceCell<RobotsDoc>> = self
            .cache
            .entry(domain.clone())
            .or_insert_with(|| Arc::new(OnceCell::new()))
            .clone();

        let doc = cell
            .get_or_try_init(|| async {
                let robots_url = format!("{domain}/robots.txt");
                match self.client.get(&robots_url).send().await {
                    Ok(resp) => {
                        let status = resp.status().as_u16();
                        match classify_status(status) {
                            StatusVerdict::Fetch => resp
                                .text()
                                .await
                                .map(RobotsDoc::Rules)
                                .map_err(|e| ScraperError::RobotsFetchFailed {
                                    domain: domain.clone(),
                                    reason: format!("could not read robots.txt body: {e}"),
                                }),
                            StatusVerdict::NoRestrictions => Ok(RobotsDoc::Absent),
                            StatusVerdict::Paced => {
                                let wait = RateLimiter::retry_after(
                                    resp.headers()
                                        .get("retry-after")
                                        .and_then(|v| v.to_str().ok()),
                                    default_retry_after_secs,
                                );
                                self.rate_limiter.back_off(&domain, Instant::now() + wait);

                                Err(ScraperError::UpstreamBackoff {
                                    domain: domain.clone(),
                                    seconds_remaining: wait.as_secs(),
                                })
                            }
                            StatusVerdict::Unreachable => {
                                Err(ScraperError::RobotsFetchFailed {
                                    domain: domain.clone(),
                                    reason: format!(
                                        "robots.txt unreachable (HTTP {status}); treating as disallow per RFC 9309 §2.3.1.4"
                                    ),
                                })
                            }
                        }
                    }
                    Err(e) => Err(ScraperError::RobotsFetchFailed {
                        domain: domain.clone(),
                        reason: format!(
                            "robots.txt unreachable ({e}); treating as disallow per RFC 9309 §2.3.1.4"
                        ),
                    }),
                }
            })
            .await?;

        Ok(evaluate(doc, path))
    }
}

/// What a robots.txt HTTP status means for crawl permission.
#[derive(Debug, PartialEq, Eq)]
enum StatusVerdict {
    /// 2xx — read the body and apply its rules.
    Fetch,
    /// 4xx — robots.txt genuinely absent, so nothing is restricted (RFC 9309 §2.3.1.3).
    NoRestrictions,
    /// 5xx and anything else — "unreachable". RFC 9309 §2.3.1.4 says treat this as a
    /// *complete disallow*, which is the opposite of the absent case and the easy
    /// thing to get backwards.
    Unreachable,
    /// 429 / 503 — the shop is pacing us. Not a verdict about its *rules* at all: we
    /// have learned nothing about what we may crawl, only that we must wait.
    Paced,
}

/// Split from the fetch so the 4xx-vs-5xx decision — "no robots.txt,
/// crawl freely" vs "server broken, crawl nothing" — is testable offline.
///
/// 429 and 503 are a deliberate deviation from RFC 9309's pure range
/// classification: both mean "not now", and reading a rate-limit response
/// as permission to crawl everything is the opposite of its meaning. Both
/// are treated as unreachable (disallow).
fn classify_status(status: u16) -> StatusVerdict {
    match status {
        200..=299 => StatusVerdict::Fetch,
        429 | 503 => StatusVerdict::Paced,
        400..=499 => StatusVerdict::NoRestrictions,
        _ => StatusVerdict::Unreachable,
    }
}

/// Apply a resolved robots.txt document to a path.
fn evaluate(doc: &RobotsDoc, path: &str) -> RobotsPolicy {
    let txt = match doc {
        RobotsDoc::Absent => return RobotsPolicy::unrestricted(),
        RobotsDoc::Rules(t) if t.trim().is_empty() => return RobotsPolicy::unrestricted(),
        RobotsDoc::Rules(t) => t,
    };
    parse_and_apply(txt, path)
}

/// Parse robots.txt and decide whether `request_path` is allowed for our
/// token, per RFC 9309: most specific matching group wins (§2.2.1, an
/// explicit naming beats `*`; consecutive User-agent lines head one group);
/// longest matching pattern wins, Allow beats Disallow on ties (§2.2.2);
/// `*` and `$` wildcards (§2.2.3); no matching rule → allowed.
/// `Crawl-delay` is returned, not discarded — `document_spacing` honours it
/// as a per-request spacing.
fn parse_and_apply(txt: &str, request_path: &str) -> RobotsPolicy {
    let groups = parse_groups(txt);
    let sitemaps = parse_sitemaps(txt);

    let group = groups
        .iter()
        .find(|g| g.named_us)
        .or_else(|| groups.iter().find(|g| g.wildcard));

    let Some(group) = group else {
        return RobotsPolicy {
            sitemaps,
            ..RobotsPolicy::unrestricted()
        };
    };

    let mut best: Option<(usize, bool, &str)> = None;
    for (pattern, allowed) in &group.rules {
        if !path_matches(pattern, request_path) {
            continue;
        }
        let spec = pattern.len();
        let replaces = match best {
            None => true,
            Some((s, _, _)) if *allowed => spec >= s,
            Some((s, _, _)) => spec > s,
        };
        if replaces {
            best = Some((spec, *allowed, pattern));
        }
    }

    let allowed = best.is_none_or(|(_, allowed, _)| allowed);

    RobotsPolicy {
        allowed,
        crawl_delay_secs: group.crawl_delay_secs,
        blocked_by: match best {
            Some((_, false, pattern)) => Some(format!("Disallow: {pattern}")),
            _ => None,
        },
        sitemaps,
    }
}

/// Collect `Sitemap:` URLs from the whole document.
///
/// ⚠️ **Document-level, deliberately not read from the winning group.** RFC 9309 §2.2.4 makes
/// `Sitemap` a non-group field, so it may appear before any `User-agent` line, between groups, or
/// after all of them — and it applies regardless of which group matched us. Reading it while walking
/// groups would silently drop declarations that sit outside one, which is where shops commonly put
/// them (both bookshops measured on 2026-07-29 declare it at the end of the file).
///
/// Duplicates are dropped: Exclusive Books declares the same sitemap twice, and fetching it twice
/// would cost the shop double for nothing.
fn parse_sitemaps(txt: &str) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();

    for line in txt.lines() {
        let line = line.split('#').next().unwrap_or("");
        let Some((field, value)) = line.split_once(':') else {
            continue;
        };
        if !field.trim().eq_ignore_ascii_case("sitemap") {
            continue;
        }
        let url = value.trim().to_string();
        if url.is_empty() || out.contains(&url) {
            continue;
        }
        out.push(url);
    }

    out
}

/// Split a robots.txt document into `User-agent` groups.
fn parse_groups(txt: &str) -> Vec<Group> {
    let mut groups: Vec<Group> = Vec::new();
    let mut in_header = false;

    for raw_line in txt.lines() {
        let line = raw_line.split('#').next().unwrap_or("").trim();
        if line.is_empty() {
            continue;
        }

        let Some((key, value)) = line.split_once(':') else {
            continue;
        };
        let key = key.trim().to_ascii_lowercase();
        let value = value.trim();

        match key.as_str() {
            "user-agent" => {
                let agent = value.to_ascii_lowercase();
                if !in_header {
                    groups.push(Group::default());
                    in_header = true;
                }
                let g = groups.last_mut().expect("just pushed");
                if agent == "*" {
                    g.wildcard = true;
                } else if agent == PRODUCT_TOKEN {
                    g.named_us = true;
                }
            }
            "disallow" | "allow" => {
                in_header = false;
                let Some(g) = groups.last_mut() else { continue };
                if value.is_empty() {
                    continue;
                }
                g.rules.push((value.to_string(), key == "allow"));
            }
            "crawl-delay" => {
                in_header = false;
                if let Some(g) = groups.last_mut() {
                    if let Ok(secs) = value.parse::<f64>() {
                        if secs.is_finite() && secs > 0.0 {
                            g.crawl_delay_secs = Some(secs.ceil() as u32);
                        }
                    }
                }
            }
            _ => {}
        }
    }

    groups
}

/// RFC 9309 §2.2.3 path matching: `*` matches any sequence, a trailing `$`
/// anchors the match to the end of the path.
fn path_matches(pattern: &str, path: &str) -> bool {
    let (pattern, anchored) = match pattern.strip_suffix('$') {
        Some(p) => (p, true),
        None => (pattern, false),
    };

    if !pattern.contains('*') {
        return if anchored {
            path == pattern
        } else {
            path.starts_with(pattern)
        };
    }

    let segments: Vec<&str> = pattern.split('*').collect();
    let last = segments.len() - 1;
    let mut cursor = 0usize;

    for (i, segment) in segments.iter().enumerate() {
        if segment.is_empty() {
            continue;
        }
        if i == 0 {
            if !path[cursor..].starts_with(segment) {
                return false;
            }
            cursor += segment.len();
            continue;
        }
        if i == last && anchored {
            return path[cursor..].ends_with(segment) && path.len() - cursor >= segment.len();
        }
        match path[cursor..].find(segment) {
            Some(pos) => cursor += pos + segment.len(),
            None => return false,
        }
    }

    true
}

/// Extract the scheme + host from a URL string.
/// Returns None for non-HTTP(S) schemes to prevent file:// or ftp:// URLs
/// from being passed to the HTTP client.
fn extract_domain(url: &str) -> Option<String> {
    let (scheme, rest) = url.split_once("://")?;
    if !matches!(scheme, "http" | "https") {
        return None;
    }
    let host = rest.split('/').next()?;
    Some(format!("{scheme}://{host}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn apply(robots: &str, path: &str) -> RobotsPolicy {
        parse_and_apply(robots, path)
    }

    #[test]
    fn test_extract_domain() {
        assert_eq!(
            extract_domain("https://www.exclusivebooks.co.za/search?q=foo"),
            Some("https://www.exclusivebooks.co.za".to_string())
        );
        assert_eq!(
            extract_domain("http://example.com"),
            Some("http://example.com".to_string())
        );
        assert_eq!(extract_domain("not-a-url"), None);
    }

    #[test]
    fn test_extract_domain_rejects_non_http_schemes() {
        assert_eq!(extract_domain("file:///etc/passwd"), None);
        assert_eq!(extract_domain("ftp://example.com/pub"), None);
        assert_eq!(extract_domain("javascript://x"), None);
    }

    #[test]
    fn test_absent_robots_allows_everything() {
        assert!(evaluate(&RobotsDoc::Absent, "/search").allowed);
        assert!(evaluate(&RobotsDoc::Rules(String::new()), "/search").allowed);
    }

    #[test]
    fn test_allows_and_disallows_paths() {
        let robots = "User-agent: *\nDisallow: /admin/\nAllow: /search\n";
        assert!(apply(robots, "/search").allowed);
        assert!(!apply(robots, "/admin/users").allowed);

        assert!(!apply("User-agent: *\nDisallow: /\n", "/search").allowed);
    }

    #[test]
    fn test_blocked_by_names_the_rule_that_blocked_us() {
        let narrow = apply("User-agent: *\nDisallow: /search\n", "/search");
        assert!(!narrow.allowed);
        assert_eq!(narrow.blocked_by.as_deref(), Some("Disallow: /search"));

        let total = apply("User-agent: *\nDisallow: /\n", "/events");
        assert!(!total.allowed);
        assert_eq!(total.blocked_by.as_deref(), Some("Disallow: /"));
    }

    #[test]
    fn test_blocked_by_reports_the_winning_rule_not_the_first_match() {
        let robots = "User-agent: *\nDisallow: /a\nAllow: /a/b\nDisallow: /a/b/c\n";
        let policy = apply(robots, "/a/b/c/x");
        assert!(!policy.allowed);
        assert_eq!(policy.blocked_by.as_deref(), Some("Disallow: /a/b/c"));
    }

    #[test]
    fn test_blocked_by_is_none_when_allowed() {
        assert_eq!(
            apply("User-agent: *\nAllow: /\n", "/events").blocked_by,
            None
        );
        assert_eq!(
            apply("User-agent: *\nDisallow: /admin\n", "/events").blocked_by,
            None
        );
        assert_eq!(RobotsPolicy::unrestricted().blocked_by, None);
    }

    #[test]
    fn test_allow_beats_disallow_at_equal_length() {
        let disallow_first = "User-agent: *\nDisallow: /search\nAllow: /search\n";
        assert!(apply(disallow_first, "/search").allowed);

        let allow_first = "User-agent: *\nAllow: /search\nDisallow: /search\n";
        assert!(apply(allow_first, "/search").allowed);
    }

    #[test]
    fn test_longest_pattern_wins() {
        let robots = "User-agent: *\nDisallow: /a\nAllow: /a/b\nDisallow: /a/b/c\n";
        assert!(!apply(robots, "/a/x").allowed);
        assert!(apply(robots, "/a/b/x").allowed);
        assert!(!apply(robots, "/a/b/c/x").allowed);
    }

    #[test]
    fn test_a_site_can_address_us_by_our_product_token() {
        let robots = "User-agent: TheStacksScraper\nDisallow: /\n\nUser-agent: *\nAllow: /\n";
        assert!(
            !apply(robots, "/products.json").allowed,
            "a group naming our product token must win over the wildcard group"
        );
    }

    #[test]
    fn test_named_group_wins_even_when_it_is_more_permissive() {
        let robots = "User-agent: *\nDisallow: /\n\nUser-agent: thestacksscraper\nAllow: /\n";
        assert!(apply(robots, "/products.json").allowed);
    }

    #[test]
    fn test_consecutive_user_agent_lines_head_one_group() {
        let robots = "User-agent: SomeBot\nUser-agent: *\nDisallow: /private\n";
        assert!(!apply(robots, "/private/x").allowed);
        assert!(apply(robots, "/public").allowed);
    }

    #[test]
    fn test_wildcard_and_anchor_patterns() {
        let robots = "User-agent: *\nDisallow: /collections/*sort_by*\n";
        assert!(!apply(robots, "/collections/all?sort_by=price").allowed);
        assert!(apply(robots, "/collections/all").allowed);

        let anchored = "User-agent: *\nDisallow: /*.json$\n";
        assert!(!apply(anchored, "/products.json").allowed);
        assert!(apply(anchored, "/products.json?limit=1").allowed);
    }

    #[test]
    fn test_exclusive_books_shape_disallows_search_but_permits_products_json() {
        let robots = "User-agent: MJ12bot\nDisallow: /\n\n\
                      User-agent: *\n\
                      Disallow: /admin\n\
                      Disallow: /cart\n\
                      Disallow: /search\n\
                      Disallow: /collections/*sort_by*\n\
                      Crawl-delay: 10\n\
                      Sitemap: https://exclusivebooks.co.za/sitemap.xml\n";

        let search = apply(robots, "/search?q=9780156001311");
        assert!(!search.allowed, "/search must be refused");

        let api = apply(robots, "/products/9780749397050.js");
        assert!(api.allowed, "/products/<isbn>.js must be permitted");
        assert_eq!(
            api.crawl_delay_secs,
            Some(10),
            "Crawl-delay must be surfaced, not discarded"
        );
    }

    #[test]
    fn test_crawl_delay_parsing() {
        assert_eq!(
            apply("User-agent: *\nCrawl-delay: 10\n", "/x").crawl_delay_secs,
            Some(10)
        );
        assert_eq!(
            apply("User-agent: *\nCrawl-delay: 0.5\n", "/x").crawl_delay_secs,
            Some(1)
        );
        assert_eq!(
            apply("User-agent: *\nCrawl-delay: soon\n", "/x").crawl_delay_secs,
            None
        );
        assert_eq!(
            apply("User-agent: *\nCrawl-delay: 0\n", "/x").crawl_delay_secs,
            None
        );
    }

    #[test]
    fn test_sitemap_urls_are_retained() {
        let robots = "User-agent: *\nDisallow: /admin\nSitemap: https://shop.test/sitemap.xml\n";
        let policy = apply(robots, "/events");
        assert_eq!(policy.sitemaps, vec!["https://shop.test/sitemap.xml"]);
    }

    #[test]
    fn test_sitemap_is_read_from_outside_any_group() {
        let robots = "Sitemap: https://shop.test/sitemap.xml\nUser-agent: *\nDisallow: /admin\n";
        let policy = apply(robots, "/events");
        assert_eq!(policy.sitemaps, vec!["https://shop.test/sitemap.xml"]);
    }

    #[test]
    fn test_sitemap_survives_when_no_group_applies_to_us() {
        let robots = "Sitemap: https://shop.test/sitemap.xml\n";
        let policy = apply(robots, "/events");
        assert!(policy.allowed);
        assert_eq!(policy.sitemaps, vec!["https://shop.test/sitemap.xml"]);
    }

    #[test]
    fn test_duplicate_sitemaps_are_dropped() {
        let robots = "Sitemap: https://shop.test/sitemap.xml\nUser-agent: *\nSitemap: https://shop.test/sitemap.xml\n";
        let policy = apply(robots, "/events");
        assert_eq!(policy.sitemaps.len(), 1);
    }

    #[test]
    fn test_multiple_distinct_sitemaps_are_all_kept_in_order() {
        let robots = "Sitemap: https://shop.test/a.xml\nSitemap: https://shop.test/b.xml\n";
        let policy = apply(robots, "/events");
        assert_eq!(
            policy.sitemaps,
            vec!["https://shop.test/a.xml", "https://shop.test/b.xml"]
        );
    }

    #[test]
    fn test_sitemap_comment_is_stripped_and_url_scheme_survives() {
        let robots = "Sitemap: https://shop.test/sitemap.xml  # the index\n";
        let policy = apply(robots, "/events");
        assert_eq!(policy.sitemaps, vec!["https://shop.test/sitemap.xml"]);
    }

    #[test]
    fn test_a_disallowed_path_still_reports_the_sitemap() {
        let robots = "User-agent: *\nDisallow: /events\nSitemap: https://shop.test/sitemap.xml\n";
        let policy = apply(robots, "/events");
        assert!(!policy.allowed);
        assert_eq!(policy.sitemaps, vec!["https://shop.test/sitemap.xml"]);
    }

    #[test]
    fn test_sitemap_does_not_close_a_group_header() {
        let robots = "User-agent: *\nSitemap: https://x/s.xml\nDisallow: /nope\n";
        assert!(!apply(robots, "/nope").allowed);
    }

    #[test]
    fn test_inline_comments_are_stripped() {
        let robots = "User-agent: *   # everyone\nDisallow: /admin   # keep out\n";
        assert!(!apply(robots, "/admin/x").allowed);
        assert!(apply(robots, "/public").allowed);
    }

    #[test]
    fn test_empty_disallow_imposes_no_restriction() {
        assert!(apply("User-agent: *\nDisallow:\n", "/anything").allowed);
    }

    #[test]
    fn test_status_classification_distinguishes_absent_from_unreachable() {
        assert_eq!(classify_status(200), StatusVerdict::Fetch);
        assert_eq!(classify_status(204), StatusVerdict::Fetch);

        assert_eq!(classify_status(404), StatusVerdict::NoRestrictions);
        assert_eq!(classify_status(401), StatusVerdict::NoRestrictions);
        assert_eq!(classify_status(403), StatusVerdict::NoRestrictions);

        assert_eq!(classify_status(500), StatusVerdict::Unreachable);
        assert_eq!(classify_status(502), StatusVerdict::Unreachable);
        assert_eq!(classify_status(302), StatusVerdict::Unreachable);
    }

    #[test]
    fn a_429_on_robots_txt_is_not_permission_to_crawl_everything() {
        assert_eq!(classify_status(429), StatusVerdict::Paced);
        assert_ne!(
            classify_status(429),
            StatusVerdict::NoRestrictions,
            "429 was read as 'no robots.txt exists, crawl freely'"
        );
    }

    #[test]
    fn a_503_paces_rather_than_merely_failing() {
        assert_eq!(classify_status(503), StatusVerdict::Paced);
    }
}
