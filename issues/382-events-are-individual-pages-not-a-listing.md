# Issue #382: These bookshops publish events as individual pages, not a listing

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
- [x] An event published as a standalone page is discovered and stored — evidence: **live run
      2026-08-04, the first row this pipeline has ever written from a real shop.** The real job
      (`DiscoverBookstoreEventsJob.perform/1`) against the real store through the compliant egress:
      sitemap walk 45 URLs / 3 documents / 18,535 bytes / 75 catalogue children refused →
      `EventsPath` records the honest negative → `EventPages` classifies exactly one candidate →
      one fetch → `JOB RESULT: {:ok, {:events, 1}}` with the row named:
      `title="Treive Nicholas book signing at our Sea Point store"` (from the page's own `<title>`,
      shop suffix stripped), `date=nil` (the page states none; we do not invent), `url=` the shop's
      own page. Dateless storage is **owner ruling 2026-08-04 (Option A)**: `event_date` optional,
      never counted as "upcoming" (`listed_events/1` vs `upcoming_events/1` split, both tested)
- [x] Non-events are refused — evidence: the classifier's ground truth is the shop's REAL 45-slug
      page list, measured before the classifier existed — 44 negatives including `halloween`,
      `mothers-day-promotion`, `careers-at-wordsworth-books`, `book-of-the-month-subscription`, each
      asserted individually. Probed both directions: adding broad tokens (`celebrate halloween`) →
      6 failures; removing `book-signing` → 4 failures incl. the ground-truth test
- [x] No extra request per page beyond the ones a candidate earns — evidence: classification reuses
      the walk's harvest (threaded through `{:error, {:no_candidate, urls}}`, so no second walk), the
      mock chain test asserts exactly 1 fetch for 45 URLs, the live run fetched 3 sitemap documents +
      1 candidate page, and a `@max_candidates_per_run 5` cap bounds a hostile sitemap — the overflow
      **logged, never silent**, with its own test
- [x] `EventsPath.candidate_tokens/0` is NOT widened — evidence: `git diff` of the change touches
      `resolve`'s return shape only; the token list is byte-identical
- [x] `just run just verify` passes — wave gate, evidence in the epic state
- [x] `gdpr-review`: considered, not skipped. New data stored: shop-published event pages (title,
      URL, optional date). An event title can carry a person's name (an author at a public,
      shop-advertised event) — the same class `bookstore_events.author_id` already holds, and it is
      public commercial information published by the shop, not user data; no user-data path touches
      this table. No new columns; `event_date` relaxed to optional on an existing nullable column

## Dependencies
Depends on **#307** (done — it built the polite page-enumeration this needs and proved the assumption
that motivates this issue).

## Agent Assignment
`elixir-agent`, with the staff engineer reviewing the classifier's negative cases.

## Progress Notes
- 2026-08-04: Filed from #307's first live run. The finding is only available live: every fixture in
  the suite agreed with the assumption, because the fixtures were written from it.

## Renumbered
- 2026-08-04: filed as **#311**, which was already taken by the 2026-07-30 campaign's wave epic
  (`issues/complete/311-campaign-*.md`). The collision was invisible until `just wave-status` resolved
  a Wave 0 item to this file and reported its unchecked boxes against that
  wave. Renumbered to #382. **Check `issues/complete/` as well as `issues/` before taking a number** —
  `mcp__project-tools__next_issue_number()` does; counting files in `issues/` alone does not.

## Progress Notes (close-out)
- 2026-08-04: Built and driven live in one sitting. Two mechanics worth recording: the dateless
  upsert needed **`NULLS NOT DISTINCT`** on the unique index (Postgres treats NULLs as distinct, so
  every run would have duplicated each dateless event and ON CONFLICT would never fire — migration
  20260804200000, pinned structurally from `pg_index` because a rollback probe was silently
  neutralised by `mix test`'s own re-migrate); and the shop-suffix stripper needed the regex **`u`
  flag** (an em dash is multibyte; without Unicode mode the character class matches its bytes and
  every title quietly keeps " — Wordsworth Books" — caught by asserting on the real page's title).
- 2026-08-04: **staff-review: LGTM.** The asymmetry argument is the design: a missed event costs one
  listing, an invented one poisons the surface, so the phrase list is precise multi-word forms and the
  44 real negatives are the test suite's centrepiece. The harvest threading (`{:no_candidate, urls}`)
  is the right seam — zero extra shop cost — and the honesty split (`listed_events` vs
  `upcoming_events`) prevents the structurally-valid-but-false "upcoming" claim for dateless rows.
  Known limits, stated: the SPA still has no consumer for bookstore events (`upcomingEventsCount` is
  produced by no server code — pre-existing, recorded in the epic as surface work for the events
  story), and Exclusive Books remains `:sitemap_unreadable` until it has a non-sitemap route.

