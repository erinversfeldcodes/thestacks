# Issue #059: Elm Wave 2 — Enrichment Display + Admin Pages

## Summary
Replace stub enrichment components with real data: reviews with sentiment bars, prices per edition with sparklines, expanded author cards with RSS and events. Add admin pages for scraper config and source approval.

## User Stories
US-2.1.1 (review display), US-2.2.1 (price display), US-2.3.1 (author card), US-2.4.1 (event display), US-2.5.1 (source approval)

## Goal
The book detail overlay shows real enrichment data. Admin users can configure scrapers and approve/reject discovered sources.

## Technical Requirements

**`Components.ReviewSummary` (no longer stub):**
- Per-source cards: GoodReads, Reddit, Storygraph
- Each card: source icon, one-sentence LLM summary, sentiment colour bar (red → amber → green), rating + count, "Last refreshed" timestamp
- Links to original threads/reviews (open in new tab)
- "AI-generated summary" label

**`Components.PriceInfo` (no longer stub):**
- Prices grouped by edition (format label: "Hardcover", "Kindle", etc.)
- Per edition: list of stores sorted by price (lowest first)
- Each store: name, price in ZAR, "Buy" link, in-stock indicator
- Price trend sparkline per store (last 6 months) — SVG, muted gold on cream
- "Prices checked by The Stacks. Last updated: [timestamp]"

**`Components.AuthorCard` (expanded):**
- Author name, website link (new tab), bio excerpt
- Latest RSS post: title, date, first sentence, "Read more" link
- Upcoming events: "[Event] at [Venue], [Date] — you own N of their books"
- "Report an issue" link (muted text below section) — opens simple feedback form

**`Page.Events` (if events surface separately from book detail):**
- Event cards matched to user's books/authors
- Amber highlight for matched events

**Admin pages:**
- `Page.Admin.ScraperConfig` — TOML editor with validation feedback, list of configured stores
- `Page.Admin.SourceApproval` — queue of discovered sources: name, URL, type, confidence score, sample data. Approve/Reject buttons.

## Definition of Done
- [ ] Review summary shows real data with sentiment bars (not stubs)
- [ ] Price info shows per-edition prices from real data
- [ ] Sparkline renders as SVG with correct trend data
- [ ] Author card shows RSS posts and events
- [ ] "Report an issue" feedback form submits
- [ ] Scraper config admin page saves valid TOML
- [ ] Source approval page shows approve/reject actions; state updates
- [ ] All components use `RemoteData` pattern
- [ ] `elm-format --validate src/` passes

## Dependencies
Issues #050-051 (enrichment APIs must return real data)

## Agent Assignment
elm-agent

## Progress Notes
