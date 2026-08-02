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
- [ ] Un-merge splits a merged edition — evidence: before/after query
- [ ] Placement disposition decided, implemented, and stated — evidence: the reasoning + the test
- [ ] MFA-gated; audit row in the same transaction — evidence: tests
- [ ] Whether this is a #340 correction or a bespoke action, decided with reasons — evidence: the decision
- [ ] Both exclusions recorded in mapping — evidence: diff
- [ ] Mutation probe on the audit-row assertion — evidence: transcript
- [ ] Live-driven on preview as owner — evidence: screenshots + query
- [ ] `gdpr-review` verdict cited
- [ ] `staff-review` verdict recorded below

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
