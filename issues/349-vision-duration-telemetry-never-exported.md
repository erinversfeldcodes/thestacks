# Issue #349: Vision request duration is measured and never exported

## Summary
Found by the lead while answering an owner question about upload timeouts (2026-07-31). `Stacks.AI.Client` emits `[:stacks, :vision, :request, :stop]` with `%{duration: duration}` on both the success and the non-200 path (`apps/core/lib/stacks/ai/client.ex:196-215`). **Nothing consumes it.** `apps/core/lib/core/prom_ex/plugins/stacks.ex` mentions "vision" exactly once, in a comment — there is no metric definition, so the duration never reaches VictoriaMetrics and never renders in Grafana.

The campaign's dominant defect class again: the measurement is built, nothing is wired to it.

## Why it matters right now
Every timeout in the upload path is currently a guess, and at least one is provably wrong (see **#350**). The only latency figure anyone has written down is a **comment** — `prom_ex/plugins/stacks.ex:41` estimates upload's real cost profile at "~3–8s (two sequential Modal vision calls + R2 upload + DB writes)" — against a 210s client timeout and a 300s Modal timeout. Nobody can currently check that estimate against production, so nobody can size a timeout from evidence.

## User Stories
None — observability. Validatable by the zero-row/zero-series sweep below.

## Goal
Vision call latency is visible in Grafana, so timeouts, retry budgets and the SSE deadline can be set from a distribution rather than from an estimate in a comment.

## Scope Check
One PromEx plugin entry plus a dashboard panel. Trivial. One concern.

## Wiring
Router wiring: none. This **is** a wiring issue: emitter → PromEx plugin → VictoriaMetrics → Grafana, and the first hop after the emitter is missing.

## Feature-Completeness Pre-Check
n/a — no user story. The pre-check is the **zero-series sweep**: confirm no `vision` series exists in the metrics store today, which is the evidence the defect is real.

## Technical Requirements
1. **Add a distribution metric** for `[:stacks, :vision, :request, :stop]` keyed by `endpoint` and `status`, following the existing plugin conventions.
2. **Pick buckets from the claim you are testing.** The estimate is 3–8s and the client gives up at 210s, so buckets must span both — a top bucket at 20s (as `@route_duration_buckets` uses) would put every slow call in `+Inf` and hide exactly the tail this exists to measure. Read the comment at `plugins/stacks.ex:35-43` first: it records a previous incident where a too-low ceiling reported a flat p95 and hid the distribution.
3. **Prove it end to end.** ⚠️ Per ADR-021 the pipeline is push-based; a metric that compiles is not a metric that arrives. Deploy to a preview, drive a real upload, and **observe the series in the store** — that is the acceptance test. The #248 lesson is that the whole observability stack once shipped structurally complete and blank.
4. **Report the observed p50/p95/p99** in the Progress Notes. That number is the input to #350 and #351.

## Reviewer Context
- ⚠️ **A dashboard-render gate that seeds its own series proves nothing.** Require real data from a real upload (see `completion-audit` class 2).
- Modal is available (unblocked 2026-07-26), so a preview can drive the real vision loop.
- Related: **#350** (the timeout inversion this data should settle), **#351** (reader-facing wait), ADR-021 (metrics are push, not scrape).
- Commit: agent commits are DENIED. Stage, ONE-LINE message to scratchpad, never push.

## Test Audit
| Layer | Applies? | Verdict |
|-------|----------|---------|
| Observability | yes | ❌ series present in the store after a real upload — not a synthetic seed |
| Observability | yes | ❌ buckets span 3s–210s; no saturation at the top bucket |
| Others | no | n/a |

## Definition of Done
- [ ] Metric defined and exported — evidence: diff
- [ ] Series observed in the store after a real preview upload — evidence: query output
- [ ] p50/p95/p99 recorded — evidence: the numbers, in Progress Notes
- [ ] `staff-review` verdict recorded below

## Dependencies
None technical. **Precedes #350** (which needs this data to size the timeout honestly). Needs an owner wave assignment.

## Agent Assignment
elixir-agent / observability.

## Progress Notes
Filed 2026-07-31 by the lead. Confirmed: `grep -c vision apps/core/lib/core/prom_ex/plugins/stacks.ex` → 1, and that single hit is a comment.
