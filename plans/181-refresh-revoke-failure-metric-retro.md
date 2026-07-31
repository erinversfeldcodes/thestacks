# Retrospective — Issue #181 (metric on refresh revoke-failure)

**Date**: 2026-07-10 · **Agent**: elixir-agent · **Revision cycles**: 0 · **Outcome**: merged into `feat/124-e2e-auth`

## What worked well
- **The agent found an honest way to drive the real branch instead of settling for a wiring-only
  test.** The hard part of #181 was that forcing `Guardian.revoke` to fail for an otherwise-valid
  request looked to require a production seam. The agent discovered `Guardian.revoke("not-a-real-token")`
  returns `{:error, :not_found}` cleanly while the mint still succeeds from `current_resource` — so a
  direct `refresh/2` call with a bad current-token exercises the genuine `error ->` branch (warning
  logged, 200 minted) and the telemetry assertion is non-vacuous. No test-only seam added to prod.
- **Two complementary tests, each honestly scoped.** Controller test proves *the branch emits*; the
  PromEx test proves *the emission is registered/exported*. Neither over-claims — the reviewer called
  out that the split is stated in the test's own comment.
- **Proportionate gating paid off.** A ~4-line observability change ran through `just verify` + a
  focused reviewer and skipped deploy/E2E/PE with recorded reasons — fast, and nothing material was
  waved through (reviewer still checked PII/tag cardinality and RED meaningfulness).

## What caused friction
- **Essentially none — this was the clean tail of the #173 chain.** The only judgement call was the
  test strategy, and the "is a real failure forceable without contortions?" question resolved to yes.
  The plan's hedge ("stub/inject a revoke error, OR exercise the branch directly") correctly left the
  door open for the cleaner option the agent then found.

## What should change in the agent system
| File to change | Recommended change | Evidence |
|---|---|---|
| `.claude/skills/write-validation-test/SKILL.md` | Add a note: before adding a test-only seam to force an error branch, probe whether the real dependency already returns the error cleanly for a crafted-but-valid input (e.g. `Guardian.revoke` on a well-formed-but-unknown token → `{:error, :not_found}` with no raise). Prefer driving the real branch over a production seam. | #181's `"not-a-real-token"` approach avoided a seam entirely. |
| (none else) | The existing telemetry/PromEx pattern (`Event.build` + counter + `prom_ex_custom_metrics_test.exs`) was discoverable and reused without friction — no doc change needed. | 0 revision cycles. |

## Candidate follow-up (noted, not filed)
- `logout/2` (`auth_controller.ex:100`) has an identical unmetered revoke-failure branch; a symmetric
  `[:stacks, :auth, :logout, :revoke_failed]` counter is a clean tiny add if logout-revoke alerting is
  ever wanted. Low value; capture on demand.

## Batch position
Follow-up #1 of #178–182 complete (order 181 → 178 → 182 → 179 → 180, per-issue gates). Next: **#178**
(extend the interceptor to the 11 OutMsg-less pages + the boot-time `GotPlacementCheck` 401 hook).
