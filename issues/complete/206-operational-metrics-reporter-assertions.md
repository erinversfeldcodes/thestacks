# Issue #206: Assert operational metrics at the reporter layer (auth §12 + GDPR PromEx tag-sets)

## Summary
Completion-bar item 2 requires operational metrics to be **asserted** at the reporter/tag-set layer, not marked `n/a`. Two gaps: #124 auth §12 counters have no firing test, and #121 GDPR telemetry is asserted only at the `:telemetry` handler level, not at the PromEx reporter/tag-set level.

## User Stories
None directly (observability hardening for the #124 auth and #121 GDPR families).

## Goal
Each named counter both **fires** and is **exported with the correct tag-set** at `/internal/metrics`, or carries a formal `n/a` with written rationale.

## Scope Check
- Touches 0 controllers (test + possibly PromEx plugin tags). OK.
- Adds 0 endpoints. OK.
- Test additions well under 300 LOC. OK.
- Single concern (metric assertion). OK.

## Wiring
- [ ] This issue includes router wiring and is user-facing when complete.
- [x] This issue is implementation only (observability tests / tag-set fixes).

## Feature-Completeness Pre-Check
n/a — no user stories (observability hardening). Metrics exist; assertions are missing.

## Technical Requirements
- **(a) Auth §12 metrics (#124):** registration success/failure, JWT issuance count, login-failure-by-type (401/403/422/429) have **no firing test** — only the #181 refresh-revoke counter is asserted (`prom_ex_custom_metrics_test.exs:70`). Add firing tests for each, using the established pattern: emit the `:telemetry` event, `Process.sleep(50)`, scrape `PromEx.get_metrics(Core.PromEx)`, assert the `stacks_*` family name appears.
- **(b) GDPR telemetry (#121):** currently asserted at `:telemetry` handler level but **not at the PromEx reporter/tag-set level** — the Phase-4 tag-drop slipped past. Add reporter-tag-set assertions so each GDPR counter is exported with the expected label set (not just present).
- Assert **tag-sets**, not just family-name presence: a counter exported with dropped/wrong tags is a silent regression the current family-name check misses.

## Reviewer Context
- Pattern to follow: `apps/core/test/core/prom_ex_custom_metrics_test.exs:70` (`async: false`; PromEx is global; the app supervisor starts `Core.PromEx` in test env).
- `PromEx.get_metrics/1` returns `:prom_ex_down` if PromEx isn't running — keep the `refute output == :prom_ex_down` guard.
- Family-name-only assertions (as the existing tests use) are insufficient here — the requirement is tag-set correctness.

## Test Audit
| Layer | Applies? | Verdict |
|-------|----------|---------|
| operational metrics (auth §12 counters) | yes | ❌ no firing test → ✅ each fires + tag-set exported |
| operational metrics (GDPR PromEx tag-sets) | yes | ❌ handler-level only → ✅ reporter/tag-set asserted |
| 1–10, 12–13 | no | n/a — metric-assertion issue |

Punch list:
1. Registration success/failure counter fires + tag-set — `prom_ex_custom_metrics_test.exs`.
2. JWT issuance counter fires + tag-set.
3. Login-failure-by-type (401/403/422/429) fires + tag-set.
4. GDPR counters exported with correct tag-set (not just name).
5. Any genuinely-not-emitted metric → formal `n/a` + rationale (not silent).

Verdict: ❌ until each named counter fires AND exports with the right tag-set.

## Definition of Done
- [ ] Auth §12 counters (registration success/failure, JWT issuance, login-failure-by-type) each have a firing + tag-set test.
- [ ] GDPR counters asserted at the PromEx reporter/tag-set level (labels verified).
- [ ] Any counter that is legitimately not emitted carries a formal `n/a` with rationale.
- [ ] Every behaviour has a validation path.
- [ ] Tests written and passing (`just run mix test`).
- [ ] Standards compliance verified (`just verify` passes).
- [ ] **Test audit (above) is GREEN** — 0 ❌, 0 ⚠️.
- [ ] **Meets the Completion Bar** (`docs/agents/standards/completion-bar.md`) — all 7 items (metrics **asserted**, not assumed).

## Dependencies
#124 (auth metrics), #121/#181 (GDPR + refresh-revoke counter), #139 (PromEx export wiring).

## Agent Assignment
elixir-agent.

## Progress Notes
_none yet._
