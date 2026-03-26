# Issue #132: Deployment Coordination Gap for Enum Wire Format Migration

## Priority: P1 High

## Problem

The branch migrates `ClassifyResponse.classification` and `AssociateCallback.status` from free-form strings to formal proto enum values (e.g., `"book"` → `"CLASSIFICATION_RESULT_BOOK"`). Both Python (sender) and Elixir (receiver) are updated atomically in the same branch. However, there is no deployment coordination document or feature-flag mechanism to handle the window between Python deploying and Elixir deploying (or vice versa) in a rolling deploy.

During a rolling deploy:
- If Python vision service is updated first, it sends `"ASSOCIATION_STATUS_CONFIRMED"` but Elixir still expects... (it already expects these strings — **the Elixir side was already on the new strings**). However, any rollback scenario reintroduces the window.
- If an operator rolls back the vision service to a pre-enum version while Elixir stays on the new code, Elixir will receive old strings (`"confirmed"`, `"rejected"`) and silently drop them into the `dispatch_association/2` catch-all clause, treating them as unknown status and returning `200 ok` — no cover associations will be processed, with no alert.

## Impact

Silent data loss during rollback: cover association callbacks would be silently discarded. No telemetry event is emitted when the catch-all `dispatch_association/2` clause fires. An operator rolling back the Python service would not see errors — they would see `200` responses in logs and would not know cover associations are being silently dropped.

## Evidence

- `apps/core/lib/stacks_web/controllers/internal_controller.ex:129` — catch-all `dispatch_association` logs a warning but returns `200 ok` with no telemetry event.
- No CI gate enforces that Python and Elixir enum strings are identical.
- No runbook exists for rolling back the vision service independently of core.
- `scripts/lint-proto.sh` runs `buf breaking` to catch proto changes but does not validate that Elixir pattern-match strings match the proto enum JSON names.

## Suggested Fix

1. Add a telemetry event to the catch-all `dispatch_association/2` clause so alert rules can fire when unknown statuses are received.
2. Create a runbook (`docs/runbooks/vision-service-rollback.md`) documenting the rollback procedure and the risk of enum mismatch.
3. Add a CI check that extracts Elixir pattern-match strings from `internal_controller.ex` and verifies they match the proto enum JSON names — this can be done as an Elixir test that parses the generated proto module.
4. Consider a 2-phase deploy order: Elixir first (backward-compatible because old Python strings fall to the catch-all with a warning), then Python.

## Agent Assignment

elixir-agent + platform-reviewer

## Definition of Done

- [ ] Telemetry event emitted when `dispatch_association/2` catch-all fires
- [ ] Runbook exists at `docs/runbooks/vision-service-rollback.md`
- [ ] CI check or test verifies Elixir pattern-match strings match proto enum JSON names
- [ ] Deploy ordering documented (Elixir before Python for this enum migration)
