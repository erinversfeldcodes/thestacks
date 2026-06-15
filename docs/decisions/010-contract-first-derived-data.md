# ADR 010: Contract-First Derived Data Architecture

**Status:** Accepted
**Date:** 2026-03-20
**Deciders:** Platform owner
**Technical area:** Data engineering, data architecture, dbt, event-driven architecture
**Supersedes:** None (this ADR names an existing pattern and refines the rationale)
**Related:** ADR 007 (Protobuf as contract), ADR 009 (proto-to-schema codegen), ADR 014 (proto-first context interfaces), ADR 002 (Oban over Kafka)

---

## Context

The Stacks uses a three-schema PostgreSQL architecture (`op`, `wh`, `audit`) with dbt transforming operational data into analytical views across three layers (staging → intermediate → marts). The staging layer (34 proto-generated views), the intermediate layer, and the marts layer are now all in place (Issues #052a/b/c).

Before committing to the intermediate/mart buildout, we evaluated which data architecture pattern best describes what we're building and should guide design decisions going forward.

### Patterns considered

| Pattern | Core idea | Fit for The Stacks |
|---------|-----------|-------------------|
| **Star schema** (Kimball) | Fact tables + dimension tables with surrogate keys, conformed dimensions, SCD tracking | Poor. Designed for BI analysts writing ad-hoc SQL. Our consumers are the app itself (Elm frontend, metrics dashboard, RSS feeds) and one owner — not a team of analysts. Surrogate keys and conformed dimensions don't earn their keep at this scale. |
| **Medallion / Lakehouse** (Databricks) | Bronze (raw) → Silver (cleaned) → Gold (serving) across object storage | Conceptually close, but mechanistically wrong. Medallion assumes raw file ingestion into a data lake that needs progressive cleaning. Our data enters through Protobuf-validated contracts — it's already clean at write time. We have no data lake, no object storage layer, no Spark. |
| **CQRS + Event Sourcing** (full) | Event log as sole source of truth; all state derived from replay | Over-engineered. Full event sourcing (no operational tables, all state from replay) adds complexity without benefit at our scale. We keep operational tables for OLTP and use the event log for history, replay, and triggering — not as the sole system of record. |
| **Contract-first derived data** (this ADR) | Protobuf contracts enforce shape at write boundary; event log provides ordered history; all downstream views are purpose-built derivations that can be rebuilt from the systems of record | Good fit. Matches what we're already building. Names the pattern so agents and contributors understand the "why." |

### Intellectual lineage

This pattern draws primarily from Kleppmann's *Designing Data-Intensive Applications* (Chapters 4, 11, 12):

- **"Turning the database inside out"** — the event log is the ordered, immutable history; everything downstream (staging views, intermediate models, marts, ETS caches, search indexes, RSS feeds) is a derived data system that can be rebuilt from the systems of record.
- **Schema-on-write at the boundary** — Protobuf contracts enforce the data shape before it enters storage (Ch. 4). This is stronger than medallion's bronze layer, which accepts messy raw data and cleans it later.
- **Derived data with purpose-built read models** — each mart exists because a specific consumer needs data in a specific shape (Ch. 11). A mart isn't "gold" because it's cleaner — it's a read model optimised for the metrics dashboard, or the search index, or the wear calculation. This is CQRS-lite without the full event sourcing overhead.
- **The log as integration point** — the event log connects subsystems (enrichment workers, feed regeneration, dbt refresh) through events, not through shared database reads (Ch. 11, 12).
- **Schema evolution via upcasting** — old events are transformed to the current shape on read, exactly as DDIA recommends for long-lived event stores (Ch. 4).

---

## Decision

We adopt **contract-first derived data** as the named architecture pattern for The Stacks' data pipeline. This formalises what we're already building and provides design guidance for the intermediate/mart buildout (Issue #052).

### The pattern

```
                    SYSTEMS OF RECORD
                    ─────────────────
Protobuf contracts ──► op.* tables (OLTP, Ecto writes)
                    ──► op.event_log (append-only, immutable)
                    ──► audit.audit_log (append-only, encrypted)

                    DERIVED DATA (all rebuildable)
                    ──────────────────────────────
op.* ──► wh.stg_*     Structural projections (PII-excluded, proto-derived where applicable)
stg ──► wh.int_*       Semantic aggregates (domain-meaningful joins and computations)
int ──► wh.mart_*      Consumer-optimised read models (one per use case)
     ──► ETS caches    Ephemeral in-memory derivations (BookDetailCache)
     ──► Search index  mart_platform_searchable (denormalised for full-text)
     ──► Atom feeds    Per-shelf XML projections (event-driven regeneration)
```

### Design principles

1. **Contract-enforced input.** Data entering `op.*` tables is validated against Protobuf contracts (for raw ingestion tables) or Ecto changesets (for domain tables). The staging layer doesn't clean — it projects (selects columns, excludes PII). This is schema-on-write, not schema-on-read.

2. **Every layer after `op.*` is derived and rebuildable.** If the `wh` schema is dropped, `dbt run` reconstructs it. If the ETS cache crashes, events rebuild it. If the search index drifts, the mart is the source of truth. The only non-rebuildable data is in `op.*` and `audit.*`.

3. **Purpose-built read models, not generic "gold" tables.** Each mart serves a specific consumer with a specific access pattern. `mart_community_read_count` exists for the "Looking for a Home" wear calculation (5-min refresh). `mart_platform_searchable` exists for the search endpoint (5-min refresh). `mart_data_freshness` exists for the metrics dashboard (daily). Don't create a mart without a named consumer.

4. **Event-triggered where possible, cron as catch-all.** Prefer triggering selective dbt runs based on event types over running everything on a daily cron. The daily cron remains as a catch-all to ensure eventual consistency, but the primary refresh mechanism should be event-driven:

   | Event type | Triggers selective rebuild of |
   |------------|------------------------------|
   | `shelf.book_placed`, `shelf.book_moved` | `mart_community_read_count` |
   | `enrichment.prices_scraped` | `int_price_trends`, `mart_book_prices` |
   | `enrichment.reviews_scraped` | `int_review_sentiment`, `mart_book_reviews` |
   | `post.published`, `post.updated` | `int_blog_engagement`, `mart_blog_activity` |
   | `source_health.recorded` | `int_source_health`, `mart_data_quality_trend` |

5. **Incremental materialisation for high-volume models.** Models fed by unboundedly growing source tables should use dbt's `+materialized: incremental` with merge strategies rather than full rebuilds:

   | Model | Why incremental |
   |-------|----------------|
   | `int_price_trends` | `price_snapshots` grows as editions × stores × days |
   | `mart_data_quality_trend` | 12-week rolling window — append new, drop oldest |
   | `mart_community_read_count` | 5-min refresh; only changed placements matter |
   | `mart_platform_searchable` | 5-min refresh; only changed/new books matter |

   For the 5-minute hot-path marts, evaluate PostgreSQL `MATERIALIZED VIEW` with `REFRESH CONCURRENTLY` (via dbt's `materialized_view` adapter) as an alternative to incremental tables — this avoids locking during refresh.

6. **PII never enters `wh`.** Tier 3 (sensitive) and Tier 4 (external personal) data is excluded at the staging layer. This is a hard boundary: `stg_*` models explicitly select only the columns that belong in the warehouse. No `SELECT *`.

7. **The staging layer is a second evolution boundary.** When a proto message gains a new field, the staging model must handle both old rows (field null) and new rows (field present) via `COALESCE` or conditional logic. This is independent of the Elixir Upcaster, which handles event payloads specifically.

### What this is NOT

- **Not full CQRS.** We don't have separate write and read databases. `op.*` tables serve both OLTP writes and application reads. The `wh.*` layer is for analytical reads only — controllers reading individual records still query `op.*` directly.
- **Not event sourcing.** The `op.*` tables are the primary system of record for current state. The event log provides history and triggers, but you don't need to replay events to know what's on a shelf — you query `op.bookshelf_placements`.
- **Not a data lake.** There's no object storage, no raw file ingestion, no schema-on-read. Data is structured and validated before it enters the system.

---

## Consequences

### Positive

- **Named pattern.** Contributors and agents can reference "ADR 010" instead of rediscovering the rationale. The pattern name ("contract-first derived data") communicates both the input discipline (contracts) and the output philosophy (derived, rebuildable read models).
- **Design guidance for Issue #052.** Every intermediate/mart model should have a named consumer, a refresh strategy (event-triggered or cron), and a materialisation choice (view, incremental table, or materialized view). This prevents speculative "might be useful" models.
- **Incremental materialisation.** Adopting dbt incremental models for high-volume tables prevents the 5-minute refresh from becoming a bottleneck as data grows.
- **Event-triggered selective refresh.** Reduces unnecessary dbt runs — only rebuild what changed. The daily cron catches anything missed.

### Negative / trade-offs

- **Incremental models are harder to debug.** Full rebuilds are idempotent; incremental models can accumulate state bugs. Mitigation: `dbt run --full-refresh` as a manual escape hatch, documented in runbooks.
- **Event-triggered dbt adds coupling.** The `DbtRefreshJob` worker needs to know which events map to which models. Mitigation: keep the mapping in a single config module (`Stacks.Workers.DbtRefreshJob`), not scattered across event handlers.
- **PostgreSQL does all the work.** No offloading to a columnar engine. This is fine for single-user / small-community scale. The scaling path (Parquet → DuckDB → ClickHouse) is documented but deliberately deferred until query volume justifies it.

### Scaling boundary

The architecture works well while:
- The `wh` schema fits comfortably in PostgreSQL (< 100 GB)
- dbt runs complete within acceptable latency (< 5 min for hot-path marts)
- A single `stacks_dbt` role with concurrency 1 handles the load

When any of these are violated, revisit the "Scaling Beyond PostgreSQL" path in `docs/technical-architecture.md` section 6. The key enabler: dbt models are portable across targets.

---

## References

- Kleppmann, M. (2017). *Designing Data-Intensive Applications*. O'Reilly. Chapters 4 (Encoding and Evolution), 11 (Stream Processing), 12 (The Future of Data Systems).
- ADR 007: Protobuf as Schema Contract
- ADR 009: Proto-to-Schema Codegen for Raw Ingestion Tables
- ADR 014: Proto-First Context Interfaces
- ADR 002: Oban over Kafka (no external message broker)
- Issue #052 (a/b/c): dbt Intermediate + Mart Models, refresh job, data-quality incremental
- Issue #068: Source Health Monitoring
- Issue #080: Proto-to-Schema Codegen
- Issue #082: Proto Sync — schema.yml Generation
- Issue #131: Proto as Single Source of Truth
- `docs/data-quality.md`: Quality dimensions and SLAs
