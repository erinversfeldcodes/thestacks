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

## Status: ACCEPTED risk — not actionable now (do NOT delegate)
The single-release `NOT NULL` tighten is a **deliberately accepted** decision, not a bug:
the only writer of new `op.users` rows is registration, which is not expected during the
deploy window (pre-launch, low/no live signups), so the rolling-deploy race the reviewers
flagged has no practical trigger. There is nothing to implement on this branch — the
constraint already exists (with `@breaking_ok` recording this rationale).

This issue is the **contract** half of expand-contract (ship the tighten in a *later*
release, after release 1 is fully out) — deploy-sequencing, not code. Revisit **only if**
`op.users` ever runs multi-instance rolling production **with live registration traffic**.
Two options at that point: (a) make the introducing release ship `handle` NULLABLE and add
`NOT NULL` in a follow-up release; (b) a zero-downtime add via `ADD CONSTRAINT … CHECK
(handle IS NOT NULL) NOT VALID` then `VALIDATE CONSTRAINT` (avoids the table lock, though it
does not itself close the N-1-writer window — deferral is the only thing that does).

## Source
Principal-engineer + elixir/database/platform reviewers on the #210 epic review.
