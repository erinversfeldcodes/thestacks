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
- [x] Approach chosen and recorded with reasoning — evidence: sitemap harvesting, argued in this issue
      and in `apps/scraper/src/sitemap.rs`'s module docs. The measurement that settled it: a blind
      `/events` guess costs the shop a **249,540-byte** styled Shopify 404, while the sitemap index is
      **10,334 bytes** and states which pages exist — ~25× less traffic *and* the actual answer
- [ ] ⛔ **BLOCKED — needs a live run.** Every scrapeable store has a working events path **or** a
      durable "no events page" reason —
      evidence: a live batch run's summary line, plus the DB rows
- [x] The job stops re-fetching stores known to have no events page — evidence:
      `a recent negative is not re-asked, so the shop pays nothing` asserts `sitemap_calls() == []` and
      `fetches() == []` for a store checked inside the 30-day window. Probed: forcing the window open
      (`if true or stale?`) fails exactly that test. Before this, a shop with no events page paid for a
      fresh sitemap walk on **every run, forever**
- [ ] ⛔ **BLOCKED — needs a live run.** A batch run writes a non-zero event count, or its summary
      accounts for every store —
      evidence: captured run output on a preview
- [x] `just verify` passes — evidence: verify24, **exit 0** — 3235 Elixir tests, 1285 Elm, 15
      properties, all five codegen targets clean, `check-css.sh` 0 problems

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

## Part 2 — landed
`739c1c26` — `POST /sitemap-urls`. `apps/scraper/src/sitemap.rs` holds the pure core: `<loc>`
extraction (CDATA, entities, attributes, truncated bodies), `DocKind` with a distinct `Unknown` so a
bot-challenge page is never mistaken for "this shop lists no pages", `classify_child` (exclusions
beat page tokens, so an ambiguous `product-pages-sitemap.xml` is refused), and `CrawlBudget` — a
**consumable** value, because `spend()` is what yields the byte ceiling, so no request can be issued
in this path without an allowance. `fetch_capped` streams and hangs up rather than reading past it;
a cap applied after the transfer is not a cap.

Guards worth noting: cross-host `Sitemap:` lines are **refused, not followed** (`path_within`) —
robots.txt is attacker-controlled input, and this was a second door into the open-proxy hole
`/fetch` already guards for `path`. Known-`Page` children are read before `Unlabelled` ones, because
a finite budget makes ordering allocation.

Probes: page-before-exclusion ordering → 1 failure; `Unknown` falling back to `UrlSet` → 1 failure;
`charge_bytes` becoming a no-op → 3 failures.

## Parts 3–5 — remaining, in this order

**Part 3 — `Stacks.Enrichment.EventsPath.resolve/1`.** Consume `ScraperClient.sitemap_urls/1`, filter
the returned URLs on `events|whats-on|calendar|diary|programme|happenings`, verify the best candidate
with **one** fetch, and persist the result on the store: `events_path` on success,
`unscrapable_reason` otherwise, so a shop is never asked the same question twice. Needs a migration
(two nullable columns on `op.bookstores`) → therefore needs `mix proto.sync` **and** the
`gdpr-review` lens.

⚠️ Do not treat `{:error, :no_sitemap_declared}` as "no events page" — it is "we could not look", and
conflating them is the exact false negative parts 1–2 were shaped to avoid. Same for
`truncated: true`.

**Part 4 — wire the job off `@events_path "/events"`.** `DiscoverBookstoreEventsJob` currently fetches
one hardcoded path that 404s on every scrapeable store. It should read the store's resolved
`events_path`, and call `EventsPath.resolve/1` when it has none. **A zero-row sweep afterwards is
mandatory** — the whole point is that this pipeline has never written a row, and "it compiles" has
never been evidence of that changing.

**Part 5 — conditional requests (`ETag` / `If-Modified-Since`).** Absent entirely, and the single
biggest remaining politeness win: a 304 costs the shop almost nothing, and both the events page and
the sitemaps are re-read on a schedule. Store the validators alongside `events_path`.

## Parts 3–5 — landed
`78037736` (parts 3–4), `b4fa7020` (part 5), `f1518d57` + `9b9a334b` (review fixes).

- **Part 3** `Stacks.Enrichment.EventsPath.resolve/1` — one function, one argument, and the caller
  needs to know nothing about robots.txt, sitemap indexes, child classification or crawl budgets.
  Persists `events_path` / `events_unresolved_reason` / `events_path_checked_at`.
- **Part 4** the job reads the resolved path. There is now **no default events path at all**;
  reintroducing one would restore the quiet failure, since a guess that 404s looks exactly like a
  shop with no events.
- **Part 5** conditional requests. `If-None-Match` / `If-Modified-Since` sent verbatim, a 304 is its
  own outcome carrying no body, and the validators are banked so the round trip closes.

**Three real defects surfaced by writing the tests, not by review:**
1. `persist_events/2` returned a bare `:ok`, so `summarise_batch/2`'s events clause was **dead** —
   every batch logged "0 event(s) written" regardless of what it wrote.
2. `parse_events/2` refused a date whenever a page held more than one distinct date, so a **normal
   listing produced nothing**. Replaced with block-scoped pairing: a date is used only if it sits
   between its own heading and the next, so it can never be borrowed from another event or from page
   chrome. Footer trimmed; chrome headings filtered.
3. A byte cap that cut a document short did **not** set `truncated` — the index was truncated
   mid-`<loc>`, parsed to zero children, and the walk ended normally reporting a complete result.

## Progress Notes
- 2026-07-29: **staff-review: LGTM WITH NOTES** over `bf374c7f^..HEAD`. Two 🟧 raised and both
  **fixed in this issue** rather than deferred: (a) `Engine::sitemap_urls` had never been executed —
  every piece unit-tested, the assembling loop never run, which is #307's own defect one layer up.
  Fixed with a mock-mode seam (`Engine::new_mock_http`) plus five end-to-end walk tests; writing them
  found defect 3 above, and found that `sitemap_urls`/`harvest_one` called `RobotsChecker`
  **unguarded**, so `new_mock` would have made live network calls. (b) `events_path_checked_at` was
  written and never read — the field documented at length as making a negative re-checkable, with
  nothing re-checking. Fixed with a 30-day window that gates **both** a negative (a shop with no
  events page no longer pays for a walk every run) and a stale positive (a path that dies by 500 or
  redirect, which the 404 branch never catches). One 🟨 fixed (double regex scan → one). One 🟦
  recorded, not actioned: `"post"` in `EXCLUDED_TOKENS` would refuse `/pages/postponed-events`.

## Why the last two boxes are still open — and it is not effort

Both require running the pipeline against the **real shops**, and both are blocked by #308's own
finding: probing `exclusivebooks.co.za` and `www.wordsworth.co.za` a handful of times from one laptop
produced **HTTP 429 on every path including `/robots.txt`**. Running a live batch now would be the
exact discourtesy this issue was rebuilt to avoid, and would also measure our own rate-limit state
rather than the shops' events pages.

What is in place for when a cooldown has lapsed:
- The client now **honours** a 429 rather than ignoring it (#308), so a live run is safe to attempt in
  a way it was not before.
- Conditional requests mean a repeat run costs a shop a 304 with no body.
- `summarise_batch/2` accounts for **every** store per run — `events` / `no_page` / `blocked` /
  `paced` / `unchanged` / `failed` — so the second box is answerable from one log line rather than an
  investigation. That reporting was itself a defect: the events tally clause was dead code, so every
  batch logged "0 event(s) written" regardless of what it wrote.

⚠️ Deliberately **not** ticking these from unit tests. A green suite proving the chain writes rows
against a fixture is not evidence that a real shop has an events page — that conflation is why this
pipeline sat at zero rows with every test passing, and it is the one mistake this issue exists to
correct.

