# Issue #061: Elm Wave 4 — Metrics Dashboard + RSS

## Summary
Build the Elm metrics dashboard (curator's desk aesthetic) and add RSS feed links on public shelf pages.

## User Stories
US-5.1 (metrics dashboard), US-6.1 (RSS feeds)

## Goal
The metrics dashboard shows real operational data with the curator's desk aesthetic. Public shelves expose RSS feed URLs.

## Technical Requirements

**`Page.Admin.Metrics`:**
- Curator's desk aesthetic: warm wood surface, paper textures, serif typography, muted gold sparklines
- System health: uptime gauge, API latency sparkline, DB size, last deploy info
- Jobs: table of Oban jobs — name, status (colour-coded), last run, next run. Failed jobs highlighted in muted red.
- Data freshness: gauges per category (prices, reviews, author, events) — green/amber/red by SLA
- Source discovery: configured sources count, pending review count, Brave Search usage
- Costs: itemised ledger table — Fly.io, Modal, Brave Search, domain. Running total. Cost per book.
- GDPR: images pending deletion, audit log entries, encryption status
- Philosophy note at bottom in italic serif

**RSS integration:**
- `Components.RSSLink` — small RSS icon (brass/wood aesthetic) in shelf header on public shelves
- Click reveals feed URL and explanation: "Subscribe in your RSS reader"
- Only shown when shelf visibility is `platform`

## Definition of Done
- [ ] Metrics dashboard renders all sections with real data from API
- [ ] Sparklines render as SVG
- [ ] Job status table is colour-coded
- [ ] Cost ledger shows itemised breakdown
- [ ] RSS icon appears on public shelves
- [ ] Feed URL is correct and displays explanation on click
- [ ] Curator's desk aesthetic is implemented (not just a data table)
- [ ] `elm-format --validate src/` passes

## Dependencies
Issue #056 (metrics + RSS API endpoints)

## Agent Assignment
elm-agent

## Progress Notes
