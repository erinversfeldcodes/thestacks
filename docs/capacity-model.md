# The Stacks — Capacity Model

> **Version:** 1.0
> **Created:** 2026-03-19
> **Status:** Living document — update after each phase and quarterly thereafter
> **Owner:** Platform operator / principle-engineer-agent

This document defines performance budgets, latency targets, cost projections, and database growth models for The Stacks. Numbers are grounded in the architecture described in `docs/technical-architecture.md`. Assumptions are stated explicitly — challenge them as real data becomes available.

---

## Table of Contents

1. [Elm Frontend Performance Budget](#1-elm-frontend-performance-budget)
2. [API Latency Targets](#2-api-latency-targets)
3. [Cost Model (per-user projection)](#3-cost-model-per-user-projection)
4. [Database Growth Model](#4-database-growth-model)
5. [Scaling Trigger Points](#5-scaling-trigger-points)

---

## 1. Elm Frontend Performance Budget

The Elm frontend renders a continuous bookcase of spine components. Each spine is an SVG or CSS element with texture, thickness, and wear level. Performance degrades as the number of spines in a single shelf view grows.

### Render Targets

| Metric | Target | Soft limit | Measurement method |
|--------|--------|-----------|-------------------|
| Bookshelf render — 500 books | < 200ms | — | `elm-benchmark` or `Performance.now()` port |
| Bookshelf render — 2,000 books | < 500ms | Pagination recommended above 2K | Same |
| Book detail overlay open (cached data) | < 100ms | — | `Performance.now()` in Elm subscription |
| Book detail overlay open (cold API) | < 500ms | Alert if P95 > 1s | Measured via Telemetry on the API side |
| Search — local (all shelves, 2,000 books) | < 50ms | — | Elm-side timing |
| Page load — initial, cold, 3G | < 3s | — | Lighthouse CI |
| Elm bundle size | < 100KB gzipped | Alert at 150KB | `elm make --optimize` + esbuild output |

**Notes:**
- The 2,000-book threshold for pagination is a soft limit, not a hard cut-off. The bookcase renders all books in the model — if a user has 5,000 books across five shelves (1,000 per shelf), performance at that scale must be measured before shipping.
- Local search is O(n) over in-memory book data (all books are in the Elm model). This is fast at 2K books but will degrade at 10K+.
- Book detail overlay shows enrichment data loaded asynchronously — the overlay opens immediately with book metadata (instant) and enrichment slots fill in as API calls complete (RemoteData pattern).

### Measurement plan

- During Phase 1 (extended): Generate a fixture of 500 books and 2,000 books. Run `elm-benchmark` against the `groupIntoRows` and spine-rendering logic.
- Add `Performance.now()` timing in `Main.elm` for overlay open events. Send timing via a port to be surfaced on the metrics dashboard.
- Lighthouse CI runs on every CI build against the production URL (or a preview URL). Budget defined in `lighthouse-budget.json`.

---

## 2. API Latency Targets

Latency targets are P50/P95/P99 at the Phoenix controller level (not including network round-trip). Measured via `Telemetry.Metrics` and exported via PromEx to the metrics dashboard.

### Core endpoints

| Endpoint | P50 | P95 | P99 | Notes |
|----------|-----|-----|-----|-------|
| `GET /api/bookshelves/:name` | 30ms | 100ms | 200ms | Single user's shelf — indexed query on `bookshelf_id`. Expected simple. |
| `GET /api/books/:id` | 50ms | 150ms | 300ms | Work + editions join. Enrichment fields (prices, reviews) are separate API calls from the frontend. |
| `POST /api/books/confirm` | 30ms | 100ms | 200ms | ISBN lookup + work upsert + placement insert. |
| `GET /api/search` (local, user's books) | 20ms | 80ms | 150ms | PostgreSQL full-text search on tsvector index. |
| `GET /api/search/platform` | 100ms | 500ms | 1,000ms | Cross-user query via `mart_platform_searchable` (dbt mart). May need materialised index. |
| `POST /api/auth/login` | 100ms | 200ms | 500ms | Argon2 hashing is intentionally slow. Cannot be optimised. |
| `POST /api/auth/register` | 150ms | 300ms | 600ms | Argon2 hash + email send enqueue. |
| `PUT /api/placements/:id/move` | 20ms | 75ms | 150ms | Simple update + history insert. |
| `GET /api/admin/source-health` | 50ms | 100ms | 200ms | Per-source health (relocated from the removed `/api/metrics` in #267; the in-app metrics dashboard is superseded by Grafana). |
| `GET /feed/:bookshelf` | 30ms | 100ms | 200ms | RSS feed generation from shelf data. |

**Note — authenticated-request overhead (Issue #124, ADR 016):** every
authenticated request now includes one PK-indexed `SELECT` on `op.guardian_tokens`
(`guardian_db` `on_verify`) as part of JWT verification, and every login adds one
INSERT to the same table. This DB round-trip is now on the auth hot path (auth is
no longer purely CPU-bound signature checking) and must be validated against the
latency/throughput targets above — in particular `auth_p95_ms ≤ 500` and the
per-endpoint P95 budgets, since the `SELECT` applies to *all* authenticated
endpoints, not just the auth routes.

### Vision-related (dominated by Modal cold start)

| Endpoint | P50 | P95 | P99 | Notes |
|----------|-----|-----|-----|-------|
| `POST /api/upload/identify` | 15–30s | 45s | 60s | Dominated by Modal cold start (15–30s). Warm container: 3–8s. |
| ISBN resolution step (Open Library) | 500ms | 2,000ms | 5,000ms | External API call. Circuit breaker trips at 5 failures/60s. |

**Alert thresholds:**
- Alert if P95 for any core endpoint exceeds 2× the target for 5 consecutive minutes.
- Alert if `POST /api/upload/identify` P99 exceeds 90s (indicates Modal is down, not just slow).

### Enforcement

Latency is measured via Phoenix Telemetry events (`[:phoenix, :endpoint, :stop]`) and exported via PromEx. The metrics dashboard (US-5.1.1, Phase 4 (Polish) — since superseded by the Grafana stack, ADR-021) surfaces:
- P50/P95/P99 per endpoint over rolling 1h / 24h windows
- Alert badges when thresholds are exceeded

The post-deploy SLO gate (`scripts/check-slo-gate.sh`, per ADR-015) enforces a hard subset of these targets against a 10-minute window after every production deploy:

| SLI | Threshold |
|-----|-----------|
| `upload_p95_ms` | ≤ 3000 (interim; target 2000) |
| `auth_p95_ms` | ≤ 500 |
| `catalogue_p95_ms` | ≤ 500 |
| `real_5xx_rate` | ≤ 0.005 |

A breach triggers automatic rollback. The endpoint-level targets in the tables above are the development goals; the gate values are the deploy-blocking floor.

---

## 3. Cost Model (per-user projection)

### Assumptions

All costs in South African Rand (ZAR). Exchange rates as of 2026-03.

| Service | Unit cost assumption | Basis |
|---------|---------------------|-------|
| Modal (vision, A10G) | R0.50–R2.50 per identification | ~$0.03–$0.14/min GPU time at 30–60s per call. Stack: HF Transformers + Qwen2.5-VL-7B-Instruct (bf16) on A10G, single inference per container, `max_containers=10` (see `apps/vision/modal_app.py`; rationale in ADR-001 / ADR-015) |
| Together AI (summarisation) | ~R0.10 per review summary | Per-token pricing at ~R0.002/1K tokens, ~50K tokens/summary |
| Brave Search API | R0.054/query (free tier: 2K queries/month; paid: $3/1K ≈ R0.054/query) | Brave pricing page |
| Fly.io (core app, shared-cpu-1x, 2 cpus, 512MB; plus scraper/log-shipper/searxng) | R150–R250/month flat | Fly.io pricing; sizing per `deploy/fly.*.toml` |
| Neon PostgreSQL | R0 (free tier up to 10GB + 1 compute); R200–R800+/month at scale | Neon pricing. Staging branch + per-PR preview branches use copy-on-write off the production base, so preview compute is the dominant marginal cost, not preview storage |
| Resend (email) | R0 (free tier: 3K emails/month) | Resend pricing |

### Uploads per user per month (assumption)

| Phase | Context | Uploads/user/month |
|-------|---------|-------------------|
| Early (< 100 users) | Power users building their library | 20–50 (building from scratch) |
| Growth (100–1,000 users) | Mix of new + established users | 5–10 |
| Steady state (1,000+ users) | Mostly established libraries | 2–5 |

### Cost projection table

| Scale | Users | Books/user avg | Modal (vision) | Brave Search | Fly.io | Neon | Email | Total/mo | Per-user/mo |
|-------|-------|---------------|----------------|--------------|--------|------|-------|----------|------------|
| Prototype | 10 | 200 | R100 (200 uploads) | R0 (free tier) | R200 | R0 | R0 | R300 | R30 |
| Early growth | 100 | 300 | R500 (1K uploads) | R0 (free tier) | R250 | R0 | R0 | R750 | R7.50 |
| Product-market fit | 1,000 | 300 | R2,500 (5K uploads) | R270 (5K queries paid tier) | R500 | R200 | R50 | R3,520 | R3.52 |
| Scale | 10,000 | 300 | R10,000 (20K uploads) | R2,700 (50K queries) | R2,000 | R1,000 | R200 | R15,900 | R1.59 |

**Detailed assumptions:**

| Scale | Modal assumption | Brave assumption | Neon assumption |
|-------|-----------------|-----------------|-----------------|
| 10 users | 20 uploads/user/month × R0.50 avg | Under 2K/month free tier | Free tier (< 10GB storage) |
| 100 users | 10 uploads/user/month × R0.50 avg | 50 queries/user = 5K/month (paid tier) | Free tier stretches to here |
| 1,000 users | 5 uploads/user/month × R0.50 avg | 5 queries/user/month = 5K/month | Compute scales with connections |
| 10,000 users | 2 uploads/user/month × R0.50 avg | 5 queries/user/month = 50K/month | Read replica likely needed |

**Revenue model note:** These costs are for a self-hosted or platform-owner-operated instance. The platform does not currently have a user subscription fee. The per-user cost at scale (R1.59–R7.50) represents the hosting cost that must be offset by the platform owner — either through a subscription model, marketplace transaction fees, or the platform owner subsidising the cost.

### Budget controls already implemented

- `Stacks.AI.BudgetTracker`: daily limit R5, monthly limit R100 (for Modal)
- These limits are deliberately conservative for early development — they must be raised as user count grows
- See `docs/runbooks/budget-exhaustion.md` for the response procedure

---

## 4. Database Growth Model

### Table growth rates at 1,000 users

| Table | Growth driver | Rows/day | Rows/year | Size estimate/year |
|-------|--------------|----------|-----------|-------------------|
| `price_snapshots` | 5 stores × active books per user | ~50,000 | ~18M | ~8GB |
| `event_log` | ~50 events/user/day | ~50,000 | ~18M | ~5GB |
| `review_snapshots` | ~3 reviews/book/quarter refresh cycle | ~500 | ~180K | ~200MB |
| `bookshelf_placements` | New books added | ~200 | ~73K | ~50MB |
| `bookshelf_placement_history` | ~5 moves/user/month | ~5,000 | ~1.8M | ~500MB |
| `uploaded_images` | Photo uploads | ~500/day peak | ~180K | ~100MB (metadata only) |
| `oban_jobs` | Job processing | ~10,000/day (mostly cleared) | Steady state ~1M | Manageable |
| `books` (works) | New books added | ~200 | ~73K | ~50MB |
| `book_editions` | New editions | ~250 | ~91K | ~50MB |
| `audit_log` | Security events | ~500 | ~180K | ~100MB |

**Total estimated database size at 1,000 users, year 1:** ~14GB

### Neon free tier limits

Neon's free tier includes up to 10GB of storage. At 1,000 users with a full year of data, the platform will exceed the free tier. Plan to upgrade Neon before reaching 10GB of operational data.

### Partitioning triggers

| Table | Trigger | Partition strategy |
|-------|---------|-------------------|
| `price_snapshots` | 10M rows (approximately 5–6 months at 1K users) | Partition by month on `scraped_at` |
| `event_log` | 5M rows (approximately 3 months at 1K users) | Partition by month on `occurred_at` |
| `oban_jobs` | Oban's built-in pruning handles this — no partitioning needed | Oban prunes completed jobs automatically |
| `review_snapshots` | No partitioning needed at projected volumes | — |
| `bookshelf_placement_history` | No partitioning needed at projected volumes | — |
| `audit_log` | 10M rows | Partition by year on `occurred_at` |

**Partitioning implementation note:**
PostgreSQL declarative partitioning requires creating the partitioned table from scratch and migrating data. This must be planned 1–2 months before the threshold is reached. Monitor table sizes weekly at the 100-user mark and monthly thereafter.

```sql
-- Monitor table sizes
SELECT
  schemaname,
  tablename,
  pg_size_pretty(pg_total_relation_size(schemaname || '.' || tablename)) AS total_size,
  pg_size_pretty(pg_relation_size(schemaname || '.' || tablename)) AS table_size,
  pg_size_pretty(pg_indexes_size(schemaname || '.' || tablename)) AS index_size
FROM pg_tables
WHERE schemaname IN ('op', 'wh', 'audit')
ORDER BY pg_total_relation_size(schemaname || '.' || tablename) DESC;
```

### Analytical data growth (wh schema)

The `wh` schema is written by dbt and grows with the mart refresh cadence. Key marts:

| dbt model | Refresh cadence | Estimated size at 1K users |
|-----------|----------------|---------------------------|
| `mart_community_read_count` | Per dbt refresh cycle (~hourly) | ~100K rows |
| `mart_price_alerts` | Per dbt refresh | ~50K rows |
| `mart_author_activity` | Per dbt refresh | ~20K rows |
| `mart_platform_searchable` | Every 5 minutes | ~300K rows |

The `wh` schema will remain significantly smaller than `op` throughout Phase 1 and most of Phase 2.

---

## 5. Scaling Trigger Points

These are concrete, observable thresholds that should trigger an infrastructure review.

| Metric | Current state | Trigger threshold | Action |
|--------|--------------|------------------|--------|
| Active users | < 10 | **100 users** | Evaluate Brave Search paid tier; check Neon storage consumption |
| Database size | < 1GB | **10GB** | Upgrade Neon plan; plan `price_snapshots` partitioning |
| Active users | — | **500 users** | Evaluate Neon scaling tier; plan read replicas for read-heavy `GET /bookshelves` |
| `price_snapshots` row count | 0 | **5M rows** | Implement monthly partitioning |
| `event_log` row count | 0 | **5M rows** | Implement monthly partitioning |
| Fly.io machine memory | 512MB (core), 256MB (scraper/log-shipper), 512MB (searxng) | **> 80% sustained** | Upgrade tier or add a second machine. Sizing lives in `deploy/fly.{core,scraper,searxng,log-shipper}.toml` |
| `GET /api/search/platform` P95 | N/A | **> 1,000ms** | Evaluate dedicated search service (e.g., Typesense, meilisearch) |
| Modal spend | < R5/day | **> R50/day sustained** | Renegotiate budget limits; evaluate whether modal selection is still optimal |
| Active users | — | **1,000 users** | Evaluate DuckDB for `wh` schema analytical queries |
| Active users | — | **5,000 users** | Evaluate Snowflake / ClickHouse for time-series data (`price_snapshots` history) |
| Oban queue depth | < 100 jobs | **> 1,000 jobs sustained** | See `docs/runbooks/oban-queue-backlog.md`. Configured concurrency in `apps/core/config/config.exs`: `default: 10, events: 20, vision: 60, scraper: 5, notifications: 3, dbt_refresh: 1`. Oban is the event bus (ADR-002) |

### Capacity review cadence

| Cadence | Review |
|---------|--------|
| **Weekly** (while in early growth) | Neon storage consumption, Oban queue depths, Modal spend |
| **Monthly** | Cost projection vs. actual, API latency percentiles, table growth rates |
| **Quarterly** | Full capacity model review — update projections with real data |
| **At each scaling trigger** | Architecture review for the specific concern triggered |

---

## Revision History

| Version | Date | Summary |
|---------|------|---------|
| 1.0 | 2026-03-19 | Initial capacity model — projections only, no real data |
| 1.1 | 2026-05-24 | Align with current code: Fly sizing (core 512MB/2cpu), Oban queue concurrency, vision stack (HF Transformers + Qwen2.5-VL-7B + A10G, `max_containers=10`), Neon CoW preview model, ADR-015 SLO gate thresholds. Cross-refs to ADR-001/-002/-015. |
