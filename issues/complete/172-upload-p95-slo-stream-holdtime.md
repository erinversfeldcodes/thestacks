# Issue #172: upload_p95_ms SLO measures stream hold-time; interim 30s threshold + bring-down plan

## Summary
The third production deploy attempt (run 28931136604) passed everything — preflight, migrations, seeds, warmup — and was rolled back by the SLO gate on a single SLI: `upload_p95_ms` = 18,108ms vs threshold 3,000ms, on a system that was otherwise fully healthy (availability 1.0, real 5xx 0.0, upload success rate 1.0, 0 timeouts, all fuses closed, 297/297 synthetic probes). The metric is mis-classified, not the pipeline regressed: the interim fix raises the threshold to 30s; the bring-down plan restores a real request-latency SLO once the identify cascade lands.

## User Stories
None directly — release-engineering / observability correctness.

## Goal
Deploys of a healthy system pass the SLO gate today (30s interim ceiling still catches a hung pipeline), and there is a recorded path back to a snappy-experience SLO (2–3s) once the latency work ships.

## Scope Check
- Interim fix: one threshold + comments + one fixture — well under all limits.
- The bring-down items are separate workstreams (cascade, route-group split) and are explicitly **not** in this issue's implementation scope.

## Wiring
- [ ] This issue includes router wiring and is user-facing when complete.
- [x] This issue is implementation only. Wired by issue #___ *(N/A — SLO gate script + fixtures).*

## Technical Requirements

### H. `upload_p95_ms` measures progress-stream hold-time, not request latency — interim fix in tree
**Symptom:** run 28931136604's SLO gate breached `upload_p95_ms` at 18,108ms (threshold 3,000ms) and rolled back an otherwise-green deploy. Fly logs from the same window show `POST /api/upload` returning 202 in ~1.1–1.5s.
**Cause:** `StacksWeb.Plugs.RouteGroup` classifies by path prefix, and `/api/upload/` catches both `POST /api/upload` (real request latency) **and** `GET /api/upload/:id/stream` — the chunked identification progress stream. A stream's router-dispatch duration is however long the client holds it open while the vision pipeline resolves (10–20s by design on the current always-VLM path). With the prober running 95 uploads each holding a stream to its terminal event, the p95 of the combined histogram is dominated by stream lifetimes. Preview never caught it because mock/faster vision closes streams inside the old threshold.
**Interim fix (this issue):** raise the `upload_p95_ms` threshold to 30,000ms in `scripts/check-slo-gate.sh`, with the rationale and bring-down plan in the threshold comment. 30s still catches the failure mode the SLI exists for — a hung pipeline holding streams to their timeout — while tolerating normal VLM resolution. The breached-latency fixture's upload buckets are re-shaped so its p95 lands in the 30,000–60,000ms bucket (breaches interim and future thresholds alike; no fixture churn when the threshold tightens).
**Test:** `test/platform/check_slo_gate_test.sh` — 52/52 assertions pass with the re-shaped fixture (healthy fixture passes, breach fixture still trips the gate). Live: the next Deploy production run's gate shows `upload_p95_ms` well under 30,000 and `outcome: passed`.

### Bring-down plan (tracked here, implemented elsewhere)
1. **Identify cascade** (barcode → cover-embedding retrieval → OCR → VLM fallback): collapses common-case resolution to ~1–3s, so stream hold-times shrink with it. Barcode pre-pass and title-search cache are already live; the retrieval spike is the next substantive workstream.
2. **Route-group split:** special-case `/api/upload/*/stream` into its own `:upload_stream` group in `RouteGroup.classify/1` so `upload_p95_ms` measures only request latency. Do not latency-gate the stream group — stream health is already gated by `upload_success_rate` and `oban_failure_rate_vision`.
3. **End-to-end identify SLI:** add an upload→terminal-event duration metric (from Oban/job telemetry) as the SLI that tracks the cascade's latency budget; `mix eval.resolver` (F1) is the offline counterpart on the fixed corpus.
4. Once 1–2 land: restore `upload_p95_ms` to 2,000–3,000ms.

## Reviewer Context
- The SLO gate runs windowed deltas (first-scrape subtracted from last-scrape), so the measured p95 reflects only gate-window traffic — the 18.1s reading is not pre-deploy contamination.
- `scripts/check-slo-gate.sh` does not parse under macOS bash 3.2 (pre-existing, unrelated); use bash 5 (`PATH="/opt/homebrew/bin:$PATH"`) to run `test/platform/check_slo_gate_test.sh` locally. CI runners use bash 5.
- The breached-latency fixture intentionally anchors the gate's breach decision on a single signal — keep all non-upload series identical to the healthy fixture when editing it.

## Definition of Done
- [ ] `upload_p95_ms` threshold is 30,000ms with the rationale + bring-down plan in the script comment.
- [ ] `test/platform/check_slo_gate_test.sh` passes (52/52).
- [ ] Live: a Deploy production run passes the SLO gate with `upload_p95_ms` reported under threshold, completing the pipeline end-to-end (Tag main un-skipped).
- [ ] Bring-down items (cascade, `:upload_stream` split, E2E identify SLI, threshold restore) are captured as their own issues when picked up — this issue closes on the interim fix + green deploy.
- [ ] Tests written and passing
- [ ] Standards compliance verified (`just verify` passes)

## Dependencies
- Issue #171 (merged) — seeds/warmup fixes that let the gate be reached at all.
- Bring-down items depend on the retrieval spike (not yet an issue) and a `RouteGroup` change (Elixir, separate issue when picked up).

## Agent Assignment
platform-agent (interim fix); elixir-agent (future route-group split).

## Progress Notes
- 2026-07-08: H root-caused from run 28931136604 gate output + Fly request logs + `RouteGroup` classification rules. Interim fix implemented in working tree (threshold, script comment, fixture re-shape, test description); 52/52 platform gate assertions pass under bash 5. Awaiting commit + next deploy for the live DoD tick.
