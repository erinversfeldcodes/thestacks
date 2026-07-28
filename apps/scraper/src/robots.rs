use crate::error::ScraperError;
use dashmap::DashMap;
use std::sync::Arc;
use tokio::sync::OnceCell;

// The User-Agent header for robots.txt fetches comes from the shared
// `reqwest::Client` built in `scraper.rs`, which sets it once for every request
// this service makes. It used to be duplicated here as a second constant, which
// is how the matching bug below arose.

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
}

impl RobotsPolicy {
    /// The policy for "nothing restricts us" — no document, no matching group, or a
    /// 4xx on robots.txt (RFC 9309 §2.3.1.3).
    pub fn unrestricted() -> Self {
        Self {
            allowed: true,
            crawl_delay_secs: None,
            blocked_by: None,
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
}

impl RobotsChecker {
    pub fn new(client: reqwest::Client) -> Self {
        Self {
            cache: Arc::new(DashMap::new()),
            client,
        }
    }

    /// Resolve robots.txt policy for `path` on `base_url`.
    ///
    /// Fetches and caches robots.txt on first call per domain. Concurrent callers
    /// for the same domain wait on the same OnceCell — no stampede.
    ///
    /// Outcomes, per RFC 9309 §2.3.1:
    /// - **2xx** → parse and apply the rules.
    /// - **4xx** → no robots.txt exists; allow all (§2.3.1.3).
    /// - **5xx or transport error** → "unreachable"; §2.3.1.4 says treat as a
    ///   *complete disallow*. We surface `RobotsFetchFailed` so the scrape stops
    ///   with a reason. This is deliberately **not cached**: `get_or_try_init`
    ///   does not store on `Err`, so a transient 503 blocks this attempt only and
    ///   is retried, rather than poisoning the domain for the process lifetime.
    ///   (`kalkbaybooks.co.za` returned 503 during target research, so this path
    ///   is real, not hypothetical.)
    pub async fn policy(&self, base_url: &str, path: &str) -> Result<RobotsPolicy, ScraperError> {
        let domain = extract_domain(base_url).ok_or_else(|| ScraperError::RobotsFetchFailed {
            domain: base_url.to_string(),
            reason: "cannot extract domain from URL".to_string(),
        })?;

        // Clone the Arc out of the DashMap immediately so we don't hold the
        // write-guard across an await point.
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
}

/// Split out from the fetch so the 4xx-vs-5xx distinction is testable without a
/// network or a mock HTTP server. This decision is the whole difference between
/// "no robots.txt exists, crawl freely" and "the server is broken, crawl nothing".
fn classify_status(status: u16) -> StatusVerdict {
    match status {
        200..=299 => StatusVerdict::Fetch,
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

/// Parse robots.txt and decide whether `request_path` is allowed for our token.
///
/// Rules, per RFC 9309:
/// - §2.2.1 Groups are selected by product token. **The most specific matching
///   group wins**: a group naming us explicitly beats `User-agent: *`, and only
///   the winning group's rules are evaluated. Consecutive `User-agent` lines head
///   a single group.
/// - §2.2.2 Longest matching pattern wins; `Allow` beats `Disallow` on equal length.
/// - §2.2.3 `*` matches any sequence of characters; `$` anchors to end of path.
/// - No matching rule → allowed.
///
/// `Crawl-delay` is returned rather than discarded. It is not part of the original
/// standard but is widely deployed, and the owner's hard rule is to respect what
/// robots.txt says — so the engine applies it whenever it is stricter than our own
/// configured rate. (Exclusive Books declares `Crawl-delay: 10`.)
fn parse_and_apply(txt: &str, request_path: &str) -> RobotsPolicy {
    let groups = parse_groups(txt);

    // §2.2.1: prefer a group that names us; fall back to the wildcard group.
    let group = groups
        .iter()
        .find(|g| g.named_us)
        .or_else(|| groups.iter().find(|g| g.wildcard));

    let Some(group) = group else {
        return RobotsPolicy::unrestricted();
    };

    // §2.2.2: longest matching pattern wins; Allow wins ties. The winning pattern is
    // carried alongside the verdict so a disallow can name the rule that caused it.
    let mut best: Option<(usize, bool, &str)> = None;
    for (pattern, allowed) in &group.rules {
        if !path_matches(pattern, request_path) {
            continue;
        }
        let spec = pattern.len();
        let replaces = match best {
            None => true,
            // Allow replaces at equal-or-greater length; Disallow only when strictly longer.
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
        // Only populated on a disallow — see the field's doc comment.
        blocked_by: match best {
            Some((_, false, pattern)) => Some(format!("Disallow: {pattern}")),
            _ => None,
        },
    }
}

/// Split a robots.txt document into `User-agent` groups.
fn parse_groups(txt: &str) -> Vec<Group> {
    let mut groups: Vec<Group> = Vec::new();
    // True while we are reading the consecutive `User-agent:` lines that head a
    // group; the first rule line closes the header and starts the body.
    let mut in_header = false;

    for raw_line in txt.lines() {
        // Strip inline comments, then trim.
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
                    // A `User-agent` line after rule lines starts a new group.
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
                // §2.2.2: an empty `Disallow` imposes no restriction. An empty
                // `Allow` likewise carries no information.
                if value.is_empty() {
                    continue;
                }
                g.rules.push((value.to_string(), key == "allow"));
            }
            "crawl-delay" => {
                in_header = false;
                if let Some(g) = groups.last_mut() {
                    // Accept fractional values by rounding up — a stricter reading.
                    if let Ok(secs) = value.parse::<f64>() {
                        if secs.is_finite() && secs > 0.0 {
                            g.crawl_delay_secs = Some(secs.ceil() as u32);
                        }
                    }
                }
            }
            // `Sitemap` and unknown fields are not group members; ignore them
            // without closing the current header.
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

    // Greedily consume literal segments between wildcards.
    let segments: Vec<&str> = pattern.split('*').collect();
    let last = segments.len() - 1;
    let mut cursor = 0usize;

    for (i, segment) in segments.iter().enumerate() {
        if segment.is_empty() {
            continue;
        }
        if i == 0 {
            // The pattern is anchored at the start of the path.
            if !path[cursor..].starts_with(segment) {
                return false;
            }
            cursor += segment.len();
            continue;
        }
        if i == last && anchored {
            // Final literal must land exactly at the end.
            return path[cursor..].ends_with(segment) && path.len() - cursor >= segment.len();
        }
        match path[cursor..].find(segment) {
            Some(pos) => cursor += pos + segment.len(),
            None => return false,
        }
    }

    // Pattern ended in `*`: anything remaining is fine unless `$` demanded the end,
    // which a trailing `*$` satisfies by construction.
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
        // A block has to be recordable as observable state on the store, and the rule
        // is what makes it actionable: `/search` means try another path, `/` means the
        // store is unscrapable. Without the rule an operator cannot tell them apart.
        let narrow = apply("User-agent: *\nDisallow: /search\n", "/search");
        assert!(!narrow.allowed);
        assert_eq!(narrow.blocked_by.as_deref(), Some("Disallow: /search"));

        let total = apply("User-agent: *\nDisallow: /\n", "/events");
        assert!(!total.allowed);
        assert_eq!(total.blocked_by.as_deref(), Some("Disallow: /"));
    }

    #[test]
    fn test_blocked_by_reports_the_winning_rule_not_the_first_match() {
        // §2.2.2 picks the longest match, so the recorded rule must be the one that
        // actually decided the verdict — reporting the first match would name a rule
        // that was overruled.
        let robots = "User-agent: *\nDisallow: /a\nAllow: /a/b\nDisallow: /a/b/c\n";
        let policy = apply(robots, "/a/b/c/x");
        assert!(!policy.allowed);
        assert_eq!(policy.blocked_by.as_deref(), Some("Disallow: /a/b/c"));
    }

    #[test]
    fn test_blocked_by_is_none_when_allowed() {
        // The field means exactly one thing: "the rule that blocked us". Populating it
        // on an allow would make it read as "the rule we matched" and invite a caller
        // to record a block that never happened.
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
        // RFC 9309 §2.2.2: Allow wins when Disallow and Allow have equal prefix
        // length. Order must not matter.
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
        // Regression: matching used the full UA header ("TheStacksScraper/0.1
        // (+https://…)"), which no operator would ever write. A shop that
        // specifically blocked us was silently ignored because only `*` matched.
        let robots = "User-agent: TheStacksScraper\nDisallow: /\n\nUser-agent: *\nAllow: /\n";
        assert!(
            !apply(robots, "/products.json").allowed,
            "a group naming our product token must win over the wildcard group"
        );
    }

    #[test]
    fn test_named_group_wins_even_when_it_is_more_permissive() {
        // §2.2.1 selects the group, then only that group's rules apply — the
        // wildcard group's Disallow must not leak in.
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
        // Previously `starts_with(pattern)` treated `*` literally, so wildcard
        // rules never matched and disallowed paths were scraped as "allowed".
        let robots = "User-agent: *\nDisallow: /collections/*sort_by*\n";
        assert!(!apply(robots, "/collections/all?sort_by=price").allowed);
        assert!(apply(robots, "/collections/all").allowed);

        let anchored = "User-agent: *\nDisallow: /*.json$\n";
        assert!(!apply(anchored, "/products.json").allowed);
        assert!(apply(anchored, "/products.json?limit=1").allowed);
    }

    #[test]
    fn test_exclusive_books_shape_disallows_search_but_permits_products_json() {
        // The real posture measured on 2026-07-27: `/search` is forbidden while
        // the product JSON API is not. The original TOML scraped `/search`.
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
        // Fractional delays round up — the stricter reading.
        assert_eq!(
            apply("User-agent: *\nCrawl-delay: 0.5\n", "/x").crawl_delay_secs,
            Some(1)
        );
        // Junk and non-positive values are ignored rather than trusted.
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
    fn test_sitemap_does_not_close_a_group_header() {
        // `Sitemap` is not a group member (RFC 9309 §2.2.4); it must not split a group.
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
        // The easy thing to get backwards, and the reason this is a separate
        // function: 404 means "no rules exist, crawl freely" while 503 means
        // "we cannot know the rules, so crawl nothing" (RFC 9309 §2.3.1.3/§2.3.1.4).
        // The previous implementation treated *every* non-2xx as permission.
        assert_eq!(classify_status(200), StatusVerdict::Fetch);
        assert_eq!(classify_status(204), StatusVerdict::Fetch);

        assert_eq!(classify_status(404), StatusVerdict::NoRestrictions);
        assert_eq!(classify_status(401), StatusVerdict::NoRestrictions);
        assert_eq!(classify_status(403), StatusVerdict::NoRestrictions);

        // kalkbaybooks.co.za actually returned 503 during target research.
        assert_eq!(classify_status(503), StatusVerdict::Unreachable);
        assert_eq!(classify_status(500), StatusVerdict::Unreachable);
        assert_eq!(classify_status(502), StatusVerdict::Unreachable);
        // Redirect loops and anything else we can't interpret are also unreachable.
        assert_eq!(classify_status(302), StatusVerdict::Unreachable);
    }
}
