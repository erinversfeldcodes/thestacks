# Issue #136: Release-to-main workflow with SLO gate + auto-rollback

## Summary
Build a production deploy workflow triggered on merge-to-main: deploy core/vision/scraper to prod Fly apps and Modal prod against the existing prod DB, run migrations, then gate release health on SLI thresholds backed by prom_ex metrics + synthetic probes. Auto-rollback on breach. Enforce expand–contract in CI so rollback never requires DB surgery.

## User Stories
N/A (platform work).

## Goal
- Merge to main deploys prod automatically, with no manual verification steps.
- If the deployed build is unhealthy for 10 min, it rolls back automatically.
- Breaking schema changes cannot land without the expand–contract two-PR sequence, enforced in CI.
- No standalone production DB replica needed for release rollback — Neon PITR remains the tool for data rollback only.

## Scope Check
This issue exceeds the usual limits and is intentional: it's a single coherent release-pipeline introduction. Subdivided into tasks via TaskCreate.

## Wiring
- [x] This issue includes router/workflow wiring and is operator-facing when complete.

## Technical Requirements

### SLIs (all hard gates, 10-min window)
| SLI | Source | Threshold |
|-----|--------|-----------|
| HTTP availability (non-5xx) | prom_ex Phoenix plugin + synthetics | ≥ 99% |
| HTTP p95 latency per route group | tagged phoenix.router_dispatch.stop.duration | ≤ 500ms (auth/catalogue), ≤ 2000ms (upload) |
| Upload pipeline success rate | new `[:stacks, :upload, :terminal]` event | ≥ 90% resolved vs total terminal |
| Oban failure rate per queue | prom_ex Oban plugin | ≤ 5% |
| Fuse open count | new periodic gauge | 0 |
| DB pool queue_time p95 | prom_ex Ecto plugin | ≤ 50ms |
| BEAM memory | prom_ex Beam plugin | ≤ 400MB |

### Synthetic probes
CI-driven, run during the 10-min gate window, every 30s:
- `GET /api/health`
- `GET /api/catalogue`
- `POST /api/auth/login` (owner)
- canary `POST /api/upload` (exercises vision end-to-end)

Probes provide a constant denominator when real traffic is sparse.

### Missing metrics to add
1. Route-grouping plug → tags Phoenix metrics by feature group.
2. Fuse state gauge via telemetry_poller (vision, together_ai, open_library, google_books, brave_search, scraper).
3. `[:stacks, :upload, :terminal]` event emitted when `uploaded_image` reaches `resolved`/`rejected`/`timeout`.
4. `/internal/metrics` auth (Fly 6PN allowlist or bearer token).

### Expand–contract enforcement
1. Turn on destructive squawk rules.
2. Migration linter (`scripts/lint-migrations.sh`) — destructive ops require `@breaking_ok <reason>` annotation.
3. Schema diff gate — DROP/ALTER TYPE/RENAME in structure.sql requires PR label `db-breaking`.
4. (Deferred) Two-step reference check — enforce mechanically that destructive migrations point to a prior merged commit that removed the code reference. Ship 1–3 first, evaluate need for 4.

### Rollback
- Core app: `fly deploy --image <prev-sha>` using the image digest recorded before deploy.
- Modal vision: `modal deploy` against the previous commit SHA. Ordering constraint from `docs/runbooks/vision-service-rollback.md`: **core rolls back before vision**.
- DB: no action. Expand–contract guarantees N-1 code works against N schema.

### Workflow triggering
- Initially: `workflow_run` trigger on `ci.yml` completion on **any branch** so we can iterate on the pipeline in PRs.
- Before merging this issue: switch to `on.push.branches: [main]` only.

## Reviewer Context
- `docs/technical-architecture.md` §4680–4700 has a skeleton prod-deploy flow; this issue replaces it with a real implementation.
- `docs/runbooks/vision-service-rollback.md` establishes core-before-vision ordering — critical for auto-rollback.
- `docs/agents/platform-agent.md` L42 references a `deploy-production.yml` that doesn't yet exist; this issue creates it.
- `apps/core/lib/core/prom_ex.ex` + `apps/core/lib/core_web/telemetry.ex` are where new metrics go.
- Neon PITR (7-day continuous WAL) remains the data-rollback tool. This workflow handles image/schema rollback only.

## Definition of Done
- [ ] Route-grouping plug emits `:route_group` tag; SLO thresholds computable per group.
- [ ] Fuse state gauge exported to /internal/metrics.
- [ ] Upload pipeline terminal counter exported, tagged by outcome.
- [ ] /internal/metrics rejects unauthenticated external requests.
- [ ] Synthetic probe script runs against a URL, exits 0/non-zero on health summary.
- [ ] Destructive squawk rules enabled; sample destructive migration fails CI.
- [ ] Migration linter fails on `drop_column` without `@breaking_ok`, passes with it.
- [ ] Schema diff gate fails on a DROP without `db-breaking` label.
- [ ] `deploy-production.yml` deploys core+vision+scraper, runs SLO gate, rolls back on breach.
- [ ] Workflow succeeds end-to-end when triggered on a healthy build.
- [ ] Workflow rolls back automatically when triggered on an intentionally broken build (test case).
- [ ] Before merge: workflow switched from `workflow_run` (any branch) to `push.main`.

## Dependencies
- Issue #004 (CI pipeline + deploy-preview) — provides `deploy-stack.sh` and the prod apps/secrets layout this builds on.

## Agent Assignment
platform-agent (infrastructure), elixir-agent (metrics), database-agent (migration enforcement).

## Progress Notes
2026-04-18: Issue created. Plan broken into 10 TaskCreate items for granular tracking. Implementation order: metrics → CI enforcement → workflow + gate.
