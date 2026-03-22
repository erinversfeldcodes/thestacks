# Issue #059a: Elm — Enrichment Display Components

## Summary
Replace stub enrichment components in the book detail overlay with real data: reviews with sentiment bars, prices with sparklines, expanded author cards.

## User Stories
US-2.1.1 (reviews), US-2.2.1 (prices), US-2.3.1 (author card), US-2.4.1 (events)

## Goal
The book detail overlay shows real enrichment data fetched from the API.

## Technical Requirements
**`Components.ReviewSummary`:**
- Per-source cards (GoodReads, Reddit, Storygraph)
- Each: source icon, LLM summary, sentiment colour bar, rating, "Last refreshed"
- "AI-generated summary" label

**`Components.PriceInfo`:**
- Prices grouped by edition/format
- Per edition: stores sorted by price (lowest first)
- Each store: name, price in ZAR, "Buy" link
- Price trend sparkline (SVG, muted gold on cream)

**`Components.AuthorCard` (expanded):**
- Author name, website link, bio excerpt
- Latest RSS post: title, date, first sentence
- Upcoming events with book match count

## Scope Check
- Create/modify 3 components
- ~300 LOC

## Dependencies
#057a (overlay must exist to display within)

## Definition of Done
- [ ] Reviews show real data with sentiment bars
- [ ] Prices show per-edition data with sparklines
- [ ] Author card shows RSS + events
- [ ] All use RemoteData pattern
- [ ] `elm-format --validate src/` passes

## Agent Assignment
elm-agent
