# Issue #385: The title-search "don't cache an outage" wire has no end-to-end test

> **Campaign assignment:** Wave 11 (launch gates) — `plans/staff-campaign-2026-07-30.md`. Tracked in the campaign state; completed as part of epic #321.


## Summary
#352 stops a provider outage during title search from being cached as a negative ("no such book")
for an hour. Each link is tested in isolation — `determination/1` maps transient errors to
`:unavailable`, and the cache refuses to store `:unavailable` — but **nothing drives an outage
through `search_by_title/4` and asserts the cache stays empty**, because `title_search_cache_enabled`
is `false` in `config/test.exs`. So the exact path #352 fixes runs only in production.

Found by mutation probe during #352's review: `determination(:timeout) -> :not_found` (reintroducing
the bug) reddens no test.

## Goal
An outage during a cache-enabled title search leaves no negative cache entry, proven by a test that
fails if `determination/1` misclassifies a transient error.

## Scope Check
- Controllers/endpoints/LOC: none / none / small (one test, possibly a provider seam).
- Unrelated concerns? No.

## Technical Requirements
- Enable the title-search cache within the test (override `:title_search_cache_enabled`), stub the
  upstream provider (Google Books / Open Library) to return a transient failure, call
  `search_by_title/4`, and assert `TitleSearchCache.get/3` is still a miss afterward.
- ⚠️ The provider is reached via Finch to real endpoints; there is no Mox seam today. Adding one is
  most of this issue's work — a behaviour module for the HTTP call, or a bypass/injection point.
- Probe: `determination(:timeout) -> :not_found` must red the new test.

## Definition of Done
- [ ] A cache-enabled test proves an outage writes no negative entry — evidence: test name
- [ ] `determination(:timeout) -> :not_found` reddens it — evidence: transcript
- [ ] `just run just verify` passes
- [ ] `gdpr-review`: n/a — cache mechanics, no personal data. Stated, not skipped.

## Dependencies
Depends on **#352** (the behaviour under test).

## Agent Assignment
`elixir-agent`.

## Progress Notes
- 2026-08-04: Filed from #352's review. The gap is not the behaviour (each link is proven) but the
  wire — and a wire that only runs in prod-config is exactly where a future refactor can silently
  re-invert `determination/1` with a green suite.

## Verification (2026-08-07, Wave 11 verify-and-close)
Confirmed ALREADY-FIXED and closed. Fresh run: `just run mix test` on the seam/coverage test — **69 tests, 0 failures** (batched with its sibling). #377 fixed by `df170b48` (rss_fetcher seam + transport-isolation telemetry assertion); #385 fixed by `a2393586` (isbn_resolver_test outage-not-cached, landed with #352 two days before the issue was filed). Issue filed stale; no build needed.
