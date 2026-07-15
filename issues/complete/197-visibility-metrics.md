# Issue #197: Visibility Metrics Instrumentation

**Epic:** #122 (E2E Test Suite — Privacy & Visibility) · integration branch `feat/122-e2e`

## Summary
Instrument the ~10 visibility-specific telemetry counters enumerated in #122 §12 (punch #20). None currently exist — confirmed by grep across `visibility.ex`, `social.ex`, `view_as_plug.ex`, `visibility_recap_job.ex`, and `core_web/telemetry.ex`. Add telemetry FIRING tests. Metrics instrumentation only — no new user stories.

## User Stories
None claimed. Instruments operational metrics (Layer 11) for the already-built visibility system.

## Wiring
- [ ] This issue includes router/UI wiring and is user-facing when complete.
- [x] This issue is implementation only (telemetry instrumentation + firing tests). Wired by n/a.

## Feature-Completeness Pre-Check
n/a — no new user stories claimed; instruments/tests against the already-built surface (see #122 audit).

## Technical Requirements
Instrument ~10 visibility telemetry counters (emit + firing tests, following `apps/core/test/.../observability_telemetry_test.exs` patterns):
1. Profile-visibility change count by direction (tighten / loosen).
2. Recap outcome + cap counts (bookshelves / placements / posts).
3. Block / unblock counts.
4. Block error rates (`cannot_block_self`, `already_blocked`).
5. `:rate_limit_social` hit count.
6. ViewAs usage + error counts by perspective type.
7. Ceiling-rejection counts.
8. Crawler / robots.txt fetch counts.

Instrumentation sites: `apps/core/lib/stacks/visibility.ex`, `apps/core/lib/stacks/social/social.ex`, `apps/core/lib/stacks_web/plugs/view_as_plug.ex`, `apps/core/lib/stacks/workers/visibility_recap_job.ex`, and register in `core_web/telemetry.ex`.

**Coordination note:** coordinate the `:rate_limit_social` counter with #195's rate-limit test (punch #3) so the counter and the 429 assertion agree.

## Reviewer Context
- Telemetry firing tests attach a handler and assert the `:telemetry.execute` event fires — see `observability_telemetry_test.exs`.
- Layer 11 was previously `n/a — covered by SLO gate`; this issue resolves punch #20 by instrumenting rather than descoping.

## Definition of Done
- [ ] ~10 visibility counters emit at the sites above.
- [ ] Telemetry firing tests pass for each counter.
- [ ] `:rate_limit_social` counter reconciled with #195's rate-limit test.
- [ ] `just verify` passes.
- [ ] The #122 audit punch #20 (Layer 11) goes GREEN.

## Dependencies
Epic #122. Targeted modules already exist. Soft-coordinates with #195 (`:rate_limit_social`).

## Agent Assignment
elixir-agent.

## Progress Notes
- 2026-07-14: Created as child of #122 epic (feat/122-e2e).
