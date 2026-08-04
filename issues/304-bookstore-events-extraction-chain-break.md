# Issue #304: Bookstore events — fetch works, extraction yields nothing

## Summary
`DiscoverBookstoreEventsJob` creates **zero** events — and that turns out to be **correct**, not a
chain break.

⚠️ **My original filing was wrong and is corrected below.** It claimed "a 250 KB page comes back and
the extractor finds nothing in it". The 250 KB was a **styled Shopify 404 page**, and the job never
parsed it: it already matches `{:ok, %{status: 404}}` and skips. There was no break at extraction,
because extraction never ran.

What the investigation did find: the reason was logged at `debug` (invisible, so a zero-row run looked
like silent failure), the events path is a hardcoded guess that **404s on every scrapeable store**, and
the extractor carried a latent bug that would have fabricated wrong records if it ever did run.

## User Stories
US-3.1.x (third spaces / bookshop events). The events surface cannot show anything until this works.

## Goal
A batch run over the scrapeable stores produces a non-zero `bookstore_events` count, or records a
per-store reason why not — never a silent `:ok` with nothing written.

## Scope Check
- >3 controllers? No — one worker, one extractor.
- >2 endpoints? None.
- >300 LOC? Unlikely; possibly more if per-store event-page config is needed.
- Unrelated concerns? Split the **path discovery** from the **extraction** if both grow.

## Wiring
Router wiring: implementation-only — a background job; no new user-facing route.

## Technical Requirements

**Measured on the live site, 2026-07-29** (`curl -L https://www.wordsworth.co.za/events`):

```
http=404  bytes=249540
```

The 249,540 bytes are a **404 page**, which is why it looked like a real document. Shopify serves a
fully-styled 404 with site chrome, so byte count is no evidence of content. In that body:

| Signal | Count |
|---|---|
| Headings the extractor's regex matches | **5** — all site chrome: "Subscribe", "Follow us", "Disclaimer", "Reset your password" |
| Headings with nested markup (regex misses) | 7 |
| ISO dates (`YYYY-MM-DD`) anywhere | **0** |

So three findings, and the first two replace the original diagnosis:

1. ✅ **No chain break.** `discover_for_store/1` already matches `{:ok, %{status: 404}}` and returns
   without parsing. `ScraperClient.fetch_page/2` already surfaces `%{status:, body:}`. Both correct.
   ⚠️ The original filing also claimed "`outcome` is nil on a successful fetch" — that was **my probe
   reading a `:outcome` key that has never existed** on that map. Not a defect.
2. 🟧 **A zero-row run could not explain itself.** The 404 reason was `Logger.debug`, invisible at the
   default level, so the only visible signal was an unchanged row count — which reads as breakage, and
   was mistaken for it. Now `Logger.info` per store plus a one-line batch summary
   (`N event(s) written, N with no events page, N failed`).
3. ⛔ **The extractor would have fabricated records.** `parse_events/2` paired the nth heading with the
   nth ISO date found *anywhere* in the document (`Enum.at(dates, idx)`). Those lists are unrelated —
   headings include site chrome, dates appear in footers, scripts and JSON-LD. On a page that did
   match, it would have produced an event titled "Follow us" dated from an unrelated fragment.
   **Inventing confident wrong data is worse than producing none**, and the weak regex was accidentally
   the only thing preventing it. Now a date is used only when the page carries exactly **one distinct**
   date (a listing repeating one date beside each entry is unambiguous; several different dates are not
   assignable without the surrounding DOM node).

**The remaining blocker is data, not code: no store has an events page at `/events`.** Solving that
means either a per-store events path in the scraper config, or discovery (sitemap / nav link). Until
then there is no real page to validate extraction against — which is why the DoD item that assumed one
is re-scoped rather than ticked.

⚠️ **Only 2 of 11 stores are even reachable** — `scrapeable_stores/0` skips 9 for having no scraper
config (the P9 finding: nine of eleven seeded stores named a nonexistent config). So even a perfect
extractor would cover 2 shops. That is a fixture/config problem, tracked with P9, but it caps what
this issue can demonstrate — say so rather than reporting "2 stores processed" as coverage.

## Reviewer Context
- **Do not bypass the compliant egress.** Fetches go through `ScraperClient.fetch_page/2` so
  robots.txt policy and per-store rate limits apply (C3/C4). A store with no scraper config is
  deliberately unfetchable — no config means no declared crawl policy.
- The owner's standing instruction: this job crawls **real bookshops, several one-person
  operations**. Run it on a preview, observe, and keep the request rate modest.

## Test Audit

| Layer | Applies? | Verdict |
|-------|----------|---------|
| External service calls | yes | ⚠️ mocked only; nothing asserts a real page yields events |
| Oban jobs | yes | ⚠️ the job is tested for skip/cancel, not for producing rows |
| DB interactions | yes | ❌ no test asserts a non-zero `bookstore_events` count |
| Others | no | n/a |

Punch list:
1. A test that feeds the extractor a **real captured page** (fixture from Wordsworth) and asserts
   events come out. This is the assertion whose absence let a zero-row outcome look like success.
2. A **zero-row guard**: a batch run that writes nothing must log per-store *why*, and the test
   should assert the reason is recorded rather than the count being zero.
3. A test that `outcome` is set on a successful fetch.

Verdict: ❌ — the happy path has no coverage that would notice it producing nothing.

## Definition of Done
- [x] Determined from the real page whether Wordsworth has events — evidence: `curl -L` →
      **`http=404`, 249,540 bytes of styled Shopify 404**; 5 matched headings are all site chrome
      ("Subscribe", "Follow us", "Disclaimer"), **0** ISO dates. It has no events page
- [x] The original "extraction is broken" diagnosis corrected — evidence: `discover_for_store/1`
      already matches `{:ok, %{status: 404}}` and never parses; the claimed nil `outcome` was my probe
      reading a key that does not exist on that map
- [x] A zero-row batch explains itself per store — evidence: `Logger.info` per 404 plus
      `summarise_batch/2` (`N event(s) written, N with no events page, N failed`); the 404 branch now
      returns `{:ok, :no_events_page}` so the summary can count it
- [x] The date-pairing bug is fixed and **mutation-probed** — evidence: `discover_bookstore_events_job_test.exs`
      "several DIFFERENT dates on the page yield no date, rather than a guessed pairing" and "one
      distinct date repeated beside every entry IS used"; restoring `Enum.at(dates, idx)` fails the
      first, reverting gives 21/21
- [x] `just verify` passes — evidence: command → captured output (see Progress Notes)
- [x] **RESOLVED 2026-08-04 by driving it live — and the answer is that there is nothing to validate
      against.** This box asked for extraction validated against a real events page. #307's live run
      enumerated both scrapeable stores' actual pages and **neither shop publishes an events page at
      all**:
      - **wordsworth** — 45 pages harvested from its own sitemap. Zero match any events vocabulary
        (`events`, `whats-on`, `calendar`, `diary`, `programme`, `happenings`). What it *does* have is
        `/pages/treive-nicholas-book-signing-at-our-sea-point-store`: **a single event as its own
        page**, among `/pages/careers-at-wordsworth-books` and `/pages/payment-logos`.
      - **exclusive_books** — its declared sitemap answers **HTTP 500, 0 bytes**, so its pages cannot
        be enumerated at all. Recorded as `:sitemap_unreadable`, i.e. *could not look*.

      So the box is not blocked and never can be satisfied as written: a listing-page extractor has no
      listing page to validate against, on either store. That is a finding about the shops, not
      unfinished work, and it is why **#311** exists — events are individual pages here, so extraction
      needs a per-page classifier rather than a list parser. Validating *that* against a real page is
      #311's DoD, with `treive-nicholas-book-signing-at-our-sea-point-store` as the known live fixture.

      ⚠️ The prediction in this box was half right and half wrong, which is worth recording. Right:
      the path problem had to be solved first, and #307 did it. Wrong: it assumed the outcome would be
      a *path*. The honest outcome was "these shops have no such path", which no amount of parsing work
      would have discovered — only enumerating their real pages did.

⚠️ **Only 2 of 11 stores are reachable at all** (`scrapeable_stores/0` skips 9 with no scraper config —
the P9 finding). So even a perfect extractor covers 2 shops today. That caps what this issue could ever
have demonstrated, and is stated rather than left to be discovered again.

## Progress Notes
- 2026-07-29: Found by running the job on a preview at the owner's instruction ("run it, observe it,
  keep working on any errors"). The job returned `:ok` with `EVENTS before=0 after=0` — a clean
  success that wrote nothing, which is the failure mode the zero-row sweep exists to catch. Numbers
  above measured directly against the live stack.
