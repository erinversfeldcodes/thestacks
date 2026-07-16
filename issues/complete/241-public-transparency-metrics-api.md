# Issue #241: Public transparency metrics API (curated, anonymised)

## Summary
A public, unauthenticated JSON API that serves the **curated, anonymised** subset of platform
observability the transparency page (#235) renders — combining **live ops signals** (windowed rates /
current values queried from Fly's managed Prometheus) with **durable aggregates** (public-safe dbt
marts). The whitelist IS the privacy boundary: only low-cardinality, non-PII, non-de-anonymisable
signals; linked-account (future Audible-style) metrics are excluded and reserved for a future
owner-only view. Child of epic **#231**; part of the current #118+#231 PR. Backed by the #234 design.

## User Stories
None directly — the data layer behind the US-facing transparency surface (#235). Child of **#231**.

## Goal
`GET /api/transparency/metrics` (public, no auth) returns a stable JSON payload of (a) live rates/
current-values from a fixed PromQL whitelist against Fly's Prometheus (cached), and (b) durable totals/
ratios from public-safe marts — every value anonymised and safe for a logged-out visitor, every entry
carrying the teaching metadata (what/how/why) the page shows. A non-whitelisted query cannot be
reached; no PII or de-anonymisable/linked-account field can appear.

## Scope Check
- >3 controllers? No (one `TransparencyController` + a `Stacks.Transparency` context + a Prometheus
  client + a mart). >2 endpoints? No (one public GET; maybe a health/cache-status). >300 LOC? Borderline
  — the PromQL whitelist + client + cache + mart query + serializer; keep it lean, split if it grows.
  Mixed concerns? No — one concern: the public transparency data layer.

## Wiring
- [x] User-facing when complete (the public API #235 consumes). Router wiring included.

## Feature-Completeness Pre-Check
n/a — no user story; it's the data layer for #235. Its validation paths are the whitelist-enforcement,
anonymisation, and endpoint-shape tests below.

## Technical Requirements

### 1. Live signals — whitelisted PromQL against Fly's Prometheus
- A `Stacks.Transparency.Prometheus` client that queries Fly's managed-Prometheus HTTP API
  (`.../prometheus/<org>/api/v1/query`) with a **read token** (Fly secret, guarded — absent ⇒ the live
  section degrades gracefully to "unavailable", never an error/leak).
- A **fixed, code-defined whitelist** of safe queries (module attribute / config), e.g.
  `rate(stacks_moderation_isbn_resolution_count_total{outcome="isbn_not_found"}[1h])`,
  moderation-funnel throughput, `stacks_fuse_state_state`, age-gate enforce rate, cost rate. **Only
  whitelisted queries run** — no user-supplied PromQL, ever (SSRF/PromQL-injection guard).
- **Cache** results (Cachex/ETS with a short TTL, e.g. 30–60s) so public page-loads don't hit
  Prometheus; serve stale-on-error.

### 2. Durable stats — public-safe marts
- A dbt mart (e.g. `wh.mart_public_transparency`) exposing only anonymised aggregates: total books,
  % age-gated, total searches, total exports/deletions, aggregate platform cost, etc. **No per-user
  rows, no de-anonymisable dimensions, no linked-account signals.** The context reads this mart.

### 3. The privacy boundary (load-bearing)
- Everything served is an **aggregate** — never a per-user value. The whitelist + the mart's columns
  are the boundary; adding a signal requires an explicit whitelist/mart entry (so nothing leaks by
  default). Linked-account / cross-integration metrics are **excluded by construction** and documented
  as future owner-only (#234).
- Each returned entry carries **teaching metadata** (`label`, `what`, `how`, `why`, `unit`) so #235
  can render the "why we measure this" tooltip — the public analogue of the #233 dashboard standard.

### 4. Endpoint
- `GET /api/transparency/metrics` under a **public** pipeline (no auth, no rate-limit-by-user; apply a
  light global cache/rate guard). Returns `{ live: [...], durable: [...], generated_at, cache_ttl }`.

## Reviewer Context
- **Security-critical:** no user-supplied PromQL (fixed whitelist only); no raw `/internal/metrics`
  proxying (that's the authed firehose — this serves a curated subset). Route through platform-reviewer
  + a security lens.
- **GDPR:** only anonymised aggregates; the mart + whitelist must exclude PII and any de-anonymisable /
  linked-account dimension (route through the gdpr-review lens). This is the exact de-anonymisation risk
  #234 flags for the future owner-only view.
- Fly Prometheus token is a secret, guarded like the log-shipper / Grafana config (no-op when absent).
- Prometheus retention is Fly-side (~days–weeks) — fine for windowed live signals; durable totals come
  from marts, not Prometheus.

## Test Audit
_Compact — a public data API; load-bearing: whitelist enforcement, anonymisation, endpoint shape, cache/degrade._

| Layer | Applies? | Verdict |
|-------|----------|---------|
| Whitelist enforcement (only fixed queries run; no user PromQL) | yes | ❌ (→ ✅ test: whitelisted query returns a number; arbitrary/injected PromQL is impossible to reach) |
| Anonymisation / no-PII / no-de-anon field | yes | ❌ (→ ✅ test: payload contains no per-user or excluded dimension) |
| Public endpoint shape + teaching metadata present | yes | ❌ (→ ✅ controller test: `{live, durable, generated_at}` + each entry has what/how/why) |
| Graceful degradation (Prometheus/token absent) | yes | ❌ (→ ✅ test: live section = "unavailable", no error/leak, durable still served) |
| Cache (no per-request Prometheus hit) | yes | ❌ (→ ✅ test: second call within TTL doesn't re-query) |
| dbt mart public-safe (no PII columns) | yes | ❌ (→ ✅ dbt schema test / accepted columns) |
| 1–13 app US layers | no | n/a — data layer for #235. |

Punch: (1) PromQL client + whitelist + cache; (2) public mart; (3) endpoint + teaching metadata; (4) whitelist/anon/degrade/cache tests; (5) mart schema test.
Verdict: baseline — 5 punch items.

## Definition of Done
- [ ] `GET /api/transparency/metrics` (public) returns `{live, durable, generated_at, cache_ttl}` with teaching metadata per entry.
- [ ] Live signals come from a **fixed PromQL whitelist** against Fly Prometheus (cached, token-guarded, degrade-on-absent); **no user-supplied PromQL**.
- [ ] Durable stats come from a **public-safe mart** with no PII / de-anonymisable / linked-account columns.
- [ ] Tests: whitelist enforcement, no-PII/no-de-anon payload, endpoint shape + metadata, graceful degradation, cache, mart schema.
- [ ] `just verify` passes; test audit GREEN; GDPR + platform reviewed.
- [ ] Meets the Completion Bar — the anonymisation boundary is a real test, not an assumption.

## Dependencies
#228/#230/#232 (metrics emitted, exposed, scraped by Fly Prometheus). Feeds **#235** (the page).
Part of the current #118+#231 PR. Live PromQL validation is deploy-time (documented, like #232).

## Agent Assignment
elixir-agent (context + client + endpoint) + dbt work (public mart). Reviewer: elixir-reviewer +
platform-reviewer + contract-reviewer (public payload shape); gdpr-review lens on the anonymisation boundary.
