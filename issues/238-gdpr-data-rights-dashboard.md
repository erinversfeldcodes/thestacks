# Issue #238: GDPR data-rights dashboard (+ export/deletion latency, audit-read counter)

> **Wave 2 of the #231 observability initiative — DEFERRED.** Do not start until the current
> #118 + #231 epic ships its PR.

## Summary
GDPR telemetry is **fully wired** (export, deletion+failed_step, consent grant/revoke by feature,
image expired/stuck/orphan, audit write) but **dashboarded nowhere**. Build a data-rights dashboard,
and close two small gaps: export/deletion have counts but **no latency distribution** (can't watch the
30-day SLA), and audit-log **reads** are unmetered (only writes). This dashboard is the operational
spine of the #234 user-facing transparency page.

## User Stories
None directly — observability of GDPR/data-rights (US-8.x). Child of epic **#231** (Wave 2). Feeds #234.

## Goal
A data-rights dashboard exposes export/deletion outcomes + latency, consent adoption by feature, and
retention purges, each panel teaching; the two metric gaps (latency, audit-read) are wired; drift +
live-exposure tests prove the families appear after a real export/deletion/consent interaction.

## Scope Check
- >3 controllers? No. >2 endpoints? No. >300 LOC? No (dashboard JSON + 2 small metric additions +
  tests). Mixed concerns? No — GDPR observability.

## Wiring
- [x] Ops-facing (Grafana via #232) + feeds the #234 user-facing surface.

## Feature-Completeness Pre-Check
n/a — no user story. GDPR features + most metrics are BUILT (#121/#183–#189, `gdpr_telemetry_test.exs`);
this dashboards them + adds latency/read observability.

## Technical Requirements

### 1. Dashboard (`apps/core/priv/grafana/gdpr_data_rights.json` via `dashboards/0`), teaching panels over the EXISTING families:
- **Export** requests by `result` (`stacks_gdpr_export_count_total`) — *data-portability demand + failures.*
- **Deletion** by `result` + `failed_step` (`stacks_gdpr_deletion_count_total`) — *erasure success; a rising `failed_step` → a broken cascade branch (which one).*
- **Consent** grant/revoke by `feature` (`…_consent_grant/revoke`) — *opt-in adoption + withdrawal per feature (analytics, writing-assistant, …).*
- **Image retention** expired/stuck/orphan by `reason` (`…_image_*`) — *is the 30-day image purge keeping up? `stuck` climbing → a purge backlog.*
- **Audit writes** by `action`/`resource_type` (`…_audit_write`) — *admin/data-access activity volume.*

### 2. Close the two gaps
- **Export/deletion latency distribution:** add a `:telemetry` duration measurement (or a distribution
  metric) on the export + deletion jobs (`workers/data_export_job.ex:35`, `account_deletion_job.ex:23`)
  so a panel can show p95 against the 30-day erasure/export promise. Firing test.
- **Audit-log read counter:** emit `[:stacks, :gdpr, :audit, :read]` where audit entries are read
  (`gdpr_controller`/`audit.ex` read path) so the "who looked at the audit log" side is observable, not
  just writes. Register + firing test.

### 3. Drift + live-exposure tests (per #230)
- Drift: dashboard ↔ registered families; every GDPR family has a panel.
- Live-exposure: trigger an export, a deletion, and a consent grant/revoke, then assert
  `GET /internal/metrics` shows the `stacks_gdpr_*` families (incl. the new latency + audit-read) with samples.

## Reviewer Context
- No PII in tags — `feature`/`result`/`reason`/`action`/`resource_type` are whitelisted atoms; never an
  email/user-id (GDPR: these metrics MUST NOT re-introduce personal data into the warehouse-adjacent sink).
- GDPR features + existing metrics are done (#121/#183–#189); this adds a dashboard + latency + audit-read only.
- The dashboard's panel copy should be reusable as source material for the #234 user-facing page
  ("here's the data-rights machinery, and here's how we watch it works").

## Test Audit
_Compact — observability; existing metrics + 2 small additions._

| Layer | Applies? | Verdict |
|-------|----------|---------|
| Dashboard exists + registered + teaching | yes | ❌ no GDPR dashboard. (→ ✅) |
| Export/deletion latency metric | yes | ❌ only outcome counters exist. (→ ✅) |
| Audit-read counter | yes | ❌ only writes metered. (→ ✅) |
| Drift + live-exposure | yes | ❌ (→ ✅) |
| Existing GDPR counters | — | ✅ (unchanged, `gdpr_telemetry_test.exs`) |
| 1–13 app layers | no | n/a — GDPR behaviour covered by #121/#183–#189. |

Punch: (1) dashboard + teaching panels; (2) export/deletion latency + firing test; (3) audit-read counter + firing test; (4) drift; (5) live-exposure.
Verdict: baseline — 5 punch items.

## Definition of Done
- [ ] `gdpr_data_rights` dashboard registered via `dashboards/0`, every panel teaching.
- [ ] Export/deletion latency metric + audit-read counter wired, registered, firing-tested.
- [ ] Drift + live-exposure tests (families appear after export/deletion/consent interaction).
- [ ] `just verify` passes; test audit GREEN; no PII in tags (GDPR-reviewed).
- [ ] Meets the Completion Bar.

## Dependencies
#121/#183–#189 (GDPR features + metrics — merged). **Deferred: start after the current #118+#231 PR.**

## Agent Assignment
elixir-agent (dashboard + latency/read metrics + tests). Reviewer: elixir-reviewer + platform-reviewer;
gdpr-review skill as a lens on the new metric tags.
