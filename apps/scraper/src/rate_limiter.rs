use crate::error::ScraperError;
use dashmap::DashMap;
use std::collections::VecDeque;
use std::sync::Arc;
use std::time::{Duration, Instant};

/// A sliding-window, per-domain rate limiter — plus the shop's own say in the matter.
///
/// Each domain maintains a queue of timestamps of recent requests. A request is allowed if fewer
/// than `limit` requests have been made within the last 60 seconds.
///
/// ⚠️ **The sliding window alone is self-certified politeness.** It encodes the pace *we* chose,
/// measured by *our* clock, and for a long time it was the only pacing this service had — so a shop
/// answering `429 Too Many Requests` with a `Retry-After` header was ignored, and we carried on at
/// our configured rate. (Measured during #307: a handful of probes from one laptop got
/// `429` on every path of both target shops, including `/robots.txt`.) `cooldowns` is the missing
/// channel: the domain's own instruction, which outranks our configuration.
///
/// The cooldown is consulted **inside `check_and_record`** rather than exposed for callers to check.
/// That is deliberate and is the whole design: every egress path already calls this one function, so
/// the backoff cannot be bypassed by a caller who forgets it. A `should_i_wait()` helper would
/// reproduce exactly the bug this exists to fix.
///
/// ⚠️ Both maps are per-process and in-memory, so a redeploy forgets an active cooldown. That is
/// consistent with the rest of this service (the ISBN index has the same lifetime) but it is a real
/// limitation, not an oversight: right after a deploy we may resume asking a shop that had told us
/// to wait. Persisting it is a separate decision, deliberately not taken here.
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
    /// If allowed, records the request and returns Ok(()).
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

        // The shop's instruction is checked FIRST, and before the window is touched. Checking it
        // second would mean a domain whose 60-second window has drained is let through mid-cooldown
        // — which is most of the time, since a cooldown typically outlasts the window.
        if let Some(until) = self.cooldowns.get(domain).map(|r| *r.value()) {
            if now < until {
                return Err(ScraperError::UpstreamBackoff {
                    domain: domain.to_string(),
                    seconds_remaining: (until - now).as_secs(),
                });
            }
            // Expired. Drop it so the map does not grow without bound across a long-lived process.
            self.cooldowns.remove(domain);
        }

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

    /// How long to wait after a pacing response, from the shop's `Retry-After` header.
    ///
    /// RFC 9110 §10.2.3 allows two forms: delta-seconds, and an HTTP-date.
    ///
    /// ⚠️ **Only delta-seconds is parsed.** An HTTP-date needs a real calendar to turn into a
    /// duration, and this service has no date crate — adding one to read a header that is
    /// overwhelmingly sent as an integer on 429 is not a trade worth making. An HTTP-date therefore
    /// takes the `fallback` path, which is the store's configured `retry_after_seconds`: a
    /// conservative wait rather than no wait, so the failure mode is politeness, not a hammer.
    ///
    /// The result is clamped to `[1s, 1h]`:
    /// - the floor, because `Retry-After: 0` immediately after a 429 is not an instruction worth
    ///   obeying literally, and a zero cooldown would read as "no cooldown" at the call site;
    /// - the ceiling, because a mistaken or hostile `Retry-After: 999999999` would otherwise park a
    ///   domain for as long as the process lives. An hour is far longer than any real pacing signal
    ///   and still recovers without a redeploy.
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

    // ------------------------------------------------------------------
    // Shop-imposed backoff — the channel the limiter used to lack entirely
    // ------------------------------------------------------------------

    #[test]
    fn a_cooldown_refuses_a_domain_whose_own_window_is_empty() {
        // The load-bearing case: a cooldown typically outlasts the 60-second window, so by the time
        // we would next consider asking, our own limiter has nothing against it. Without the
        // cooldown the request goes straight out in the middle of a backoff we were told to observe.
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
        // Two different operator responses: widen our config, versus wait. Collapsing them into one
        // error would have someone tuning `requests_per_minute` at a signal unrelated to it.
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
        // This is the test that actually pins the ORDER of the two checks, which the one above does
        // not: with an empty window, either order returns `UpstreamBackoff`. Only when BOTH would
        // refuse does the order become observable.
        //
        // Why it matters is diagnostic honesty. Reporting `RateLimitExceeded` here sends an operator
        // to widen `requests_per_minute` — the exact wrong move against a shop that has just told us
        // there are already too many requests.
        let limiter = RateLimiter::new();

        // Fill our own window first; it has to be done before the cooldown, since a cooldown would
        // refuse these very calls.
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
        // A burst can have several requests refused at once, and a later response may carry a
        // shorter `Retry-After` purely because it was computed a moment later. Taking the smaller
        // value would let the tail of the burst talk us down from the wait we were actually asked
        // for — the bug being pre-empted here, not a hypothetical.
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
        // One shop pacing us must not stop us talking to any other. This is the same guarantee the
        // sliding window has, and the reason `:scraper_fuse` being shared across stores is such a
        // hazard on this path.
        let limiter = RateLimiter::new();
        limiter.back_off("paced.com", Instant::now() + Duration::from_secs(60));

        assert!(limiter.check_and_record("paced.com", 60).is_err());
        assert!(limiter.check_and_record("other.com", 60).is_ok());
    }

    #[test]
    fn retry_after_reads_delta_seconds_and_falls_back_otherwise() {
        // The fallback cases matter more than the happy one: every one of them must still produce a
        // WAIT. A header we cannot read is not permission to carry on at full speed.
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
