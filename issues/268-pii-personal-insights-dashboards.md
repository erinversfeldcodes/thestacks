# Issue #268: User-facing PII / personal-insights dashboards

## Summary
Build user-facing "personal insights" dashboards that expose **each user's own** metrics to that
user (personal reading/collection stats, their own data-rights status, etc.) — as distinct from the
platform-wide operational metrics (now Grafana, ADR-021) and the public `/costs` page.

## User Stories
New (to be authored) — personal-insights / "your stats" surface. NOT US-5.1.1 (that was the
platform-ops dashboard, deprecated in #267).

## Goal
A signed-in user can view metrics scoped to their own account/data, gated so users only ever see
their own PII (never platform-wide or other users' data).

## Scope Check
Backlog / not yet scoped — will be split into properly-sized issues when picked up. This is a
placeholder capturing the intent + prior art so it isn't lost.

## Wiring
TBD — user-facing, will include router/UI wiring.

## Feature-Completeness Pre-Check
TBD at planning time (run the `feature-completeness` skill when this is worked).

## Technical Requirements (sketch — to be refined)
- **Auth model:** user-scoped (a user's normal session), returning ONLY that user's data — a
  fundamentally different access model from the deprecated ops dashboard (which required
  `admin_session`). Design the gating carefully (GDPR: personal data exposed to its owner only).
- **Prior art (#261/#262):** the deprecated ops dashboard's `{data: …}` decoder-envelope contract
  (#261) and mart-less live-query aggregation pattern (#262) are useful reference for the
  frontend↔backend contract and the aggregation approach — see git history of `feat/119-e2e`
  (`MetricsController`, `Stacks.Admin.Metrics`, `Api.elm` metrics decoders) before they were removed
  in #267.
- **Do NOT** reuse the admin-session/break-glass flow — personal insights are per-user, not admin.

## Reviewer Context
- Cross-check against ADR-021 (Grafana ops metrics) and ADR-018 (Audience/visibility) so the personal
  surface doesn't duplicate ops metrics and respects the visibility model.

## Test Audit
Deferred — generate the 13-layer audit when this is scoped for implementation (`test-audit` skill).

## Definition of Done
- [ ] Scoped into properly-sized implementation issues (this is a backlog placeholder) — evidence: child issues filed
- [ ] (per child) Feature-Completeness Pre-Check ✅, Test audit GREEN, `just verify` passes

## Dependencies
Follows #267 (which deprecated the ops-metrics SPA dashboard and preserved the #261/#262 pattern as
prior art). Backlog — not part of the #119 epic.

## Agent Assignment
elixir-agent + elm-agent (when scoped)

## Progress Notes
- 2026-07-20: Filed as the forward-looking home for personal-insights dashboards, capturing #261/#262
  as prior art per the owner's note during #119.
