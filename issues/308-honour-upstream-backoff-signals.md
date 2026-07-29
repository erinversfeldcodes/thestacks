# Issue #308: Honour the shop's own "slow down" signal (429 / Retry-After)

## Summary
Our crawl politeness is entirely **self-certified**. `RateLimiter` knows only our configured
`requests_per_minute` and our own clock; there is no channel by which a shop can tell us to slow
down. When one does — HTTP 429 with a `Retry-After` header — we ignore it, keep our own pace, and
record the refusal as a *failure*, which melts the fuse shared by every other shop.

`retry_after_seconds = 60` is configured for **both** target shops and is **read by no code at all**.

Found by measurement, not review: probing `exclusivebooks.co.za` and `www.wordsworth.co.za` a
handful of times from one laptop during #307 design produced **HTTP 429 on every path including
`/robots.txt`**, with a bot-challenge HTML body. Both domains simultaneously — they sit behind a
shared bot-protection front keyed on client IP.

```
exclusivebooks.co.za/robots.txt      429 9251 text/html  challenge=2
exclusivebooks.co.za/sitemap.xml     429 9275 text/html  challenge=2
exclusivebooks.co.za/pages/events    429 9278 text/html  challenge=2
www.wordsworth.co.za/robots.txt      429 9251 text/html  challenge=2
www.wordsworth.co.za/sitemap.xml     429 9275 text/html  challenge=2
```

## User Stories
None directly. It protects US-6.x (bookshop price comparison) and the events discovery behind
US-12.x from being the reason a shop blocks us outright — and protects every *other* shop from one
shop's rate limit.

## Goal
A shop's explicit pacing signal is obeyed, and being paced is a **determination, not a failure**.

Stated as the invariant: after a 429, no further request goes to that domain until the cooldown the
shop asked for has elapsed — enforced inside `RateLimiter`, so it holds for every present and future
caller rather than for the callers who remember.

## Scope Check
- More than 3 controllers? → No controllers. One Rust module + one Elixir client branch.
- More than 2 new endpoints? → **None.** Two new *outcome* enum values on existing endpoints.
- More than ~300 lines of production code? → No. ~120 in `rate_limiter.rs`/`scraper.rs`, ~30 Elixir.
- Unrelated concerns? → No. Deliberately excludes conditional requests (ETag/`If-Modified-Since`),
  which is the *next* politeness win and belongs with #307's remaining parts.

## Wiring
Router wiring: implementation-only — no new routes. The wiring that matters is not a route, it is
that the cooldown lives **inside `check_and_record`**, the one function every egress path already
calls. A `back_off` method that callers must remember to consult would reproduce the defect this
issue exists to fix.

Trace to prove: `retry_after_seconds` (config) → `Retry-After` (response header) →
`RateLimiter::back_off` → `check_and_record` refuses → `FETCH_OUTCOME_RATE_LIMITED` on the wire →
`ScraperClient` returns a determination → the events job records it **without** melting the fuse.

## Feature-Completeness Pre-Check
n/a — no named user story. This is a compliance/behaviour defect in built, live code.

## Technical Requirements

**1. `RateLimiter` gains an externally-imposed cooldown.**
- `back_off(domain, until: Instant)` records or *extends* (never shortens) a per-domain cooldown.
- `check_and_record` consults it **first**, before the sliding window, and returns a distinct
  `ScraperError::UpstreamBackoff { domain, seconds_remaining }` — distinct from
  `RateLimitExceeded`, because "we hit our own ceiling" and "the shop told us to stop" call for
  different operator responses and different outcomes on the wire.

**2. Parse `Retry-After` per RFC 9110 §10.2.3.** Two forms: delta-seconds, and an HTTP-date. Parse
delta-seconds; for anything unparseable or absent fall back to `config.rate_limit.retry_after_seconds`
— the field that has been configured and unread since the scrapers were written. Clamp to a sane
ceiling so a hostile or mistaken `Retry-After: 999999999` cannot park a domain forever.

**3. Treat 429 (and 503-with-`Retry-After`) as a determination.** New `FETCH_OUTCOME_RATE_LIMITED`
and `SCRAPE_OUTCOME_RATE_LIMITED`. Returned with HTTP 200, exactly as `ROBOTS_BLOCKED` already is,
and for the identical reason recorded in `scraper.proto`: the caller melts `:scraper_fuse` on any
non-200, and that fuse is shared across all stores.

**4. Never parse a non-2xx body.** The 429 bodies above are 9 KB of styled challenge HTML that a
price or event extractor will happily accept and find nothing in. `DiscoverBookstoreEventsJob`
already gets this right (only `status: 200` is parsed) — the price path should be checked to match,
and the check should be somewhere a new extractor inherits.

## Reviewer Context
- ⚠️ **This is the `ROBOTS_BLOCKED` lesson recurring one layer out.** `scraper.proto`'s
  `ScrapeOutcome` comment already explains at length why a determination must not be an error, and
  the fuse is why. A 429 is a determination — it recurs on every attempt while we are paced, so as
  a failure it takes price scraping down for *every* shop, repeatedly.
- ⚠️ **`retry_after_seconds` being configured-but-unread is the project's dominant defect class**
  (built, not wired). Grep before assuming any config field is live.
- The rate limiter is per-process and in-memory (`DashMap`), and so is the cooldown. That is
  consistent with the existing design and with the ISBN index, which also "lives in this service's
  process and dies with it" — but it means a redeploy forgets an active cooldown. Say so in the
  module docs rather than pretending otherwise; persisting it is a separate decision.
- Do **not** add a retry loop. Honouring a backoff means *not asking again yet*, and a sleep-then-retry
  inside the request path holds a connection open to do nothing.

## Test Audit

| Layer | Applies? | Verdict |
|-------|----------|---------|
| Rust unit (`rate_limiter.rs`) | yes | to add — cooldown blocks, extends, expires, is per-domain |
| Rust unit (`Retry-After` parsing) | yes | to add — delta-seconds, HTTP-date, absent, hostile value |
| Rust handler (`fetch_response`) | yes | to add — 429 maps to RATE_LIMITED, body not forwarded |
| Elixir (`ScraperClient`) | yes | to add — RATE_LIMITED is a determination; fuse **not** melted |
| E2E / live | no | n/a — cannot provoke a real 429 on demand, and provoking one is the harm |

Punch list:
1. The fuse assertion is the load-bearing one: a test that a `RATE_LIMITED` response leaves
   `:scraper_fuse` intact. Mutation-probe it by routing 429 through the error path and confirming
   that test — and only that test — fails.
2. A test that the cooldown is consulted **before** the sliding window, so a fresh window cannot
   let a request through during a cooldown.

## Definition of Done
- [x] `RateLimiter` holds a per-domain cooldown consulted before the sliding window — evidence:
      `a_cooldown_refuses_a_domain_whose_own_window_is_empty` (cooldown observed at all) **and**
      `the_shops_instruction_is_reported_ahead_of_our_own_ceiling` (the order is observable only when
      *both* would refuse — the first test passes under either order, which is why there are two).
      Probe: moving the cooldown check after the window check fails the second, 1 failure
- [x] `back_off` extends but never shortens an existing cooldown — evidence:
      `back_off_extends_but_never_shortens`. Probe: `*existing = until` unconditionally → 1 failure
- [x] `Retry-After` parsed, clamped, with a fallback to `retry_after_seconds` — evidence:
      `retry_after_reads_delta_seconds_and_falls_back_otherwise`, 6 cases incl. `0` → floored to 1s
      and `999999999` → clamped to 3600s. ⚠️ **Only delta-seconds is parsed**; an HTTP-date takes the
      fallback path. Documented on the function, and the failure mode is a longer wait, not none
- [x] `retry_after_seconds` is **read** — evidence: previously it appeared *only* in the two store
      TOMLs, `config.rs`'s field and its own `default_retry_after` — nothing consumed it. Now
      threaded `config.rate_limit.retry_after_seconds` → `RobotsChecker::policy/3` and
      `Engine::note_pacing` → `RateLimiter::retry_after`
- [x] 429 is a determination, not a failure — evidence: `FETCH_OUTCOME_RATE_LIMITED` returned with
      HTTP 200 carrying `retry_after_seconds`; `outcome_for_error` maps `UpstreamBackoff` to
      `SCRAPE_OUTCOME_RATE_LIMITED` (the explicit no-wildcard match *forced* this decision at
      compile time, as its comment promised it would);
      `ScraperClientTest` proves neither determination is `{:unexpected, _}`, which is the only
      return that melts a fuse; `discover_bookstore_events_job_test` proves the job succeeds and the
      store is **not** marked robots-blocked
- [x] The wiring is proven end-to-end, not just per-unit — evidence:
      `a_429_records_a_cooldown_the_next_request_actually_observes` asserts the *next* egress is
      refused for the 120 s asked for, under the same domain key. Probe: deleting the `back_off`
      call while still returning the determination → 1 failure. This is the check a mismatched key
      would have slipped past with every other test green
- [x] No non-2xx body is ever handed to an extractor — evidence: pacing is checked **before**
      `response.text()` in `fetch_path` and **before** `error_for_status()` in `fetch_html`, and the
      `RATE_LIMITED` response body is `String::new()`. The events job already refused to parse a
      non-200; the price path did not, because `error_for_status` folded a 429 into a generic
      `ScraperError::Http`, i.e. a fuse-melting failure
- [x] **Second defect found and fixed, same root cause** — a 429 on `/robots.txt` was classified
      `NoRestrictions` and *cached*: see the new section below
- [x] Batch summary made honest — evidence: `summarise_batch/2` carried a `blocked` key that was
      never incremented and never printed (a blocked store returned a bare `:ok`), so a run in which
      every store was blocked logged "0 event(s) written" with nothing accounting for it. Now
      `blocked` and `paced` are tallied and printed
- [x] `just run just verify` passes, `cargo clippy --all-targets -- -D warnings` and `cargo fmt`
      clean — evidence: see Progress Notes
- [x] `gdpr-review`: **n/a** — no personal data anywhere in this diff. It touches shop-side HTTP
      metadata (status codes, `Retry-After`, sitemap URLs) only: no new columns, no event payloads,
      no user-reachable fields. Stated rather than skipped.

## The second defect: a 429 on robots.txt granted us *unrestricted* access

Found while implementing the above, and worse than the one this issue was filed for.

`classify_status` mapped `400..=499` to `NoRestrictions` — "no robots.txt exists, crawl freely" —
and **429 lands in that range.** So a shop answering "Too Many Requests" had all of its crawl rules
discarded. Read strictly, this follows RFC 9309: §2.3.1.3 "Unavailable" is defined purely as "status
codes in the 400-499 range", and the RFC says nothing about 429 or 503 specifically (verified against
the published RFC text rather than recalled). The literal reading is the harmful one.

And it compounded, because the 4xx result is **cached**. `RobotsDoc::Absent` went into the domain's
`OnceCell`, so a single transient 429 left us crawling that domain with no robots rules **for the
rest of the process lifetime**. The module docs already take care not to cache the 5xx case for
precisely this reason; this door stood open beside it.

Fix: a fourth verdict, `Paced`, matched **before** the ranges. It returns an `Err`, so nothing is
cached and nothing is crawled — RFC 9309 §2.3.1.4's "complete disallow" outcome still holds — and it
records the cooldown on the way out.

**503 moved to `Paced` too**, deliberately. Both verdicts refuse to crawl, so the RFC-mandated
behaviour is unchanged; what changes is that `Unreachable` became `RobotsFetchFailed`, which
`outcome_for_error` calls a *failure*, which melts the fuse shared by every store. A durably-503 shop
(kalkbaybooks.co.za, during target research) therefore took price scraping down for everyone,
repeatedly. Probe: removing the `429 | 503` arm fails exactly the two tests written for it.

## Dependencies
Blocks the remaining parts of **#307** (sitemap-driven events-path discovery). Harvesting a shop's
sitemap politely is meaningless through a client that ignores an explicit "stop".

Depends on nothing. #307 part 1 (`Sitemap:` retention, landed) is independent.

## Agent Assignment
`rust-agent` for the scraper; `elixir-agent` for the `ScraperClient`/events-job branch.

## Progress Notes
- 2026-07-29: Filed from a #307 design measurement. The intent was to read the two shops' sitemap
  indexes to ground the child-selection policy in fact; instead both answered 429, which is a more
  useful finding than the one being sought. Live probing of these two domains stopped at that
  point — continuing to measure would be the exact discourtesy this issue is about. The remaining
  #307 design is therefore drawn from RFC 9309/9110 and the documented Shopify sitemap layout, with
  fixtures rather than live requests, and is marked as such.

## Progress Notes (review)
- 2026-07-29: **staff-review: LGTM.** Nothing above 🟦 in this issue's slice of the diff. The
  determination-not-failure split is the `ROBOTS_BLOCKED` precedent applied correctly, the cooldown
  sits inside `check_and_record` where no caller can route around it, and the 429-on-robots.txt fix
  is a deliberate, documented deviation from the letter of RFC 9309 (verified against the published
  text, which does not special-case 429). Four mutation probes, each failing only its intended test.
  What it cannot prove: a real 429 end to end — provoking one is the discourtesy the issue exists to
  prevent.
