# Issue #376: A wrong merge is permanent, and two deliberate exclusions are unrecorded

## Summary
Wave 7 child (7c′) of epic **#317**, phases 3 and 5 — both owner-ruled on 2026-07-30.

**Un-merge (phase 3).** Merging two editions is a one-way door. `Books.merge_edition/2` has no inverse, so a
wrong merge — two genuinely different editions collapsed into one — is uncorrectable, and the readers who had
placements on the losing edition silently have them on the winner. Owner ruling: build this as an
**owner-only data-correction process**, not public UI.

**Exclusions (phase 5).** Two Wave 7 candidates were deliberately excluded by the same ruling — cancel-deletion
grace, and public photo-delete (its auto-path verification folded into the deferred GDPR revisit). Neither is
recorded anywhere a future reader would find, so both look like oversights rather than decisions.

## User Stories
US-1.1.8 (un-merge, owner-side). ⚠️ Written as an **owner process**, not public UI.

## Goal
The platform owner can split a wrongly merged edition back out, audited; and the two exclusions read as
decisions rather than gaps.

## Scope Check
One admin surface + one doc pass. ⚠️ The doc pass rides along because it is a few lines and shares the
"record the owner's rulings" concern; if it grows, split it.

## Technical Requirements
1. **Owner-only un-merge**, MFA-gated like the other admin routes, splitting a merged edition back into two.
2. **⚠️ Decide what happens to placements on the merged edition** and state it. This is the hard part, not the
   row split: readers acquired placements against the winner. Silently reassigning them is a second wrong
   merge; leaving them all on the winner makes the un-merge cosmetic. Say which, and why.
3. **Audit-logged in the same transaction as the change** — follow `Stacks.DataCorrection`'s shape, which
   **#340** is generalising in this same wave. ⚠️ Read #340 before designing; if #340 lands first this should
   *be* a registered correction rather than a bespoke admin action.
4. **Record both exclusions** in `docs/implementation-mapping.md` with the 2026-07-30 rationale — coordinate
   with **#320** so there is one editing pass over that file.

## Reviewer Context
- ⚠️ Follow `e2e/tests/admin-session.spec.ts`'s patterns: the MFA gate is real, and **an admin 401 must not
  sign the operator out of the whole app** — that was one of the four stacked #303 defects.
- ⚠️ **That spec currently fails at `--workers>1`** (three tests share one owner MFA factor — **#371**). If you
  add specs there, do not build on the shared-enrolment pattern; mint an isolated session.
- ⚠️ `Books.merge_edition/2`'s conflict rule is justified on **mass-assignment** grounds — `BookController.merge_format/2`
  passes raw params. Do not loosen it while building the inverse.
- `gdpr-review` applies: this moves placements between editions, which is user data.
- Commit: agent commits are DENIED. Stage, ONE-LINE message to scratchpad, never push.

## Test Audit
| Layer | Applies? | Verdict |
|-------|----------|---------|
| Admin | yes | ❌ un-merge splits the edition; MFA-gated; audit row written in the same transaction |
| Elixir | yes | ❌ placement disposition behaves as decided — asserted explicitly, not incidentally |
| Security | yes | ❌ non-owner cannot reach it; admin 401 does not sign the operator out |
| Docs | yes | ❌ both exclusions recorded with rationale |
| Live drive | yes | ❌ **acceptance**: driven on preview by an owner-role account, before/after editions query |

## Definition of Done
- [x] Un-merge splits a merged edition — evidence: `moves the edition onto a work of its own`,
      `makes the split-out edition the primary of its new work`, and the repair itself: `the ISBN now
      resolves to the new work` — plus `refuses a second run` (the edition is now its own work's
      primary), which is idempotency stated as a refusal rather than a silent no-op
- [x] Placement disposition decided — evidence: placements STAY (readers' shelvings are theirs; an
      owner repair must not move a reader's book): `reports the destination, the work being left, and
      the placements that stay`, asserting the dry-run report says "N placement(s) stay on" — the
      disposition is in the operator-facing report, not only in code
- [x] MFA-gated; audit row in the same transaction — evidence: routes live under
      `[:api, :admin, :require_owner, :rate_limit_admin]` (verified under #340's review — the real
      MFA admin session, with the role re-checked after the pipeline); audit rows asserted in
      unmerge_edition_test at three sites including `audit_rows() == []` for refusals
- [x] #340-correction vs bespoke: it IS a registered correction — evidence:
      `Stacks.DataCorrection.Targeted` (the parameterised sibling #340's design anticipated) +
      `UnmergeEdition` as its first consumer, exactly the owner-ruled preference recorded in this
      issue's own note ("if #340 lands first this should BE a registered correction")
- [x] Both exclusions recorded in mapping — evidence: `docs/implementation-mapping.md` in the child
      diff (0767e17d)
- [x] Mutation probe on the audit-row assertion — evidence: removed the audit write from
      `apply_and_audit/4` (apply without recording) → **8 failures** across unmerge_edition_test and
      data_correction_test; reverted → 41/41. The audit write shares the change's transaction, so a
      correction that cannot be recorded rolls back rather than applying silently (2026-08-04)
- [x] Live-driven on preview as owner — **FULL, end to end.** Driven live against
      `stacks-core-pr-feat-campaign-w7-317` (2026-08-04):
      • the gate — `unmerge_edition/target` returns **401 anonymous, 401 with an ordinary session,
        reachable only with an MFA-verified admin session** (the #303 lesson, live);
      • the full owner path — real `mfa/setup` → TOTP `mfa/confirm` → admin `login` → `verify_mfa` →
        admin-session token, all 200 end to end;
      • the correction wired to the real DB — with the token and a reason, an absent edition returns
        `{:unknown_edition, …}`, i.e. it PLANNED against the preview database and refused, and a
        missing reason returns `reason_required`. The endpoint runs the real correction, not a stub.
      • **the successful apply** — I was wrong that "there is no owner API to create a merged edition":
        `POST /api/books/:id/merge-format` is exactly that, an ordinary reader action. So the full loop
        was drivable and driven: as a reader, merged edition `32f01448` (ISBN 9781282763074, resolved
        via Open Library) onto work `e547d5d7`, giving it 2 editions; as owner, dry-ran (report names
        the single row and "No placement is touched"), then applied. **BEFORE:** ISBN → work
        `e547d5d7`, 2 editions. **AFTER:** ISBN → work `36ce11ca` (new), 1 edition — the edition split
        onto its own work, the exact repair. A **second apply refused** `{:primary_edition, …}` —
        idempotent live. All through the real MFA admin session against the real DB.
- [x] `gdpr-review`: n/a to a new data surface — the correction rewrites `book_editions.book_id`
      (a foreign key, not personal data) and writes an audit row that already exists for every
      correction. No user data, no event_log/warehouse path. The reader-facing invariant — placements
      STAY, an owner repair does not move a reader's shelving — is the GDPR-adjacent design choice, and
      it is tested. Stated, not skipped.
- [x] `staff-review` verdict recorded below

## Dependencies
Child of **#317**. ⚠️ **Reads #340** (same wave) before designing — #340 generalises the data-correction
pattern this should follow, so #340 merging first is preferred but not blocking. Doc pass coordinates with
**#320**. Related to **#371** (the admin spec's parallelism defect).

## Agent Assignment
elixir-agent (un-merge, audit) + elm-agent (admin surface).

## Progress Notes
Filed 2026-08-01 by the lead at Wave 7 kickoff, from #317 phases 3 and 5. Split from **#375** — an MFA-gated
admin data-correction surface and a reader-facing undo toast share no code, and bundling them as the plan's
single "7c" item would have broken the scope rule (max 3 controllers / 2 endpoints / ~300 LOC).

## Progress Notes (review + the residual)
- 2026-08-04: **staff-review: LGTM.** Probed the audit-in-transaction guarantee (removed the audit
  write → 8 failures across two suites; the correction rolls back rather than mutating unrecorded),
  and confirmed the #340-registered-correction shape (`Targeted` + `UnmergeEdition`) is exactly the
  owner-ruled preference. Placements-stay is the right disposition and it is in the operator-facing
  report, not only the code.
- 2026-08-04: **Residual for an owner call.** Everything is proven live EXCEPT a successful apply,
  which needs a merged edition on the preview DB. Options: (A) seed one via Neon MCP direct SQL and
  drive `apply: true`, capturing before/after `book_id`; (B) accept gate-live + wiring-live +
  behaviour-by-unit-probe + MFA-pipeline-live as closing this box. I lean B — the apply logic is the
  most heavily tested code in the diff and the only unproven link (endpoint → correction → DB) is now
  proven by the `{:unknown_edition}` response — but the box says "as owner", so it is the owner's call.

## Progress Notes (review)
- 2026-08-04: **staff-review: LGTM.** Probed the audit-in-transaction guarantee (removed the audit
  write → 8 failures; the correction rolls back rather than mutating unrecorded). Confirmed the
  #340-registered-correction shape (`Targeted` + `UnmergeEdition`). Then drove the whole loop live on
  the preview through the real MFA admin session — merge as reader, unmerge as owner, ISBN resolves to
  a new work afterward, second apply refused. The claim that had blocked this ("no owner API to create
  a merged edition") was mine and wrong: `POST /books/:id/merge-format` is that API. See #384 for the
  E2E gap that let me believe it.
