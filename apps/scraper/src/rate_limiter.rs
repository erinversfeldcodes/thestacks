use crate::error::ScraperError;
use dashmap::DashMap;
use std::collections::VecDeque;
use std::sync::Arc;
use std::time::{Duration, Instant};

/// A sliding-window, per-domain rate limiter.
///
/// Each domain maintains a queue of timestamps of recent requests.
/// A request is allowed if fewer than `limit` requests have been
/// made within the last 60 seconds.
#[derive(Debug, Clone)]
pub struct RateLimiter {
    /// Maps domain → deque of request timestamps.
    state: Arc<DashMap<String, VecDeque<Instant>>>,
}

impl RateLimiter {
    pub fn new() -> Self {
        Self {
            state: Arc::new(DashMap::new()),
        }
    }

    /// Check whether a request to `domain` is allowed under `requests_per_minute`.
    /// If allowed, records the request and returns Ok(()).
    /// If rate limit is exceeded, returns Err(ScraperError::RateLimitExceeded).
    pub fn check_and_record(
        &self,
        domain: &str,
        requests_per_minute: u32,
    ) -> Result<(), ScraperError> {
        let window = Duration::from_secs(60);
        let now = Instant::now();

        let mut entry = self.state.entry(domain.to_string()).or_default();

        // Evict timestamps older than the sliding window.
        while let Some(&front) = entry.front() {
            if now.duration_since(front) >= window {
                entry.pop_front();
            } else {
                break;
            }
        }

        if entry.len() as u32 >= requests_per_minute {
            return Err(ScraperError::RateLimitExceeded {
                domain: domain.to_string(),
            });
        }

        entry.push_back(now);
        Ok(())
    }

    /// Minimum delay between requests based on `requests_per_minute`.
    pub fn min_delay(requests_per_minute: u32) -> Duration {
        if requests_per_minute == 0 {
            return Duration::from_secs(60);
        }
        Duration::from_millis(60_000 / requests_per_minute as u64)
    }
}

impl Default for RateLimiter {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_allows_requests_under_limit() {
        let limiter = RateLimiter::new();
        // 5 requests/min limit, fire 5 — all should succeed.
        for _ in 0..5 {
            assert!(limiter.check_and_record("example.com", 5).is_ok());
        }
    }

    #[test]
    fn test_rejects_request_over_limit() {
        let limiter = RateLimiter::new();
        // Fill up the limit.
        for _ in 0..3 {
            limiter.check_and_record("example.com", 3).unwrap();
        }
        // Next request should be rejected.
        let result = limiter.check_and_record("example.com", 3);
        assert!(result.is_err());
        assert!(matches!(
            result.unwrap_err(),
            ScraperError::RateLimitExceeded { .. }
        ));
    }

    #[test]
    fn test_separate_domains_tracked_independently() {
        let limiter = RateLimiter::new();
        // Fill up domain A.
        for _ in 0..2 {
            limiter.check_and_record("a.com", 2).unwrap();
        }
        // Domain A is exhausted.
        assert!(limiter.check_and_record("a.com", 2).is_err());
        // Domain B is unaffected.
        assert!(limiter.check_and_record("b.com", 2).is_ok());
    }

    #[test]
    fn test_min_delay_calculation() {
        assert_eq!(RateLimiter::min_delay(10), Duration::from_millis(6000));
        assert_eq!(RateLimiter::min_delay(60), Duration::from_millis(1000));
        assert_eq!(RateLimiter::min_delay(1), Duration::from_millis(60_000));
    }
}
