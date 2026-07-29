# Issue #307: Find each bookshop's real events page

## Summary
`DiscoverBookstoreEventsJob` fetches a single hardcoded `/events` path on every store, and it **404s
on every scrapeable store**. Split out of **#304**, which proved the fetch and status handling are
correct — the blocker is not knowing where each shop's events actually live.

## User Stories
US-3.1.x (third spaces / bookshop events). The events surface has nothing to show until this is solved.

## Goal
Each scrapeable store either has a known, working events path, or is recorded as having no events page
so the job stops asking.

## Scope Check
- >3 controllers? → none; a worker plus scraper config.
- >2 endpoints? → none.
- >300 LOC? → depends on approach (see below); config-only is small, discovery is larger. **Split if
  discovery is chosen.**
- Unrelated concerns? → ⚠️ Do **not** fold the parser rewrite in here. That is a separate change and is
  noted in #304; mixing "where is the page" with "how do we read it" makes both hard to review.

## Goal decision required (do not guess)

Two approaches, and this is a genuine fork worth a human ruling before code:

| | How | Cost | Risk |
|---|---|---|---|
| **A. Per-store config** | Add `events_path` to each store's scraper config, filled in by hand | Small, explicit, auditable | Manual; rots when a shop redesigns |
| **B. Discovery** | Read `/sitemap.xml` or the nav for a link matching `events\|whats-on\|calendar\|diary` | Self-maintaining | More requests per store, more code, and a wrong guess crawls pages the shop did not offer |

⚠️ **The owner's standing constraint bears on this:** the job crawls **real bookshops, several of them
one-person operations**. B multiplies requests per store. A stays at exactly one. That asymmetry should
probably decide it, but the call is not mine.

## Technical Requirements

- **Do not bypass the compliant egress.** All fetches go through `ScraperClient.fetch_page/2` so
  robots.txt and the per-store rate limit apply (C3/C4). A store with no scraper config is
  deliberately unfetchable — no config means no declared crawl policy.
- Record "no events page" **durably**, not just in the log, so the job can stop re-fetching a 404 every
  run. `unscrapable_reason` (added by P9) is the obvious home.
- Measured starting point (2026-07-29): `https://www.wordsworth.co.za/events` → **404**;
  `https://exclusivebooks.co.za/events` → **18 bytes** (also no page). Those are the only two
  scrapeable stores; the other nine are skipped for having no scraper config (P9).

## Reviewer Context
- ⚠️ **Byte count is not evidence of content.** Wordsworth's 404 is **249,540 bytes** because Shopify
  serves a fully-styled 404 with site chrome. A large body was read as a real page during #304's
  investigation and sent it down the wrong path entirely. Check the status.
- Several stores are chains (Wordsworth, Exclusive Books) with per-branch pages; the bookshop data model
  currently has one row per chain, which is tracked separately in the campaign plan.

## Test Audit

| Layer | Applies? | Verdict |
|-------|----------|---------|
| External service calls | yes | ❌ nothing asserts a store's events path resolves |
| DB interactions | yes | ❌ nothing asserts "no events page" is recorded durably |
| Oban jobs | yes | ⚠️ skip/cancel paths covered; path resolution is new |
| Others | no | n/a |

Punch list:
1. A test that a store with a configured `events_path` fetches that path, not `/events`.
2. A test that a 404 records a durable reason so the next run skips it.
3. If B is chosen: a test that discovery never requests more than N pages per store.

## Definition of Done
- [ ] Approach A or B chosen and recorded with reasoning — evidence: the decision written in this issue
- [ ] Every scrapeable store has a working events path **or** a durable "no events page" reason —
      evidence: a live batch run's summary line, plus the DB rows
- [ ] The job stops re-fetching stores known to have no events page — evidence: named test
- [ ] A live batch run writes a non-zero event count, or its summary accounts for every store —
      evidence: captured run output on a preview
- [ ] `just verify` passes — evidence: command → captured output

## Progress Notes
- 2026-07-29: Split out of #304. That issue began as "extraction is broken" and the investigation
  disproved it: the fetch layer, the status handling and the 404 branch are all correct. The genuine
  blocker is that nobody knows where these shops publish their events, which is a data question and is
  why it is filed separately rather than fixed in passing.

## Dependencies
⛔ **Blocked on #308** (honour the shop's 429 / `Retry-After`). Discovered while designing part 2 of
this issue: both target shops answered **HTTP 429 with a 9 KB bot-challenge page on every path,
`/robots.txt` included**, after only a handful of requests from one laptop. Behind that sat two
defects — `retry_after_seconds` configured and read by nothing, and a 429 on `/robots.txt` being read
as *unrestricted permission* and then cached for the process lifetime.

Harvesting a shop's sitemap "politely" through a client that ignores an explicit *stop* would be
theatre, so #308 lands first.

## Part 1 — landed
`bf374c7f` — `Sitemap:` URLs are parsed at document level (RFC 9309 §2.2.4: not a group member, so
they survive a no-matching-group *and* a disallow), de-duplicated, and carried on every `/fetch`
response as proto field 5. Free information: robots.txt is already read for compliance on every
request, so asking separately would cost the shop a request it should never have to serve.

⚠️ **Parts 2–5 are specified from RFC 9309/9110 and the documented Shopify/Yoast sitemap layouts,
with fixtures — not from measurement.** The measurement that was meant to ground the child-selection
policy is what produced the 429 above, and continuing to probe would be precisely the discourtesy
this issue exists to avoid. Confidence in the classification tokens is therefore "grounded in spec",
not "measured"; re-measure once #308 is deployed and a cooldown has lapsed. Say so in the PR.
