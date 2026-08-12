use crate::error::ScraperError;
use dashmap::DashMap;
use std::collections::VecDeque;
use std::sync::Arc;
use std::time::{Duration, Instant};

/// Sliding-window per-domain rate limiter, plus the shop's own say in the
/// matter. The window alone is self-certified politeness (our pace, our
/// clock) — a shop's `429 Retry-After` used to be ignored entirely. Now a
/// pacing response records a cooldown: `check_and_record` refuses until it
/// elapses, so the shop's explicit signal outranks our configured rate.
#[derive(Debug, Clone)]
pub struct RateLimiter {
    /// Maps domain → deque of request timestamps.
    state: Arc<DashMap<String, VecDeque<Instant>>>,
    /// Maps domain → the instant a shop-imposed backoff expires.
    cooldowns: Arc<DashMap<String, Instant>>,
}

impl RateLimiter {
    pub fn new() -> Self {
        Self {
            state: Arc::new(DashMap::new()),
            cooldowns: Arc::new(DashMap::new()),
        }
    }

    /// Record that `domain` asked us to stop until `until`.
    ///
    /// **Extends, never shortens.** Two concurrent requests can both be refused, and the second
    /// response may carry a shorter `Retry-After` simply because it was computed a moment later;
    /// taking the smaller value would let the tail of a burst talk us down from the backoff the
    /// shop originally asked for.
    pub fn back_off(&self, domain: &str, until: Instant) {
        self.cooldowns
            .entry(domain.to_string())
            .and_modify(|existing| {
                if until > *existing {
                    *existing = until;
                }
            })
            .or_insert(until);
    }

    /// Check whether a request to `domain` is allowed under `requests_per_minute`.
    /// If allowed, records the request and returns Ok().
    ///
    /// Refuses with `UpstreamBackoff` while the shop's own cooldown is in force, and with
    /// `RateLimitExceeded` when only our configured ceiling is reached. The two are distinct
    /// because they call for different responses: the first means wait, the second means our
    /// config is too aggressive for the work we are asking of it.
    pub fn check_and_record(
        &self,
        domain: &str,
        requests_per_minute: u32,
    ) -> Result<(), ScraperError> {
        let window = Duration::from_secs(60);
        let now = Instant::now();

        if let Some(until) = self.cooldowns.get(domain).map(|r| *r.value()) {
            if now < until {
                return Err(ScraperError::UpstreamBackoff {
                    domain: domain.to_string(),
                    seconds_remaining: (until - now).as_secs(),
                });
            }
            self.cooldowns.remove(domain);
        }

        let mut entry = self.state.entry(domain.to_string()).or_default();

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

    /// How long to wait after a pacing response, from `Retry-After`.
    /// RFC 9110 allows delta-seconds and HTTP-date; only delta-seconds is
    /// parsed — an HTTP-date needs a calendar crate to become a duration, and
    /// the header is overwhelmingly an integer on 429. HTTP-dates take the
    /// `fallback` (the store's configured `retry_after_seconds`): the failure
    /// mode is extra politeness, not a hammer. Result clamped to a sane
    /// ceiling so a hostile header can't park the scraper.
    pub fn retry_after(header: Option<&str>, fallback_secs: u64) -> Duration {
        const CEILING_SECS: u64 = 3600;

        let secs = header
            .map(str::trim)
            .and_then(|raw| raw.parse::<u64>().ok())
            .unwrap_or(fallback_secs);

        Duration::from_secs(secs.clamp(1, CEILING_SECS))
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
        for _ in 0..5 {
            assert!(limiter.check_and_record("example.com", 5).is_ok());
        }
    }

    #[test]
    fn test_rejects_request_over_limit() {
        let limiter = RateLimiter::new();
        for _ in 0..3 {
            limiter.check_and_record("example.com", 3).unwrap();
        }
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
        for _ in 0..2 {
            limiter.check_and_record("a.com", 2).unwrap();
        }
        assert!(limiter.check_and_record("a.com", 2).is_err());
        assert!(limiter.check_and_record("b.com", 2).is_ok());
    }

    #[test]
    fn a_cooldown_refuses_a_domain_whose_own_window_is_empty() {
        let limiter = RateLimiter::new();
        limiter.back_off("example.com", Instant::now() + Duration::from_secs(60));

        let err = limiter
            .check_and_record("example.com", 60)
            .expect_err("a request went out during a cooldown the shop asked for");

        assert!(
            matches!(err, ScraperError::UpstreamBackoff { .. }),
            "reported as our own ceiling rather than the shop's instruction: {err:?}"
        );
    }

    #[test]
    fn a_backoff_is_distinguishable_from_our_own_ceiling() {
        let limiter = RateLimiter::new();

        limiter.back_off("paced.com", Instant::now() + Duration::from_secs(30));
        for _ in 0..2 {
            limiter.check_and_record("ours.com", 2).unwrap();
        }

        assert!(matches!(
            limiter.check_and_record("paced.com", 60).unwrap_err(),
            ScraperError::UpstreamBackoff { .. }
        ));
        assert!(matches!(
            limiter.check_and_record("ours.com", 2).unwrap_err(),
            ScraperError::RateLimitExceeded { .. }
        ));
    }

    #[test]
    fn the_shops_instruction_is_reported_ahead_of_our_own_ceiling() {
        let limiter = RateLimiter::new();

        for _ in 0..2 {
            limiter.check_and_record("example.com", 2).unwrap();
        }
        limiter.back_off("example.com", Instant::now() + Duration::from_secs(60));

        let err = limiter.check_and_record("example.com", 2).unwrap_err();
        assert!(
            matches!(err, ScraperError::UpstreamBackoff { .. }),
            "our own ceiling was reported ahead of the shop's explicit instruction: {err:?}"
        );
    }

    #[test]
    fn back_off_extends_but_never_shortens() {
        let limiter = RateLimiter::new();
        let long = Instant::now() + Duration::from_secs(600);

        limiter.back_off("example.com", long);
        limiter.back_off("example.com", Instant::now() + Duration::from_secs(5));

        match limiter.check_and_record("example.com", 60).unwrap_err() {
            ScraperError::UpstreamBackoff {
                seconds_remaining, ..
            } => assert!(
                seconds_remaining > 60,
                "the longer cooldown was shortened to {seconds_remaining}s by a later, smaller one"
            ),
            other => panic!("expected UpstreamBackoff, got {other:?}"),
        }
    }

    #[test]
    fn an_elapsed_cooldown_lets_requests_through_again() {
        // Being paced must resolve by itself. Unlike a robots.txt disallow this one is temporary,
        // and a cooldown that never expires would be indistinguishable from a permanent block.
        let limiter = RateLimiter::new();
        limiter.back_off("example.com", Instant::now() - Duration::from_secs(1));

        assert!(
            limiter.check_and_record("example.com", 60).is_ok(),
            "an expired cooldown still refused the request"
        );
    }

    #[test]
    fn a_cooldown_is_per_domain() {
        let limiter = RateLimiter::new();
        limiter.back_off("paced.com", Instant::now() + Duration::from_secs(60));

        assert!(limiter.check_and_record("paced.com", 60).is_err());
        assert!(limiter.check_and_record("other.com", 60).is_ok());
    }

    #[test]
    fn retry_after_reads_delta_seconds_and_falls_back_otherwise() {
        let cases: [(Option<&str>, u64, u64, &str); 6] = [
            (Some("120"), 60, 120, "plain delta-seconds"),
            (Some("  90 "), 60, 90, "surrounding whitespace"),
            (
                None,
                60,
                60,
                "no header at all → the store's configured fallback",
            ),
            (
                Some("Wed, 21 Oct 2026 07:28:00 GMT"),
                60,
                60,
                "an HTTP-date is not parsed; it must fall back, not become zero",
            ),
            (
                Some("0"),
                60,
                1,
                "a literal 0 is floored, not treated as 'no cooldown'",
            ),
            (
                Some("999999999"),
                60,
                3600,
                "a hostile value is clamped so it cannot park the domain for the process lifetime",
            ),
        ];

        for (header, fallback, expected, why) in cases {
            assert_eq!(
                RateLimiter::retry_after(header, fallback),
                Duration::from_secs(expected),
                "{why} (header={header:?})"
            );
        }
    }

    #[test]
    fn test_min_delay_calculation() {
        assert_eq!(RateLimiter::min_delay(10), Duration::from_millis(6000));
        assert_eq!(RateLimiter::min_delay(60), Duration::from_millis(1000));
        assert_eq!(RateLimiter::min_delay(1), Duration::from_millis(60_000));
    }
}
