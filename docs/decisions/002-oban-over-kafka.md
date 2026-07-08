# ADR 002: Oban as Event Bus Instead of Kafka or RabbitMQ

**Status:** Accepted
**Date:** 2026-03-05
**Deciders:** Platform owner
**Technical area:** Event-driven architecture, job processing, infrastructure

---

## Context

The Stacks is an event-driven system. Significant state changes (book added, shelf moved, enrichment completed, partner inventory updated) need to:

1. Be recorded durably for replay, debugging, and audit.
2. Trigger downstream subscribers (enrichment fan-out, notifications, dbt refresh, content moderation).
3. Retry on failure with backpressure.
4. Be inspectable — operators need to see queue depth, failed jobs, and retry state.

Several approaches were evaluated:

| Approach | Infrastructure cost | Operational complexity | Elixir fit |
|----------|---------------------|----------------------|------------|
| **Kafka** | External cluster (managed ~R500+/mo, or self-hosted on Fly) | High — partitions, consumer groups, offset management, schema registry | Moderate — `brod` or `kafka_ex` libraries, extra config |
| **RabbitMQ** | External broker (self-hosted or managed) | Medium — exchanges, queues, bindings, dead-letter queues | Good — `amqp` library |
| **Oban (PostgreSQL-backed)** | Zero — uses the existing Neon PostgreSQL database | Low — single process in the Phoenix supervision tree, inspectable via `oban_jobs` table | Excellent — native Elixir, OTP-aware, standard Hex package |
| **GenServer + ETS** | Zero | Low | Native — but no persistence, no retry, no backpressure |

**Key architectural constraint:** The platform is a single-tenanted, owner-operated book management system for Phase 1. Even at 10,000 users the event volume is modest (see `docs/capacity-model.md` — ~50 events/user/day = 500K events/day at 10K users). This is well within PostgreSQL's operational envelope.

**Project constraint:** The CLAUDE.md explicitly lists "Add Kafka, RabbitMQ, or any external message broker" as a hard Do Not — this was settled early in the architecture decision.

---

## Decision

**Use Oban as the event bus and job processing backbone, backed by the existing PostgreSQL database.**

All significant state changes emit events via `Stacks.Events.emit/1`, which:
1. Inserts a row into the `op.event_log` table (durable, immutable, indexed).
2. Enqueues an Oban job for each registered subscriber.

**Event log schema:** `op.event_log` with `event_type`, `aggregate_type`, `aggregate_id`, `schema_version`, `payload` (JSONB), `metadata` (JSONB), `occurred_at`, `published_at`. Full schema in `docs/technical-architecture.md` section 7.

**Oban queue configuration** (`apps/core/config/config.exs`):

| Queue | Concurrency | Purpose |
|-------|------------|---------|
| `default` | 10 | General-purpose fallback |
| `events` | 20 | Event fan-out to registered subscribers |
| `vision` | 60 | GPU calls to Modal — expensive, rate-limited |
| `scraper` | 5 | Per-bookshop price fetches |
| `notifications` | 3 | Email delivery |
| `dbt_refresh` | 1 | Sequential dbt runs |

> **Note:** The original ADR planned dedicated queues for `review_scrape`, `author_scrape`, `source_discovery`, and `geographic_discovery`. These were never created — those workers run on the `default` queue instead, which provides sufficient concurrency for Phase 1 volumes.

**Event subscriber registration:** Subscribers register centrally via `Stacks.Events.Registry` — a compile-time module attribute mapping event types to handler modules implementing `Stacks.Events.Handler`. No GenServer or runtime state is involved.

**Retry strategy:** Built-in Oban exponential backoff with configurable max attempts per queue. Failed jobs transition to `discarded` state after max retries and remain inspectable in `oban_jobs`.

**Scheduling:** `Oban.Cron` handles periodic jobs (staleness-driven refresh, quarterly geographic sweeps, dbt refresh triggers).

---

## Consequences

**Positive:**
- Zero additional infrastructure — event bus uses the same Neon PostgreSQL instance already required for operational data.
- Full ACID guarantees — an event and its side effects are either both committed or both rolled back in a single database transaction.
- Inspectable — `oban_jobs` table is queryable with standard SQL. Operators can check queue depth, failed jobs, retry counts without a separate dashboard tool.
- Native Elixir/OTP integration — Oban runs in the Phoenix supervision tree. If the Phoenix app restarts, Oban picks up where it left off. No separate broker process to manage.
- Replay is possible — `event_log` stores all events with schema versions. Events can be replayed by querying the table and re-enqueueing jobs.
- Oban Pro (if needed) adds batch jobs, workflows, and enhanced metrics — all additive, no architecture change.

**Negative:**
- PostgreSQL is doing double duty as operational store and event bus. Under very high event volume (multi-million events/day), this could create write contention. Mitigation: partition `event_log` by month at 5M rows (see `docs/capacity-model.md`).
- No built-in topic fan-out like Kafka's consumer groups. Subscribers are Elixir modules registered at startup — adding a new subscriber requires a code deploy.
- Job payload size is bounded by PostgreSQL JSONB limits (~1GB technically, but large payloads are an anti-pattern). Image bytes are stored in job args for vision jobs; this is acceptable at the current vision queue concurrency.
- Event replay cannot selectively exclude side effects — if a subscriber sends an email, replaying the event will re-send the email. Replay should be done in a development environment or with side-effect guards.

**Not a constraint:**
- This decision does not prevent introducing Kafka or RabbitMQ in Phase 2 if event volume reaches a threshold that genuinely requires it. The `event_log` table and `Stacks.Events.emit/1` interface are stable; changing the delivery mechanism would be a subscriber-layer change.

**Monitoring:**
- Queue depth: `SELECT count(*) FROM oban_jobs WHERE state = 'available' GROUP BY queue`
- Failed jobs: `SELECT * FROM oban_jobs WHERE state = 'discarded' ORDER BY attempted_at DESC`
- See `docs/runbooks/oban-queue-backlog.md` for the full incident response procedure.
