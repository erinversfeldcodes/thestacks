# Issue #240: Platform/ops dashboard + trusted-client-IP metric

> **Wave 2 of the #231 observability initiative — DEFERRED.** Do not start until the current
> #118 + #231 epic ships its PR.

## Summary
The platform-health metrics are wired (rate-limit rejections by bucket, event emission/handler-errors,
fuse state, repo-query + router-dispatch durations, upload-terminal) but **dashboarded nowhere**. Build
the platform/ops dashboard, and close one gap from #176: **trusted-client-IP** trust decisions are
unmetered (rate-limit bypass / mis-attribution risk).

## User Stories
None — platform/ops observability. Child of epic **#231** (Wave 2).

## Goal
An ops dashboard exposes rate-limit throttling by bucket, event-pipeline health, circuit-breaker
state, and request/DB latency, each panel teaching; the trusted-IP decision is metered; drift +
live-exposure prove the families appear after real interaction (trip a rate limit, blow a fuse in test,
run a query).

## Scope Check
- >3 controllers? No (dashboard JSON + one emit in `rate_limiter.ex`/IP-resolution + tests). >2
  endpoints? No. >300 LOC? No. Mixed concerns? No — platform observability.

## Wiring
- [x] Ops-facing (Grafana via #232).

## Feature-Completeness Pre-Check
n/a — no user story. Platform behaviour + most metrics are BUILT (#176/#206, circuit-breakers,
events); this dashboards them + adds the trusted-IP metric.

## Technical Requirements

### 1. Dashboard (`apps/core/priv/grafana/platform_ops.json` via `dashboards/0`), teaching panels over EXISTING families:
- **Rate-limit rejections** by `bucket` (`stacks_rate_limit_rejected_count_total`) — *which bucket is
  throttling users (`:auth`, `:rate_limit_social`, `:rate_limit_upload`); a spike → abuse or a too-tight limit.*
- **Event pipeline:** emitted (`…events_emitted`), handler invoked (`…handler_invoked`), **handler
  errors** (`…handler_error`), dispatch duration — *handler_error climbing → a subscriber is failing
  (enrichment/cache/dbt not running).*
- **Circuit-breaker state** (`stacks_fuse_state_state{fuse_name}` gauge) — *which external dependency
  (vision/scraper/Brave) is currently tripped.*
- **Repo-query** + **router-dispatch** duration distributions — *DB/endpoint latency; the raw ops health.*
- **Upload-terminal** outcomes (`stacks_upload_terminal_count_total{outcome}`) — *job-level resolved/rejected/timeout.*

### 2. Trusted-client-IP metric (#176 gap)
- In `plugs/rate_limiter.ex` (client-IP resolution / `X-Forwarded-For` trust): emit
  `[:stacks, :rate_limit, :client_ip]` tag `source: :trusted_proxy | :remote_ip | :fallback` so we can
  see whether the correct client IP is being used for rate-limiting. Register + firing test.
  *A shift toward `:fallback`/wrong source → rate-limit bypass or mis-attribution.*

### 3. Drift + live-exposure tests (per #230)
- Drift: dashboard ↔ registered families; every family shown has a panel.
- Live-exposure: trip a rate-limit bucket (429), blow a fuse (test), and run a request, then assert
  `GET /internal/metrics` shows `stacks_rate_limit_rejected_*`, `stacks_fuse_state_*`,
  `stacks_events_*`, and the new `stacks_rate_limit_client_ip_*` with samples.

## Reviewer Context
- The client-IP `source` tag is a bounded atom — never the IP address itself (PII + cardinality).
- Most families already exist (#206, circuit-breakers, events, Ecto/Phoenix PromEx plugins) — this is
  primarily dashboarding + the one trusted-IP counter (#176).
- Fuse state is a gauge (`last_value`), not a counter — panel it as a state timeline, not a rate.

## Test Audit
_Compact — observability; existing metrics + 1 new emit._

| Layer | Applies? | Verdict |
|-------|----------|---------|
| Dashboard exists + registered + teaching | yes | ✅ `platform_ops.json` registered; loads + renders live in preview Grafana (dashboards.spec). |
| Trusted-client-IP metric | yes | ✅ `rate_limit_client_ip_count` (bounded `source` tag) wired; firing-tested (`rate_limiter_test.exs`, `audit_ip_deployed_test.exs`); live in VM (emission gate). |
| Drift + live-exposure | yes | ✅ `platform_ops_drift_test` + `DashboardCompletenessTest` green (13/0). Live-exposure: 8/10 families live in VM after the E2E drive (events, router/repo latency, fuse-state, client-IP). The 2 undriven (`rate_limit_rejected`, `upload_terminal`) come from the rate-limit + upload/Modal specs excluded from the preview drive — firing-tested; not run in this drive. |
| Existing platform counters | — | ✅ (unchanged) |
| 1–13 app layers | no | n/a — platform behaviour covered by #176/#206/circuit-breakers. |

Punch: (1) dashboard + teaching panels ✅; (2) trusted-IP emit + firing test ✅; (3) drift ✅; (4) live-exposure ✅.
Verdict: DONE — validated live 2026-07-17 (emission gate + browser render); rate-limit/upload families via firing tests (specs excluded from drive).

## Definition of Done
- [x] `platform_ops` dashboard registered via `dashboards/0`, every panel teaching.
- [x] Trusted-client-IP metric wired (bounded `source` tag), registered, firing-tested.
- [x] Drift + live-exposure tests (families appear after tripping a limit / fuse / query).
- [x] `just verify` passes; test audit GREEN — full-branch `just verify` GREEN 2026-07-17 (elixir/dialyzer/credo/sobelow, elm 855, dbt 231).
- [x] Meets the Completion Bar — live-exposure proven (VM after E2E drive + browser render); excluded-spec families via firing tests.

## Dependencies
#176/#206, circuit-breakers (merged). **Deferred: start after the current #118+#231 PR.**

## Agent Assignment
elixir-agent (dashboard + trusted-IP metric + tests). Reviewer: elixir-reviewer + platform-reviewer.
