# Issue #061a: Elm — Metrics Dashboard

## Summary
Build the admin metrics dashboard with curator's desk aesthetic.

## User Stories
US-5.1 (metrics dashboard)

## Goal
The metrics dashboard shows real operational data from the API with the platform's dark-academic aesthetic.

## Technical Requirements
**`Page.Admin.Metrics`:**
- Curator's desk aesthetic: warm wood, paper textures, serif typography, muted gold sparklines
- Sections:
  - System health: source health table (per-source status, colour-coded)
  - Data quality trends: sparklines per category (12-week rolling)
  - Enrichment gaps: count cards ("47 books with no prices")
  - LLM faithfulness: confidence distribution
  - Costs: itemised ledger (Fly.io, Modal, Brave Search, domain)
  - GDPR: images pending deletion, consent rates
- All data from `GET /api/metrics`, `/api/metrics/quality-trends`, `/api/metrics/source-health`, `/api/metrics/enrichment-gaps`
- SVG sparklines
- Philosophy note at bottom in italic serif

## Scope Check
- Create 1 large page module with section components
- ~400 LOC (largest single Elm issue)

## Dependencies
None (API exists from #056)

## Definition of Done
- [ ] All sections render with real data
- [ ] Sparklines render as SVG
- [ ] Source health table colour-coded
- [ ] Cost ledger itemised
- [ ] Owner-only access enforced
- [ ] `elm-format --validate src/` passes

## Agent Assignment
elm-agent
