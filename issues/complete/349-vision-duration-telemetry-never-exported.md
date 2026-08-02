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
- [x] Metric defined and exported — evidence: commit `30df278f` "export the vision request duration that was measured and dropped", confirmed an ancestor of `feat/campaign-w7-317` (`git merge-base --is-ancestor`). `@vision_duration_buckets` + emitter in `apps/core/lib/core/prom_ex/plugins/stacks.ex`.
- [x] Series observed in the store after a real preview upload — evidence: verified 2026-08-02 on a fresh full preview from `feat/campaign-w7-317` with vision ENABLED (no `SKIP_VISION`), Modal app `thestacks-vision-feat-ca-v349` live. **36 real vision calls** (6 deploy warmup canaries + 30 driven uploads, all HTTP 202; `stacks_upload_terminal_count_total` → resolved 30 / rejected 6 = 36, matching one `/analyze` per upload):
      ```
      stacks_vision_request_stop_duration_milliseconds_count{app="stacks-core-pr-feat-ca-v349"}
        -> {endpoint="analyze", status="200"}  [1785694560, "36"]
      sum(stacks_vision_request_stop_duration_milliseconds_sum{...})
        -> [1785694559, "471241.854461"]   # ms; mean 13.09 s
      ```
      Accruing over real wall-clock (`query_range`, step 60s): 18:09→4, 18:10→6, 18:11→8, 18:12→23, 18:13→36.
      **The final hop proven too** — read back through Grafana's own provisioned datasource (`POST /api/ds/query`, `stacks-grafana-pr-feat-ca-v349.fly.dev`): `histogram_quantile(0.99, ...)` → `57899.99`.
      ⚠️ **Previews DO push metrics** — `scripts/deploy-stack.sh` deploys an ephemeral per-PR store (`VM_APP`, line 718-720) and sets `STACKS_METRICS_PUSH_URL` (line 919). Access gotcha: `fly proxy <local>:8428 <app>.flycast` — `.internal:8428` is connection-refused, the port is only exposed via fly-proxy.
      ⚠️ **Absence is not evidence**: `stacks-vm-pr-feat-campaign-w6-316` runs a core containing this fix and has NO vision family — because nothing on that preview ever called vision.
- [x] p50/p95/p99 recorded — evidence: n=36, all `analyze`/`200`. **p50 8437.5 ms · p95 49500 ms · p99 57900 ms**; `+Inf` saturation check → **0** (buckets fit; no retune needed).
      ⚠️ **Read p95/p99 as "somewhere in (30 s, 60 s]", not as 49.5/57.9 s** — at n=36 the 34th–36th samples share one bucket, so both are interpolation inside it.
      **The split #350 actually needs**, because the whole 30–60 s tail is cold starts:
      | | n | median | p95 | max |
      |---|---|---|---|---|
      | Cold (Modal scaling from zero) | 6 | (30 s, 60 s] | — | ≤60 s |
      | Warm | 30 | **(5 s, 8 s]** | **(15 s, 30 s]** | **≤30 s** |
      **The `~3–8s` estimate at `plugins/stacks.ex:41` is now falsified**: only 18 of 36 calls (50%) landed at or below 8 s. ⚠️ And that estimate describes the *upload route* — "two sequential Modal vision calls + R2 upload + DB writes" — so a single-call median of 8.4 s makes it worse than half wrong, not better. The comparison is legitimate by design: `3_000`/`8_000` were chosen as bucket **edges** precisely to make that claim falsifiable off two bucket counts without interpolation.
- [x] `staff-review` verdict recorded below — **LGTM** (2026-08-02, lead). This is a verification leg, not a code change; the review is of the evidence. Praise: it answered *"do previews push at all?"* **before** driving anything, which is what stops "the series is absent" from being read as a defect — and it then found a preview (w6) that contains the fix and legitimately has no vision family. It proved the **last** hop through Grafana's own datasource rather than stopping at the store. And it declined to launder n=36 into a production p99, separating cold from warm instead of reporting one misleading number. Spot-checked by the lead: commit lineage, the `~3–8s` comment, `STACKS_METRICS_PUSH_URL`, and the bucket-vs-timeout guard test — all as reported.

## Dependencies
None technical. **Precedes #350** (which needs this data to size the timeout honestly). Needs an owner wave assignment.

## Agent Assignment
elixir-agent / observability.

## Progress Notes
Filed 2026-07-31 by the lead. Confirmed: `grep -c vision apps/core/lib/core/prom_ex/plugins/stacks.ex` → 1, and that single hit is a comment.

**2026-07-31 — built (elixir/observability agent).** The emitter → PromEx hop now exists:

- `Core.PromEx.Plugins.Stacks` registers a `distribution` on
  `[:stacks, :vision, :request, :stop]`, `measurement: :duration`,
  `unit: {:native, :millisecond}`, `tags: [:endpoint, :status]` → exported as
  `stacks_vision_request_stop_duration_milliseconds_{bucket,sum,count}`.
- Buckets `[100, 250, 500, 1_000, 2_000, 3_000, 5_000, 8_000, 15_000, 30_000, 60_000, 120_000, 210_000]`.
  3_000/8_000 are edges so the "~3–8s" estimate is read off two bucket counts with no
  interpolation; the top finite bucket is `Stacks.AI.Client.receive_timeout_ms/0`
  (210_000) — the point the client hangs up, above which no `:stop` event can exist —
  so `+Inf` is structurally unreachable and no quantile can be the
  `2 × max_finite_bucket` fallback that produced the false flat p95 on 2026-04-20.
- Classified `:public` in `Core.PromEx.MetricAudience`; panel "Vision call latency
  p50 / p95 / p99" added to `grafana/platform_ops.json` (Upload pipeline row).
- `Core.PromEx.VisionLatencyTest` (9 tests) proves the metric is *attached*, not just
  defined: it emits the real event and reads the series back out of
  `PromEx.get_metrics/1`. Mutation-probed — a 20_000 ceiling fails 2 tests, a wrong
  `event_name` fails 4.

⚠️ **Still unproven here: that the series ARRIVES.** ADR-021 is push, and the #248
lesson is that this stack once shipped structurally complete and blank. End-to-end
proof needs a real upload against a deployed preview. Lead's verification query
(VictoriaMetrics, after ≥1 real upload):

```
# does the series exist at all — the zero-series sweep, inverted
count(stacks_vision_request_stop_duration_milliseconds_count{app="thestacks-core"})

# p50 / p95 / p99 in ms, over the whole observed window
histogram_quantile(0.50, sum by (le) (rate(stacks_vision_request_stop_duration_milliseconds_bucket{app="thestacks-core"}[1h])))
histogram_quantile(0.95, sum by (le) (rate(stacks_vision_request_stop_duration_milliseconds_bucket{app="thestacks-core"}[1h])))
histogram_quantile(0.99, sum by (le) (rate(stacks_vision_request_stop_duration_milliseconds_bucket{app="thestacks-core"}[1h])))

# saturation check — MUST be 0, or the ceiling is wrong after all
sum(rate(stacks_vision_request_stop_duration_milliseconds_bucket{app="thestacks-core",le="+Inf"}[1h]))
  - sum(rate(stacks_vision_request_stop_duration_milliseconds_bucket{app="thestacks-core",le="210000"}[1h]))
```

**staff-review verdict: LGTM** (2026-07-31, lead, Mode B on 30df278f). Praise: (a) the **bucket ceiling is an argument, not a guess** — the top finite bucket is `Stacks.AI.Client.receive_timeout_ms/0` (210_000), the point at which the client hangs up, above which no `:stop` event can exist. That makes `+Inf` *structurally unreachable*, so no quantile can fall back to `2 × max_finite_bucket` — the exact mechanism that produced the false flat p95 recorded in the plugin's 2026-04-20 comment. A 20s ceiling would have reproduced it precisely; (b) 3_000 and 8_000 are **edges rather than interior points**, so the "~3–8s" estimate is read off two bucket counts with no interpolation — the claim becomes falsifiable instead of smoothed; (c) the test emits the **real event and reads the series back out of `PromEx.get_metrics/1`** — the same path the push actually uses — rather than asserting the plugin returns a struct; (d) the GDPR argument is structural: `endpoint_path/1` **raises** outside its four known values, so a call site cannot widen the label, and the `:exception` path carrying an unbounded `reason` term is deliberately left unregistered. A test emits ISBN/title/user_id/image_url in metadata and asserts none becomes a label; (e) it stated plainly that **a metric that compiles is not a metric that arrives**, left that DoD box unticked, and handed over the exact verification queries.
**⚠️ Finding worth carrying into #350 — the timeout tail is invisible by construction.** A call that actually reaches the 210s deadline emits `[:stacks, :vision, :request, :exception]`, not `:stop`, so it contributes **no duration sample**. The p50/p95/p99 this exports are therefore *conditional on having received an HTTP response* and structurally under-report the true tail. **#350 must not size a timeout from this histogram alone** — the count of 210s give-ups has to come from an `:exception` counter that does not yet exist. Two further vision events remain emitted-and-unregistered (`[:stacks, :vision, :error]`, `[:stacks, :vision, :unknown_association_status]`), each one plugin entry.
Probes: ceiling → 20_000 fails 2 tests; `event_name` → `:finish` fails 4. Suites: **3348/0**, observability surface 79/0, credo clean.
**Outstanding: the series has not been observed arriving.** The lead will run the handed-over queries against the preview after a real upload before this is called done.

## What remains unverified, and where it gets closed (lead, 2026-07-31)
**Proven:** the metric is defined, classified `:public`, has a Grafana panel, and 9 unit tests emit the *real* event and read the series back out of `PromEx.get_metrics/1`. Mutation-probed two ways.

**Not proven — one thing only: that a series ARRIVES in the store.** ADR-021 made the pipeline **push**, so registration in-process says nothing about delivery. #248 is the precedent: the whole observability stack once shipped structurally complete and blank.

**Why the lead could not close it during the follow-ups drive.** Two access facts, both discovered rather than assumed: `/internal/metrics` is gated by `StacksWeb.Plugs.MetricsAuth` (`endpoint.ex:38-45`) and the preview carries **no `METRICS_SCRAPE_TOKEN` secret** — only `STACKS_METRICS_PUSH_URL`, which is consistent with push. And VictoriaMetrics sits on an internal address (`stacks-vm-pr-<branch>.flycast:8428`) unreachable from a laptop. Attempts to read the family off the running node via `core rpc` were lost to shell escaping; abandoned rather than half-done.

**The three steps that close it** — all need a deployed preview with Modal available:
1. Drive a **real photo upload** through the vision path, so `[:stacks, :vision, :request, :stop]` actually fires with a duration.
2. Run the zero-series sweep, inverted: `count(stacks_vision_request_stop_duration_milliseconds_count{app="thestacks-core"})` — **non-zero is the acceptance test.**
3. Read p50/p95/p99 and the `+Inf` saturation check (queries already recorded above). Easiest access is the preview Grafana (`stacks-grafana-pr-<branch>.fly.dev`, Upload pipeline row) — the panel rendering with real data *is* the proof; otherwise query VM from inside the Fly network.

**Scheduled: Wave 7, riding on item 7b.** 7b is "Upload failure UX; 429 UX" — it drives the vision path anyway, so the upload that generates the sample is work that wave is doing regardless. No other wave before it touches uploads (Wave 6 is session UX). Recording the p50/p95/p99 there also unblocks **#350**, which must not size a timeout from this histogram alone: a call that reaches the 210s deadline emits `:exception`, not `:stop`, so the percentiles are conditional on having received a response and structurally under-report the tail.
