# Issue #304: Bookstore events — fetch works, extraction yields nothing

## Summary
`DiscoverBookstoreEventsJob` runs clean and creates **zero** events. Observed on a preview
2026-07-29: the compliant egress and the fetch both work, a 250 KB page comes back, and the
extractor finds nothing in it. The break is at extraction and at path-guessing, not at the network.

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

**Measured, not inferred** (`ScraperClient.fetch_page(store.scraper_module, "/events")` on the live
preview):

| Store | Fetch | Body | Events extracted |
|---|---|---|---|
| Wordsworth Books | `:ok` | **249,540 bytes** | 0 |
| Exclusive Books | `:ok` | **18 bytes** | 0 |

Three distinct defects behind one clean `:ok`:

1. ⛔ **Extraction finds nothing in a real page.** 250 KB of Wordsworth HTML produced zero events.
   Either the site has no events or the extractor does not match its markup — determine which
   before writing code, by dumping the fetched body and looking.
2. 🟧 **The events path is a single hardcoded guess.** `@events_path "/events"` is fetched on
   *every* store (`discover_bookstore_events_job.ex:78`). Exclusive Books returned 18 bytes, i.e.
   no such page. Shopify stores vary; one guessed path cannot serve them all. Either add a
   per-store events path to the scraper config, or discover it (sitemap / nav link).
3. 🟧 **`outcome` is `nil` on a successful fetch.** C3/C4 added a `FetchOutcome` enum precisely so a
   fetch's result is recorded; a successful fetch leaving it nil means the state that was supposed
   to make robots-blocks and failures legible is not being written on the happy path.

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
- [ ] Determined, from the captured body, whether Wordsworth genuinely has events — evidence: the
      saved fixture + what was found in it
- [ ] Extraction produces events from a real page — evidence: named test over the fixture
- [ ] Per-store events path resolved (config or discovery) — evidence: test + a live batch run
- [ ] `outcome` recorded on success — evidence: named test
- [ ] A batch run writes a non-zero count, or logs a per-store reason for each zero — evidence:
      live run output on a preview
- [ ] `just verify` passes — evidence: command → captured output

## Progress Notes
- 2026-07-29: Found by running the job on a preview at the owner's instruction ("run it, observe it,
  keep working on any errors"). The job returned `:ok` with `EVENTS before=0 after=0` — a clean
  success that wrote nothing, which is the failure mode the zero-row sweep exists to catch. Numbers
  above measured directly against the live stack.
