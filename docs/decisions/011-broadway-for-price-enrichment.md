# ADR 011: Broadway for Price Enrichment Pipeline

**Status:** Accepted
**Date:** 2026-03-20
**Deciders:** Platform owner
**Technical area:** Enrichment infrastructure, data ingestion

---

## Context

Issue #050a introduced price scraping: an Oban worker calls the Rust scraper for each ISBN × store pair, then persists results to `op.price_snapshots`. The question was how to handle persistence of scrape results.

Current volume is low — a handful of bookstores × hundreds of books = thousands of scrape results per batch run. But the enrichment layer is designed to grow: more stores, more books, partner-submitted inventory feeds, and eventually real-time price webhooks.

**Options evaluated:**

| Approach | Complexity | Backpressure | Batch efficiency | Future-ready |
|----------|-----------|--------------|-----------------|-------------|
| Direct `Repo.insert/1` per result in Oban worker | Low | None — Oban retry is the only safety valve | O(n) individual inserts | No |
| `Repo.insert_all/2` in Oban worker with chunking | Low | Manual chunking logic | Batched, but no flow control | Partial |
| Broadway pipeline with DummyProducer | Medium | Built-in GenStage backpressure | Configurable batch size + timeout | Yes |
| Broadway with external producer (SQS, Redis) | High | Full distributed backpressure | Batched | Over-engineered for current needs |

---

## Decision

**Use Broadway with `DummyProducer` for price enrichment persistence.**

The Oban worker (`TriggerPriceScrapeJob`) collects scrape results and pushes them to the Broadway pipeline via `Broadway.push_messages/2`. The pipeline validates, batches, and bulk-inserts.

```
TriggerPriceScrapeJob (Oban)
  → collects scrape results from Rust scraper
  → pushes to PricePipeline via Broadway.push_messages/2

PricePipeline (Broadway)
  → Processor: validates price data (required fields, non-negative price)
  → Batcher: collects up to 50 messages or 5s timeout
  → handle_batch: Repo upsert per message, emit event on success
  → handle_failed: log failures (no retry — Oban handles job-level retry)
```

**Why DummyProducer:** We don't have an external message source (no SQS, no Redis). Messages are pushed synchronously from the Oban worker. `DummyProducer` is Broadway's built-in producer for this "push, don't pull" pattern.

**Why not direct inserts:** The current volume doesn't require Broadway. But:
1. Broadway's batch + backpressure model prevents database overload if volume spikes (partner inventory feeds, bulk imports)
2. The `handle_message` → `handle_batch` separation cleanly separates validation from persistence
3. `handle_failed` provides a structured error-handling path separate from the happy path
4. Broadway telemetry integrates with our PromEx metrics pipeline for free

**Why not a full external producer:** Adding SQS or Redis as a producer would introduce infrastructure we don't need. Oban already provides job persistence and retry. Broadway adds flow control within the process.

---

## Consequences

**Positive:**
- Batch inserts are controlled: 50 messages or 5 seconds, whichever comes first. Database never sees unbounded insert storms.
- Adding a second enrichment pipeline (e.g., partner inventory) follows the same pattern.
- Broadway telemetry gives us batch duration, message count, and failure rate metrics without custom instrumentation.
- The DummyProducer can be swapped for a real producer (e.g., Broadway.Plug for webhooks) without changing the processor/batcher logic.

**Negative:**
- Adds a supervised GenStage process to the application tree. Must be conditionally excluded in test environment to avoid Ecto sandbox conflicts (documented in `application.ex`).
- Slightly more complex than direct inserts for the current low volume. New contributors must understand Broadway's message lifecycle.
- The `push_messages/2` call in the Oban worker creates a coupling between the worker and the pipeline process name.

**Test environment note:**
Broadway batch processors spawn in separate PIDs that don't have Ecto sandbox access. The `PricePipeline` is excluded from the supervision tree in test mode via `pipeline_children/0` in `application.ex`. Tests that need the pipeline start their own named instance via `start_supervised!/1`.
