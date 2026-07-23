# Issue #250: Metric audience classification gate (all-public + fail-closed mechanism)

## Summary
First child of #249. Per ADR-021 §4, the gating rule is: **an operational metric is public unless
it contains PII or can be de-anonymised.** Every one of the 49 registered `stacks_*` families is an
aggregate keyed only on bounded whitelisted atoms (no user-id/handle/IP/email/free-text), so **all
49 are public** — nothing is dropped ("display, don't delete"). This issue builds the fail-closed
**classification gate** that keeps a *future* non-public metric from leaking, and records the
all-public classification for the current set.

## User Stories
Epic #231 (radical transparency) — classification mechanism. No new stories.

## Model (ADR-021 §4) — three audiences, one routine dashboard
- **Everyone (public)** — every aggregate, non-PII, non-de-anonymisable metric. Default *target*
  for operational metrics. All 49 current families qualify. Rendered on the public transparency
  page + anonymous public Grafana. There is **no separate operator dashboard** (ADR-019 §5).
- **Producing user (own-only)** — per-user/personal metrics, shown only to that user: the #242
  personal-inference surface. A separate per-user axis, not a dashboard tier. (Route, not built here.)
- **Admin — break-glass only** — rare, explicit, logged elevated access (align #138), for a future
  aggregate-but-de-anon-risky metric that is neither public nor per-user. (Route, not built here.)

## Why nothing is dropped
"Every metric measured must be shown" has two escape valves — drop **or** display. Each family
measures something diagnostic (e.g. `rate_limit_client_ip` is the canary that fly-client-ip stopped
arriving; `events_handler_invoked` is the error-rate denominator; `shelf_browse_capped` shows the
pagination cap biting real users). So the correct resolution is *display*, not delete. A metric is
dropped ONLY if it is a genuine duplicate of another series — none currently are.

## What this issue builds
1. **Audience registry** — a single source of truth mapping each metric family → audience
   (`:public` | `:own` | `:break_glass`). **Default `:public` is NOT automatic**: the registry is
   fail-closed — a family with no explicit entry is treated as *not-public* (excluded from the
   `@allowlist` / public dashboards) until someone classifies it. All 49 current families get an
   explicit `:public` entry.
2. **Fail-closed proof** — a test that adds a hypothetical unclassified metric and asserts it is
   NOT served publicly (not in `allowlist_keys/0`, not on a public dashboard) until promoted — the
   blog-engagement-PII scenario.
3. **The all-public record** — the current 49 families enumerated as `:public` with a one-line
   note that each is aggregate + non-PII (cite the #249 audit).

## Deliberate stance (recorded, owner-confirmed)
Publishing *live* security/defense telemetry (login-failure shapes, token-reuse detection,
rate-limit rejections) publicly is an intentional radical-transparency choice, not an oversight.
These are aggregate, non-PII, non-de-anonymisable, so they are `:public` per the rule.

## Technical Requirements
- Registry consumed by `@allowlist` (the allowlist-rename phase) and the completeness gate (the completeness-gate phase).
- No `:telemetry.execute` sites or plugin entries are removed (no drops).
- Own-view (#242) and break-glass (#138) are classification VALUES + routing hooks only — the
  surfaces themselves are out of scope for this issue.

## Definition of Done
- [x] Audience registry implemented; all 49 families explicitly `:public`; unclassified defaults
      to not-public (fail-closed), proven by a test. — `Core.PromEx.MetricAudience`
      (`metric_audience.ex:47-115`, `@audience` map = 49 `:public` entries); `audience/1` fail-closed
      via `Map.get(@audience, family, :unclassified)`; proof `metric_audience_test.exs:33` ("fail-closed:
      an unknown/future metric is NOT public until explicitly promoted") + `:21` (every registered family
      classified) + `:39` (all current `:public`). All green — targeted run 59 tests / 0 failures 2026-07-23.
- [x] `just verify` green; no metric instrumentation removed. — no `:telemetry.execute` sites removed
      (registry is additive); full-branch `just verify` GREEN on the merged `feat/wave2-observability`
      stack 2026-07-17 (epic #249); targeted firing/drift/completeness suites re-run GREEN 2026-07-23.
- [x] Feeds the allowlist-rename phase (`@allowlist`) and the completeness-gate phase (completeness gate).
      — consumed by `Stacks.Transparency` (`transparency.ex:77` `@allowlist`, `allowlist_queries/0:188`;
      cross-checked by `metric_audience_test.exs:66` "every metric on the public transparency allowlist is
      classified `:public`") and by `Core.PromEx.DashboardCompletenessTest` (`dashboard_completeness_test.exs:63`,
      measured ⊆ displayed gate reads `MetricAudience.audience/1`).

## Dependencies
Parent #249. Blocks the allowlist-rename phase, the transparency-repoint phase, the completeness-gate phase. Grounded by the #249 metric audit.

## Agent Assignment
elixir-agent.

## Progress Notes
- **Verified absorbed by #249's shipped stack, close-out audit 2026-07-23.** The fail-closed audience
  registry is live: `Core.PromEx.MetricAudience` (`metric_audience.ex`) classifies all 49 registered
  families `:public`; `audience/1` returns `:unclassified` (not public) for any unlisted family. Proven
  fail-closed by `metric_audience_test.exs:33` and enforced measured⊆classified by `:21`. Consumed by
  the `@allowlist` boundary (`transparency.ex`) and the global completeness gate
  (`dashboard_completeness_test.exs`). Targeted suite GREEN 2026-07-23 (59 tests / 0 failures across the
  discovery/audience/drift/completeness files). No instrumentation removed. **CLOSE-READY.**
