# Issue #032: Public Cost Transparency Page

## Summary
Build a public-facing page showing the real costs associated with running The Stacks' public deployment. Accessible without login. Extends the metrics dashboard concept (US-5.1) but oriented toward external transparency — anyone on the internet can see what it costs to run this platform.

## User Stories
- US-5.1 View the Metrics Dashboard (extends the cost section for public access)

## Goal
A publicly accessible page that shows an honest, automated breakdown of The Stacks' running costs. Reinforces the platform's transparency philosophy. The page should be beautiful (matching the curator's desk aesthetic from US-5.1) and update automatically from billing data.

## Technical Requirements
- **Backend (Elixir):**
  - API endpoint serving cost data, accessible without authentication
  - Data sources: Fly.io billing API, Modal usage API, Neon billing, domain registrar costs
  - Scheduled Oban job to refresh cost data periodically (daily or on billing cycle)
  - Cost data stored in a simple table: `op.platform_costs` with line items, amounts, periods
  - No user data exposed — only aggregate platform operational costs
- **Frontend (Elm):**
  - Public route (e.g., `/costs` or `/transparency`)
  - Aesthetic consistent with US-5.1 metrics dashboard: curator's desk, ledger-style table, serif typography, muted gold sparklines
  - Line items: Fly.io hosting (per-service breakdown), Modal vision API, Neon database, domain registration, total monthly cost, cost per book in system
  - Historical trend: month-over-month cost chart (sparkline or simple bar chart)
  - Philosophy note at bottom (from US-5.1): "Every number here is real, unfiltered, and automated."
- **Privacy:** No user counts, no user data, no usage patterns — only infrastructure costs
- **Caching:** Cost data can be cached aggressively (hourly or daily refresh is fine)
- Dependencies: billing API integrations need API keys configured as Fly.io secrets

## Definition of Done
- [ ] Backend API endpoint serving cost data without auth
- [ ] Oban job refreshing cost data from billing APIs
- [ ] Elm page rendering cost breakdown at public route
- [ ] Aesthetic matches curator's desk style from US-5.1
- [ ] Line items: hosting, vision API, database, domain, total, cost-per-book
- [ ] Historical trend visualisation
- [ ] No user data exposed
- [ ] Mobile responsive
- [ ] Tests written and passing
- [ ] Standards compliance verified

## Dependencies
- Issue #004 (platform deployment — Fly.io infrastructure must be configured)

## Agent Assignment
elixir-agent (backend), elm-agent (frontend)

## Progress Notes
[Updated by agents during execution.]
