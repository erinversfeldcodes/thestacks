# Issue #218: Complete expand-contract for `users.handle` NOT NULL (contract step)

## Summary
`20260714200500_backfill_and_constrain_user_handles.exs` tightens `op.users.handle`
to `NOT NULL` in the SAME release that introduced the column (#211), carrying a
`@breaking_ok` risk-acceptance. This issue is the tracked **contract** step of
expand-contract: once the handle-writing release is fully rolled out (no N-1
instance can insert a handle-less row), verify the constraint is safe and remove
the `@breaking_ok` acceptance / document that the rollout completed.

## Why (deferred, not skipped)
Per `docs/agents/standards/migrations.md` §Expand-Contract, a `NOT NULL` tighten
should ship in a **later** release than the nullable add. The epic tightened in
one release because `handle` is greenfield and the app writes it on every insert
(`Accounts.maybe_put_handle`), so the only residual is a brief rolling-deploy
window where a pre-handle N-1 instance could insert a null. That risk is accepted
for pre-launch; this issue closes it properly if `op.users` reaches multi-instance
rolling production.

## Scope
- Confirm the handle-writing release is fully deployed (no N-1 writer).
- Keep the `NOT NULL` constraint; drop the `@breaking_ok` acceptance comment or
  replace it with a "rollout complete" note.
- If a zero-downtime path is ever needed: add via `NOT VALID CHECK (handle IS NOT NULL)`
  then `VALIDATE CONSTRAINT` (SHARE UPDATE EXCLUSIVE, non-blocking) instead of the
  ACCESS EXCLUSIVE `SET NOT NULL` full scan.

## Definition of Done
- [ ] Rollout confirmed; constraint validated safe; annotation updated.

## Status: RESOLVED — accepted, rolling forward (closed 2026-07-15)
**Decision (owner, 2026-07-15):** the risk is acceptable; **roll forward with the
single-release `NOT NULL` tighten and deploy it as part of this branch.** No separate
"contract release" and no deferral — the `@breaking_ok` annotation records the rationale
(only registration writes `op.users`, and no live signups are expected during the deploy
window). Nothing further to implement; this issue is closed as an accepted decision.

For the future record, IF `op.users` ever reaches multi-instance rolling production **with
live registration traffic**, the safe pattern would be: ship the introducing release with
`handle` NULLABLE, then add `NOT NULL` in a follow-up. Not needed for this deploy.

## Source
Principal-engineer + elixir/database/platform reviewers on the #210 epic review.
