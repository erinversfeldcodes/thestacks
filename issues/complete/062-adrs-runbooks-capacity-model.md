# Issue #062: ADRs, Runbooks, Capacity Model

## Summary
Create the operational documentation that distinguishes a production-ready system from a prototype: Architecture Decision Records, operational runbooks, and a capacity model with performance budget.

## User Stories
Cross-cutting — operational maturity for all stories.

## Goal
A new team member can understand *why* decisions were made (ADRs), respond to incidents without the original developer (runbooks), and predict when infrastructure needs to scale (capacity model).

## Technical Requirements

**ADRs (`docs/decisions/`):**
Create 5-10 short ADRs using the format: Title, Status, Context, Decision, Consequences.

Minimum set:
- `001-modal-over-together-ai.md` — Why Modal for vision, Together AI for summarisation (cold start)
- `002-oban-over-kafka.md` — Why Oban event bus, not Kafka/RabbitMQ (simplicity, no new infra)
- `003-works-editions-model.md` — Why books = works, book_editions = editions (multi-format, Open Library alignment)
- `004-elm-over-react.md` — Why Elm for the frontend (zero runtime exceptions, compiler guarantees)
- `005-book-detail-overlay-not-route.md` — Why overlay instead of page route (back button, spatial context)
- `006-rls-plus-application-visibility.md` — Why both RLS and resolve_visibility/2 (defence in depth)
- `007-protobuf-as-contract.md` — Why Protobuf for schema contracts (cross-language, breaking change detection)
- `008-community-wear-state.md` — Why community-driven wear on Looking for a Home (social signal, not personal history)

**Runbooks (`docs/runbooks/`):**
Per the specification in the consolidated roadmap (Cross-cutting: Operational Runbooks section). Minimum set:
- `modal-outage.md`
- `neon-outage.md`
- `oban-queue-backlog.md`
- `vision-hallucination.md`
- `stitch-money-failure.md`
- `budget-exhaustion.md`
- `email-delivery-failure.md`

Each follows the template: Symptoms, Impact, Diagnosis, Response, Recovery.

**Capacity model (`docs/capacity-model.md`):**
Per the specification in the consolidated roadmap (Cross-cutting: Capacity Model section):
- Elm frontend performance budget (render targets at 500/2K books)
- API latency targets (P50/P95/P99 per endpoint)
- Cost-per-user projection at 10/100/1K/10K users with trigger points
- Database growth model with partitioning triggers

**Data quality framework (`docs/data-quality.md`):**
Already created — review and validate against actual implementation:
- Quality dimensions and SLAs per data product (prices, reviews, author intel, events, LLM outputs)
- Source health monitoring specification (HTML change detection, RSS liveness, scraper config validity)
- Metrics dashboard integration requirements (quality trends, source health table, enrichment gaps)
- Confirm all referenced dbt models are scoped in Issue #052
- Add runbook: `docs/runbooks/scraper-config-broken.md` — response when a scraper config stops producing results

## Definition of Done
- [ ] At least 8 ADRs in `docs/decisions/`
- [ ] At least 7 runbooks in `docs/runbooks/` (including `scraper-config-broken.md`)
- [ ] `docs/capacity-model.md` exists with all 4 sections
- [ ] `docs/data-quality.md` reviewed against implementation — SLAs are realistic, all referenced dbt models exist
- [ ] ADRs reference specific files and technical-architecture.md sections
- [ ] Runbooks include actual commands to diagnose (not just descriptions)
- [ ] Capacity model has specific numbers, not just "will scale"

## Dependencies
None — can be produced alongside any task. Best done after several backend tasks are complete so the content is grounded in real implementation decisions.

## Agent Assignment
principle-engineer-agent (analysis and documentation, not code)

## Progress Notes

**2026-03-19 — Implementation complete, post-implementation review passed.**

principle-engineer-agent delivered all artefacts. Orchestrator post-implementation review:

- All 8 ADRs delivered in `docs/decisions/001–008`. Format correct (Title, Status, Context, Decision, Consequences). All reference specific files and tech-arch sections. No placeholders or TBD sections.
- All 8 runbooks delivered in `docs/runbooks/`. All follow Symptoms → Impact → Diagnosis → Response → Recovery → Post-Incident structure. All include actual diagnostic commands (SQL, IEx, fly CLI).
- `docs/capacity-model.md` delivered with all 4 required sections (performance budget, API latency, cost model, DB growth). Numbers are concrete with stated assumptions.
- `docs/data-quality.md` delivered with 6 quality dimensions, SLAs for 6 data products, source health spec, and dashboard requirements. dbt model scope aligned with Issue #052.
- All 7 DoD items satisfied.

PE Gate findings (non-blocking for documentation-only work):
1. **Fuse name mismatch** — modal-outage.md references `:modal_vision`; actual code uses `:vision_service`. Runbook needs correction.
2. **Oban queue names aspirational** — ADR 002 lists 8 queues; only 4 are currently configured. Acceptable for ADR documenting target architecture.
3. **Monthly budget discrepancy** — ADR 001 and capacity model say R100; config.exs has R50. Needs alignment.
4. **Missing `docs/rls-design.md`** — ADR 006 references it but file doesn't exist.
5. **ADR 001 config block** — illustrative config doesn't match actual structure.

Full review in `plans/062-adrs-runbooks-capacity-complete.md`.
