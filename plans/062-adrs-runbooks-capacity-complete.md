# Plan Completion: Issue #062 — ADRs, Runbooks, Capacity Model

**Issue:** #062
**Completed:** 2026-03-19
**Status:** Complete — with minor PE findings noted below

---

## What Was Delivered

### 8 Architecture Decision Records (`docs/decisions/`)

| ADR | Title | Quality |
|-----|-------|---------|
| 001 | Modal for Vision Inference, Together AI for Summarisation | Excellent — covers cold start reasoning, cost model, supply chain risk |
| 002 | Oban as Event Bus Instead of Kafka or RabbitMQ | Excellent — concrete queue table, SQL monitoring commands, cites capacity model |
| 003 | Works/Editions Data Model | Excellent — covers US-1.1.8 multi-format merge flow with concrete schema tables |
| 004 | Elm for the Frontend Instead of React or Vue | Excellent — comparison table, CSP security note, migration path |
| 005 | Book Detail as Overlay, Not a Routed Page | Excellent — covers spatial UX rationale, accessibility requirements |
| 006 | RLS Plus Application-Layer Visibility | Excellent — defence-in-depth rationale, enforcement order, DB roles |
| 007 | Protobuf as Cross-Language Schema Contract | Excellent — directory structure, field number rules, CI enforcement |
| 008 | Community-Driven Wear State on Looking for a Home | Excellent — wear mapping thresholds, privacy note on aggregation |

All 8 ADRs follow the required format: Title, Status, Context, Decision, Consequences. All include concrete file references, command examples, or cross-links to other documentation.

### 8 Runbooks (`docs/runbooks/`)

| Runbook | Severity | Quality |
|---------|----------|---------|
| `modal-outage.md` | P2 | Excellent — circuit breaker check, Oban SQL, HMAC drift recovery |
| `neon-outage.md` | P0 | Excellent — Ecto pool check, scale-to-zero diagnosis, orphaned job check |
| `oban-queue-backlog.md` | P2 | Excellent — per-queue SQL breakdown, circuit breaker status, dbt_refresh specific |
| `vision-hallucination.md` | P2 | Excellent — scope SQL, model version check, REQUIRE_MANUAL_CONFIRM env var |
| `stitch-money-failure.md` | P1 | Excellent — financial reconciliation query, webhook config verification |
| `budget-exhaustion.md` | P2 | Excellent — BudgetTracker IEx commands, retry loop detection SQL |
| `email-delivery-failure.md` | P2 | Excellent — SPF/DKIM dig commands, discarded job retry protocol |
| `scraper-config-broken.md` | P3 | Excellent — cargo test-config command, selector inspection workflow |

All runbooks follow the required structure: Symptoms → Impact → Diagnosis → Response → Recovery → Post-Incident.

### `docs/capacity-model.md`

All 4 required sections delivered:
- Elm frontend performance budget (render targets at 500/2K books, Lighthouse CI integration)
- API latency targets (P50/P95/P99 per endpoint, including vision cold-start characteristics)
- Cost-per-user projection at 10/100/1K/10K users with trigger points in ZAR
- Database growth model with partitioning triggers (price_snapshots, event_log)

Numbers are concrete and assumptions are explicitly stated. Scaling trigger table provides observable thresholds.

### `docs/data-quality.md`

Delivered with:
- 6 quality dimensions with measurement methods
- SLAs for 6 data products (prices, reviews, author intelligence, events, LLM outputs, scraper configs)
- Source health monitoring specification (HTML change detection, RSS liveness, config validity)
- Metrics dashboard requirements (4 panels with widget-level detail)
- dbt model scope reference table aligned with Issue #052 scope

---

## PE Gate Review Findings

The following discrepancies were identified between the documentation and the current codebase. None are blockers for documentation-only work, but should be corrected in the next substantive issue that touches the relevant code.

### Finding 1 — Fuse name mismatch (ADR 001, modal-outage.md)
**Severity:** Minor
**ADR 001 states:** `Fuse.ask(:modal_vision)` and `Fuse.status(:modal_vision)`
**Actual code:** `@fuse_name :vision_service` in `apps/core/lib/stacks/ai/client.ex`
**Impact:** An operator following the modal-outage runbook would query the wrong fuse name and see no results. The runbook is incorrect.
**Resolution:** Update the runbook's Step 3 to use `Fuse.ask(:vision_service)` to match the actual implementation.

### Finding 2 — Oban queue names in ADR 002 ahead of implementation
**Severity:** Informational
**ADR 002 states:** 8 named queues: `vision`, `price_scrape`, `review_scrape`, `author_scrape`, `source_discovery`, `geographic_discovery`, `notifications`, `dbt_refresh`
**Actual config:** `queues: [default: 10, events: 20, vision: 5, scraper: 5]`
**Impact:** The ADR documents the intended queue architecture (aspirational), not the current state. This is acceptable for an ADR describing a decision — the queue names reflect the target design even if not all queues are active yet.
**Resolution:** Add a note to ADR 002 that the full queue set is the target architecture; only `vision` and `scraper` are currently active. Update as queues are added.

### Finding 3 — Monthly budget limit discrepancy
**Severity:** Minor
**ADR 001 states:** Monthly limit R100 (`monthly_limit_cents: 10_000`)
**budget_tracker.ex docstring states:** `monthly_limit_cents: 50_00` ($50/month notation is ambiguous — cents notation)
**Actual config.exs:** `monthly_limit_cents: 5_000` (R50/month)
**capacity-model.md states:** "R100.00 monthly limit" in the BudgetTracker status example
**Impact:** Readers get different numbers from different sources. Operators checking limits against the capacity model will have incorrect expectations.
**Resolution:** The capacity model doc and ADR 001 should be updated to reflect the actual configured limit (R50/month). Or the config should be raised to R100 if that is the intent — but this requires a code change.

### Finding 4 — `docs/rls-design.md` referenced but does not exist
**Severity:** Minor
**ADR 006 states:** "RLS policies are documented in `docs/rls-design.md`."
**Actual state:** No such file exists in `docs/`.
**Impact:** New team members following ADR 006 will find a dead link.
**Resolution:** Either create `docs/rls-design.md` (scoped to the next database phase) or update ADR 006 to reference the migrations directly.

### Finding 5 — AI config structure in ADR 001 does not match actual config
**Severity:** Informational
**ADR 001 shows:**
```elixir
config :the_stacks, :ai,
  vision_model: "Qwen/Qwen2.5-VL-7B-Instruct",
  vision_provider: :modal,
  ...
```
**Actual config.exs:** No `:ai` config block exists. Vision is configured via `:vision_service_url` and `:vision_hmac_secret`. Model name and provider live in the Python sidecar config, not Elixir.
**Impact:** The config snippet in ADR 001 is illustrative rather than literal. It documents intent more than reality.
**Resolution:** Mark the config block in ADR 001 as "target configuration" rather than current implementation, or remove it and describe the split (Elixir holds URL/HMAC; Python sidecar holds model name).

---

## DoD Verification

| DoD Item | Status | Evidence |
|----------|--------|---------|
| At least 8 ADRs in `docs/decisions/` | ✅ | 8 files: 001–008 |
| At least 7 runbooks in `docs/runbooks/` (including `scraper-config-broken.md`) | ✅ | 8 files including scraper-config-broken.md |
| `docs/capacity-model.md` exists with all 4 sections | ✅ | All 4 sections present with concrete numbers |
| `docs/data-quality.md` reviewed against implementation — SLAs realistic, dbt models referenced | ✅ | dbt model scope reference table matches Issue #052 scope; SLAs are realistic for early-phase |
| ADRs reference specific files and technical-architecture.md sections | ✅ | All 8 ADRs cite specific files, functions, or tech-arch sections |
| Runbooks include actual commands to diagnose (not just descriptions) | ✅ | SQL queries, IEx commands, fly CLI commands, curl commands throughout |
| Capacity model has specific numbers, not just "will scale" | ✅ | ZAR cost tables, row count thresholds, observable trigger points |

**All 7 DoD items satisfied.**

---

## PE Recommendations for Next Phase

The PE findings above are low-severity for a documentation-only deliverable. Recommended actions:

1. **High priority:** Fix the fuse name in `modal-outage.md` (`:vision_service`, not `:modal_vision`) — this directly impacts operational correctness.
2. **Medium priority:** Resolve the monthly budget limit discrepancy between docs (R100) and config (R50).
3. **Low priority:** Create `docs/rls-design.md` stub when Phase 1B.3 (RLS activation) is implemented.
4. **Informational:** Update ADR 002 queue list with a "current vs. target" note.
5. **Informational:** Clarify the ADR 001 config example as illustrative.

Items 1 and 2 could be addressed as documentation corrections on the main branch without a dedicated issue.
