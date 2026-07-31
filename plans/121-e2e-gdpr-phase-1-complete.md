# Phase 1 Complete — Issue #121: Erasure invariants (SECURITY)

**Status**: APPROVED (elixir-reviewer, 1 revision cycle)
**Agent**: elixir-agent · **Reviewer**: elixir-reviewer
**Type**: test-only (no production code changed)

## What landed
Three teeth-giving tests against the built v1 erasure contract:
- `gdpr_controller_test.exs` — `DELETE /api/gdpr/account` writes a `user.deletion_requested` audit row (acting user_id, resource_type "user", resource_id = user), written synchronously by the controller and independent of the Oban job (`assert_enqueued` under `:manual` mode).
- `deletion_test.exs` — `Deletion.delete_user_data/1` writes a `user.data_deleted` audit row with `user_id: nil`, resource_type "user", resource_id = deleted user id.
- `deletion_test.exs` — `op.event_log` **full-row content** (all 9 columns) is byte-identical before/after `delete_user_data/1` — proves the UUID-only immutability contract, and (after the review revision) detects in-place `payload`/`metadata` UPDATEs, not just insert/delete.

## Gates
- 2A-iv Reception: DoD table built independently — all 3 ✅.
- 2B-i Regression: 69 tests, 0 failures (GDPR + audit + workers domain).
- 2B-ii Spec Coverage: §4 deletion audit / pre-deletion audit / event-log-preserved — covered.
- 2B-iia Fresh-DB: skipped (test-only, no migrations).
- 2B-iii Deploy+E2E: skipped (test-only, no deployed code).
- 2C Review: elixir-reviewer → NEEDS_REVISION (PK-only event_log snapshot too weak) → fixed (full-row snapshot) → **APPROVED**.

## DoD Evidence
| DoD item (§4/§5) | Impl file:line | Test | Status |
|---|---|---|---|
| `user.data_deleted` audit (user_id nil) | `deletion.ex:97` | `deletion_test.exs` (A2) | ✅ |
| `user.deletion_requested` audit | `gdpr_controller.ex:32` | `gdpr_controller_test.exs` (A1) | ✅ |
| event_log preserved (not modified) | `deletion.ex` (no event_log write) | `deletion_test.exs` (A3, full-row) | ✅ |

## Follow-up flagged to human (non-blocking, not this phase's test scope)
Production moduledoc contradiction: `events.ex:6-8` ("append-only — except GDPR erasure, which **zeroes out payloads** for deleted-user events") vs `deletion.ex:8-11` ("event_log is **NOT modified** … nothing to scrub"). Code + tests take the no-modification side (v1 payloads are UUID-only). `events.ex` appears stale/aspirational. Decision pending: fix `events.ex` moduledoc, or spin a hardening issue.
