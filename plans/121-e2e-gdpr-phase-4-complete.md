# Phase 4 Complete — Issue #121: GDPR telemetry instrumentation + firing tests

**Status**: APPROVED (elixir-reviewer, 1 revision cycle)
**Agent**: elixir-agent · **Reviewer**: elixir-reviewer
**Type**: production code (observability-only; additive, no behavior change)

## What landed
Eight GDPR telemetry signals (`[:stacks, :gdpr, …]`) emitted from the domain/worker
layer and registered in the Prom_Ex plugin, with 10 non-vacuous firing tests.

| Signal | Event | Emitter | Measurements / metadata |
|---|---|---|---|
| Export outcome | `[:stacks, :gdpr, :export]` | `data_export_job.ex` | `%{count:1}` / `%{result: :ok\|:error}` |
| Deletion outcome + failed step | `[:stacks, :gdpr, :deletion]` | `account_deletion_job.ex` | `%{count:1}` / `%{result, failed_step}` (`:none` on success) |
| Consent grant | `[:stacks, :gdpr, :consent, :grant]` | `consent.ex` (`emit_consent/3`) | `%{count:1}` / `%{feature}` |
| Consent revoke | `[:stacks, :gdpr, :consent, :revoke]` | `consent.ex` (`emit_consent/3`) | `%{count:1}` / `%{feature}` |
| Image expired (by reason) | `[:stacks, :gdpr, :image, :expired]` | `image_retention.ex` | `%{count:n}` / `%{reason: "expired"\|"stuck"}` |
| Image stuck | `[:stacks, :gdpr, :image, :stuck]` | `image_retention.ex` | `%{count:n}` / `%{reason: "stuck"}` |
| Image orphan | `[:stacks, :gdpr, :image, :orphan]` | `image_retention.ex` | `%{count:n}` / `%{}` |
| Audit-write throughput | `[:stacks, :gdpr, :audit, :write]` | `audit.ex` (`{1,_}` branch) | `%{count:1}` / `%{action, resource_type}` |

Prom_Ex: 8 metric families in `Core.PromEx.Plugins.Stacks.event_metrics/0` — `counter`
for occurrence events (export/deletion/consent/audit), `sum` over `:count` for
batch-size image events. Not added to `CoreWeb.Telemetry.metrics/0` (PromEx consumes
plugin-returned metrics only — #139/#181 precedent, reviewer-verified).

## Gates
- 2A-i Failing-test: all 10 tests failed pre-impl (`assert_receive` timeouts — flows ran, no emitter fired). ✅
- 2A-iii Implement → 2A-iv Reception: independent DoD table; assertions pin exact event + measurements + metadata.
- 2B-i Regression: **1539 tests, 0 failures, 7 excluded** (orchestrator re-ran independently).
- 2B-ii Spec Coverage: §12 GDPR telemetry — all bullets covered.
- 2B-iia Fresh-DB: skipped (no migrations).
- 2B-iii Deploy+E2E: skipped (observability-only; no API/behavior change — E2E hardening is Phase 5).
- 2C Review: elixir-reviewer → **NEEDS_REVISION** (1 blocker) → fixed → **APPROVED**.

## Revision cycle 1 (reviewer blocker — fixed)
PromEx counter declared `tags: [:result, :failed_step]` but the deletion **success**
branch emitted `%{result: :ok}` with no `:failed_step`. `TelemetryMetricsPrometheus.Core`
`validate_tags_in_tag_values/2` drops any event missing a declared tag key, so
`stacks_gdpr_deletion_count_total{result="ok"}` was **never recorded** — only failures
counted. The firing tests missed it (they attach a raw handler, bypassing the reporter).
**Fix**: success branch now emits `%{result: :ok, failed_step: :none}` (tag set matches
the failure branch); success test asserts it. 10/10 green, format + credo clean.

## Reviewer non-blocking observations (no action required)
- `audit.ex` emit sits inside a `rescue`-wrapped fn but is safe: `:telemetry.execute/3`
  isolates each handler, never re-raises into the caller — cannot mask a committed audit row.
- Image `:expired` fires for stuck rows too (`reason: "stuck"`), mirroring the existing
  `image.expired` domain event. Dashboards must filter `reason="expired"` for the
  natural-TTL figure (documented in code).
- Emit-when-zero on image events is fine for `sum` (keeps series alive for absence alerts).
- Label cardinality bounded: `failed_step` (Multi step atoms), `action`/`resource_type`
  (fixed code-defined sets) — no user-supplied free text.
