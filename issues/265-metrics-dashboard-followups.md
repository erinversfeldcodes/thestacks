# Issue #265: Metrics dashboard follow-ups — enrichment-gaps mart shape + USD padding

## Summary
Two non-blocking follow-ups from the #119 epic review (elm-reviewer + elixir-reviewer): (1) the
`enrichment_gaps/0` **mart branch** returns a structurally different JSON shape than the mart-less
fallback added in #262 — a potential prod-only dashboard break; (2) the USD cost formatter doesn't
pad to two decimals.

## User Stories
US-5.1 (View the Metrics Dashboard) — correctness/polish.

## Goal
The enrichment-gaps section renders correctly in **both** the mart-present (prod) and mart-less
(dev/preview) paths, and the cost ledger shows conventional `$X.XX`.

## Wiring
Implementation-only — no router changes.

## Feature-Completeness Pre-Check
n/a — the dashboard is built (#261/#262); these are correctness/polish follow-ups.

## Technical Requirements
1. **enrichment_gaps mart-vs-fallback shape divergence (the substantive one).**
   `Stacks.Admin.Metrics.enrichment_gaps/0` mart branch does `SELECT * FROM wh.mart_enrichment_gaps
   LIMIT 1` (a **per-book** row), while the #262 live fallback returns an **aggregate summary**
   (`%{status, total_books, missing_cover, missing_prices, missing_reviews}`). The Elm decoder
   (`Api.elm` `enrichmentGapsDecoder`, counts `booksWithoutPrices/Covers/Reviews`) matches the
   **fallback** shape. So when the `wh.mart_enrichment_gaps` view IS present (prod), the section may
   receive the wrong shape → silent zeros / decode failure. #119's E2E runs the mart-less path so it
   will NOT catch this. Fix: make the mart branch return the same aggregate shape as the fallback
   (aggregate over the mart), and add a test asserting both branches produce identical wire shape.
2. **USD 2-decimal padding.** `Page/Admin/Metrics.elm` `formatUsd` uses `String.fromFloat` → `$13`
   (not `$13.00`) and `$13.5` (not `$13.50`). Carried over verbatim from the old `formatZar`. Pad to
   two decimals.

## Reviewer Context
- The mart-branch shape issue is **pre-existing** (predates #262, which only added the fallback +
  `map_size > 0` guard) but surfaced during the #119 review; it's a genuine prod-vs-dev divergence.
- Confirm against `dbt/models/marts/mart_enrichment_gaps.sql` whether the mart is per-book or
  aggregate, and align the context read + decoder accordingly.

## Test Audit
| Layer | Applies? | Verdict |
|-------|----------|---------|
| 3 (DB aggregation) | yes | ❌ no test asserts mart-branch and fallback-branch return identical wire shape (→ ✅) |
| 10 (Elm state machine) | yes | ⚠️ `MetricsProgramTest` covers the fallback shape; add a mart-shape case + USD padding assertion (`$13.00`) (→ ✅) |
| others | no | n/a |

## Definition of Done
- [ ] `enrichment_gaps/0` mart branch returns the same aggregate wire shape as the fallback — evidence: context test asserting shape parity
- [ ] `formatUsd` pads to two decimals (`$13.00`, `$13.50`) — evidence: elm program-test assertion
- [ ] `just verify` passes — evidence: command→output
- [ ] Test audit GREEN — evidence: table

## Dependencies
Follow-up from #119 epic (children #261/#262). Non-blocking for the #119 PR.

## Agent Assignment
elixir-agent + elm-agent

## Progress Notes
- 2026-07-20: Filed from #119 batched review (elixir-reviewer Finding 3 + elm-reviewer USD nit).
