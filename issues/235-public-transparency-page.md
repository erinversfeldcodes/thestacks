# Issue #235: Public `/metrics` transparency page

## Summary
The public, unauthenticated transparency page that renders the #241 API — live curated ops signals +
durable anonymised aggregates — each with the teaching tooltip explaining *why we measure it*, a
featured **costs** widget, and one-hop links to the GDPR data-rights surfaces. Linked from About ←
navbar. Design: ADR-019. Child of epic **#231**.

## User Stories
US-8.x / transparency — "As anyone, I want to see what this platform measures + what it costs, so I
understand how it's run and funded." Child of **#231**.

## Goal
A logged-out visitor opens `/metrics` and sees: the live signals (or a graceful "live data
unavailable" when Prometheus isn't configured), durable stats, and a prominent costs widget — each
panel with its plain-language *what/how/why* — plus links to export/delete. Reachable via About, which
is reachable from the navbar.

## Scope Check
- >3 controllers? No (Elm page + one existing API). >2 endpoints? No (consumes #241). >300 LOC? ~one
  Elm page + About + wiring. Mixed concerns? No — the public transparency surface.

## Wiring
- [x] Router (Elm route `/metrics`) + navbar → About → `/metrics`. User-facing.

## Feature-Completeness Pre-Check
The data layer (#241) is built. This is the render. Pre-Check: the API is ✅; this issue delivers the page.

## Technical Requirements
1. **`Api.getTransparencyMetrics`** (Elm) → `GET /api/transparency/metrics`; decode `{live, durable,
   generated_at, cache_ttl}` with each entry's `label/what/how/why/unit/value` (+ live `:unavailable`).
2. **`Page.Metrics`** at route `/metrics` (public): render live + durable sections; each panel shows
   the value and an info tooltip with *what/how/why* (the #233 teaching standard, applied to the public
   view). Handle `RemoteData` + per-signal `unavailable` gracefully.
3. **Costs widget** — feature the platform-cost figures prominently (ADR-019 flagship): "running this
   costs $X; here's why we charge/self-host instead of selling your data" (placeholder prose).
4. **Data-rights links** — one-hop to GDPR export/delete from the "what we observe" section.
5. **Entry points** — an About page (or section) linked from the navbar; About links to `/metrics`.
   Keep the navbar uncluttered (a single About entry).
6. **Tests** — `elm-test` for the page states (loading / loaded / live-unavailable / error); a
   decoder test for the payload; the route resolves.

## Reviewer Context
- Public page — no auth; renders only #241's curated/anonymised payload (never raw metrics).
- Voice: plain + direct, placeholder prose (owner refines). Aesthetic: the "curator's desk", not a
  Grafana clone (`ux-reviewer.md:62`) — route through ux-reviewer.
- The live section must degrade gracefully (Prometheus unconfigured locally → `:unavailable`, not an error).

## Test Audit
_Compact — an Elm render of an existing API._

| Layer | Applies? | Verdict |
|-------|----------|---------|
| Elm state machine (loading/loaded/unavailable/error) | yes | ❌ (→ ✅ elm-test) |
| Decoder for the #241 payload | yes | ❌ (→ ✅ decoder test) |
| Route `/metrics` + About/navbar wiring | yes | ❌ (→ ✅ Main/Route test) |
| Teaching tooltips present per panel | yes | ❌ (→ ✅) |
| API layer | — | ✅ #241 (unchanged) |
| E2E (optional) | maybe | a browser drive of `/metrics` at the epic E2E gate |

Punch: (1) Api + decoder; (2) Page.Metrics + tooltips + costs widget; (3) About + navbar + route; (4) elm-tests.
Verdict: baseline — 4 punch items.

## Definition of Done
- [ ] `/metrics` renders live + durable transparency data with per-panel teaching tooltips + a costs widget + data-rights links.
- [ ] Reachable via navbar → About → `/metrics`.
- [ ] Graceful `live unavailable` state; RemoteData loading/error handled.
- [ ] elm-test for states + decoder + route; `just verify` passes; test audit GREEN.
- [ ] ux-reviewed ("curator's desk"); Meets the Completion Bar (driven live at the epic E2E gate).

## Dependencies
#241 (API — merged). Part of the current #118+#231 PR.

## Agent Assignment
elm-agent (page + Api + wiring). Reviewers: elm-reviewer + ux-reviewer + contract-reviewer (decoder ↔ #241 payload).
