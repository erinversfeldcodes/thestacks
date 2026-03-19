use crate::error::ScraperError;
use dashmap::DashMap;
use std::sync::Arc;

/// User-agent string used when fetching robots.txt.
const USER_AGENT: &str = "TheStacksScraper/0.1 (+https://thestacks.app/scraper)";

/// A cached robots.txt compliance checker.
///
/// Fetches and caches robots.txt per domain. If `respect_robots_txt` is false
/// in the store config, this check is bypassed.
#[derive(Debug, Clone)]
pub struct RobotsChecker {
    /// Maps domain → cached robots.txt text (or None if unavailable).
    cache: Arc<DashMap<String, Option<String>>>,
    client: reqwest::Client,
}

impl RobotsChecker {
    pub fn new(client: reqwest::Client) -> Self {
        Self {
            cache: Arc::new(DashMap::new()),
            client,
        }
    }

    /// Check whether `path` is allowed for our user-agent on `base_url`.
    ///
    /// Fetches and caches robots.txt on first call per domain.
    /// If robots.txt is unavailable, scraping is permitted (lenient).
    pub async fn is_allowed(&self, base_url: &str, path: &str) -> Result<bool, ScraperError> {
        let domain = extract_domain(base_url).ok_or_else(|| ScraperError::RobotsFetchFailed {
            domain: base_url.to_string(),
            reason: "cannot extract domain from URL".to_string(),
        })?;

        // Check cache first.
        if let Some(cached) = self.cache.get(&domain) {
            return Ok(self.check_robots_txt(cached.value().as_deref(), path));
        }

        // Fetch robots.txt.
        let robots_url = format!("{}/robots.txt", base_url.trim_end_matches('/'));
        let robots_text = match self.client.get(&robots_url).send().await {
            Ok(resp) if resp.status().is_success() => Some(resp.text().await.unwrap_or_default()),
            Ok(_) | Err(_) => None, // 404 or network error → no restrictions
        };

        let allowed = self.check_robots_txt(robots_text.as_deref(), path);
        self.cache.insert(domain, robots_text);
        Ok(allowed)
    }

    fn check_robots_txt(&self, robots_txt: Option<&str>, path: &str) -> bool {
        let txt = match robots_txt {
            Some(t) if !t.is_empty() => t,
            _ => return true, // no robots.txt → allowed
        };
        parse_robots_txt(txt, USER_AGENT, path)
    }
}

/// Minimal robots.txt parser. Returns true if `user_agent` is allowed to fetch `path`.
///
/// Rules:
/// - Scans for `User-agent: *` and `User-agent: <our-agent>` blocks.
/// - Within a matching block, collects Disallow/Allow directives.
/// - Longest prefix wins; Allow beats Disallow at equal length.
/// - If no directive matches, the path is allowed.
fn parse_robots_txt(txt: &str, user_agent: &str, request_path: &str) -> bool {
    // Normalise user_agent to lowercase for comparison.
    let ua_lower = user_agent.to_ascii_lowercase();
    // We collect (specificity, allowed) pairs: specificity = prefix length.
    let mut best: Option<(usize, bool)> = None;
    let mut in_matching_block = false;

    for raw_line in txt.lines() {
        let line = raw_line.trim();
        if line.is_empty() || line.starts_with('#') {
            // Blank line ends a block.
            if line.is_empty() {
                in_matching_block = false;
            }
            continue;
        }
        if let Some(rest) = line.strip_prefix("User-agent:") {
            let agent = rest.trim().to_ascii_lowercase();
            in_matching_block = agent == "*" || agent == ua_lower;
            continue;
        }
        if !in_matching_block {
            continue;
        }
        if let Some(rest) = line.strip_prefix("Disallow:") {
            let prefix = rest.trim();
            if prefix.is_empty() {
                // Empty Disallow means "allow everything".
                continue;
            }
            if request_path.starts_with(prefix) {
                let spec = prefix.len();
                if best.is_none_or(|(s, _)| spec >= s) {
                    best = Some((spec, false));
                }
            }
        } else if let Some(rest) = line.strip_prefix("Allow:") {
            let prefix = rest.trim();
            if prefix.is_empty() {
                continue;
            }
            if request_path.starts_with(prefix) {
                let spec = prefix.len();
                if best.is_none_or(|(s, _)| spec >= s) {
                    best = Some((spec, true));
                }
            }
        }
    }

    best.is_none_or(|(_, allowed)| allowed)
}

/// Extract the scheme + host from a URL string.
fn extract_domain(url: &str) -> Option<String> {
    // Minimal extraction: find scheme://host
    let after_scheme = url.split("://").nth(1)?;
    let host = after_scheme.split('/').next()?;
    let scheme = url.split("://").next()?;
    Some(format!("{scheme}://{host}"))
}

#[cfg(test)]
mod tests {
    use super::*;

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
    fn test_check_robots_txt_no_restrictions() {
        let client = reqwest::Client::new();
        let checker = RobotsChecker::new(client);
        // No robots.txt → allowed.
        assert!(checker.check_robots_txt(None, "/search"));
        assert!(checker.check_robots_txt(Some(""), "/search"));
    }

    #[test]
    fn test_check_robots_txt_allows_path() {
        let client = reqwest::Client::new();
        let checker = RobotsChecker::new(client);
        let robots = "User-agent: *\nDisallow: /admin/\nAllow: /search\n";
        assert!(checker.check_robots_txt(Some(robots), "/search"));
    }

    #[test]
    fn test_check_robots_txt_disallows_path() {
        let client = reqwest::Client::new();
        let checker = RobotsChecker::new(client);
        let robots = "User-agent: *\nDisallow: /\n";
        assert!(!checker.check_robots_txt(Some(robots), "/search"));
    }
}
