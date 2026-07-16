# Issue #234: Transparency & platform-honesty design pass

## Summary
Design pass (design-first, non-trivial + values-laden) for the user-facing transparency surface.
**Deliverable: `docs/decisions/019-radical-transparency-metrics.md` (ADR-019)** — the accepted design.
Child of epic **#231**. Informs #241 (data API) + #235 (public page) + #242 (personal view).

## User Stories
None — a design/decision record. Child of **#231**.

## Goal
A written, accepted design (ADR-019) capturing: route/placement, voice, the curated-public data
architecture (live Fly-Prometheus + durable marts), the anonymisation & de-anonymisation boundary, the
v1 themes mapped to existing metrics, the "ops dashboards shown-with-tooltips not hidden" principle, and
the metric-governance rule — so #241/#235/#242 build from a single source of truth.

## Wiring
- [x] Documentation only — the design record. Implementation is #241/#235/#242.

## Feature-Completeness Pre-Check
n/a — design pass.

## Technical Requirements
- Write ADR-019 (done) covering placement (`/metrics`, About ← navbar, costs widget), plain+direct
  placeholder voice, curated-public-from-both-sources architecture, whitelist-as-privacy-boundary,
  anonymised-only + linked-account/de-anon excluded, v1 themes + metric mapping, ops-dashboards-with-
  teaching-tooltips, and the "every metric earns a panel / is questioned" governance rule.
- Reference ADR-019 from the epic (#231) and the implementation tickets (#241/#235/#242).

## Test Audit
n/a — a decision record; validated by review, not tests. The implementation tickets carry the tests.

## Definition of Done
- [x] ADR-019 written + accepted.
- [ ] Referenced from #231 and the implementation tickets.

## Dependencies
Feeds #241 (data API), #235 (public page), #242 (personal view). Part of the current #118+#231 PR.

## Agent Assignment
Orchestrator (design record). Owner writes the final prose in #235.
