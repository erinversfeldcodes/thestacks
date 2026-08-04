# Issue #311: These bookshops publish events as individual pages, not a listing

## Summary
**#307** assumed every shop has an events *listing* page to find, fetch and parse. Driven live on
2026-08-04 against both scrapeable stores, that assumption is false.

Wordsworth's sitemap lists 45 pages. One of them is
`/pages/treive-nicholas-book-signing-at-our-sea-point-store` — **an actual event, as its own page** —
sitting among `/pages/careers-at-wordsworth-books`, `/pages/payment-logos` and
`/pages/summer-sale-up-to-50-off`. There is no `/events`, no `/whats-on`, nothing to parse as a list.

So the pipeline is correct and its answer is accurate ("this shop lists no events page"), while the
*strategy* above it cannot ever produce an event for these shops.

## User Stories
US-3.1.x (third spaces / bookshop events). The events surface still has nothing to show, and #307
established that this is why.

## Goal
An event published as a standalone page is discovered and stored, without inventing events from pages
that are not events.

## Scope Check
- More than 3 controllers? → None.
- More than 2 new endpoints? → None; reuses `/sitemap-urls` and `/fetch`.
- More than ~300 lines? → Likely at the edge. If a classifier is needed, split classification from
  extraction.
- Unrelated concerns? → No.

## Technical Requirements

The shape changes from *find one page and parse a list* to *classify N pages and extract one event
from each candidate*. The hard part is the classifier, and its failure mode is the expensive one:
`/pages/summer-sale-up-to-50-off` is a promotion, `/pages/careers-at-wordsworth-books` is a job ad,
and **a pipeline that invents events is worse than one that produces none** — the lesson already
recorded in `parse_events/2`.

- The candidate list is free: `sitemap_urls` already returns every page URL, so classification costs
  no extra requests. Only *verification* of a candidate costs one.
- ⚠️ **Do not widen `EventsPath.candidate_tokens/0` to catch this.** Adding `signing`, `launch`,
  `talk` would make `resolve/1` return a single event page as though it were a listing, and the job
  would then parse one event's page expecting many. The two strategies are different and must not be
  conflated in one field.
- Reuse the existing politeness: budget, `Crawl-delay` spacing, conditional requests. A per-page
  classifier must not turn 45 pages into 45 fetches — classify on the **URL and sitemap metadata
  first** (`<lastmod>` is available and free), and fetch only what survives.
- Exclusive Books cannot be reached this way at all: its declared sitemap answers **HTTP 500**. That
  store needs a different route entirely and should stay recorded as `:sitemap_unreadable` until it
  has one.

## Reviewer Context
- ⚠️ Recorded evidence, do not re-derive: Wordsworth's index declares **73 product sitemaps** plus
  collections and blogs. The catalogue exclusion in `sitemap.rs` is what keeps this affordable —
  3 documents and 18,535 bytes rather than 76 documents.
- The date-pairing rule in `parse_events/2` is block-scoped and deliberately refuses to borrow a date
  across blocks. A single event page has one date, so it may need a different extraction path — and
  that path must be at least as unwilling to guess.

## Test Audit

| Layer | Applies? | Verdict |
|-------|----------|---------|
| Elixir unit (classifier) | yes | to add — must include NEGATIVE fixtures: a promotion, a job ad, a payment-logos page |
| Elixir unit (extraction) | yes | to add |
| Live drive | **yes, mandatory** | #307 proved the assumption wrong only when driven; a fixture would have agreed with the wrong assumption |

Punch list:
1. The classifier's negative cases matter more than its positive ones. `/pages/summer-sale-up-to-50-off`
   and `/pages/careers-at-wordsworth-books` are the tests that stop this inventing events.
2. A zero-row sweep after wiring, and a **live** run. #307's whole history is a pipeline that passed
   every test and wrote nothing.

## Definition of Done
- [ ] An event published as a standalone page is discovered and stored — evidence: a live run naming
      the page and the row it wrote
- [ ] Non-events are refused — evidence: named negative tests for a promotion and a job ad,
      mutation-probed
- [ ] No extra request per page beyond the ones a candidate earns — evidence: fetch count from a live run
- [ ] `EventsPath.candidate_tokens/0` is NOT widened to cover this — evidence: it is unchanged
- [ ] `just run just verify` passes
- [ ] `gdpr-review`: n/a — shop-published event data, no personal data. Stated, not skipped.

## Dependencies
Depends on **#307** (done — it built the polite page-enumeration this needs and proved the assumption
that motivates this issue).

## Agent Assignment
`elixir-agent`, with the staff engineer reviewing the classifier's negative cases.

## Progress Notes
- 2026-08-04: Filed from #307's first live run. The finding is only available live: every fixture in
  the suite agreed with the assumption, because the fixtures were written from it.
