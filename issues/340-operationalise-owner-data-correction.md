# Issue #340: Operationalise owner-facilitated data correction

## Summary
Two separate owner rulings in this campaign asked for the same missing capability:

1. **Un-merge** (2026-07-30, on the four recovery legs): *"this should only be facilitate-able by the platform owner, it's a form of data correction that we should be building processes for."*
2. **ISBN repair** (2026-07-30, on #339): *"we should do this in a way that informs how we handle the repair of bad data in the future, ideally operationalising this kind of repair."*

Today there is no such process. When data goes wrong the options are a bespoke migration, a `psql` session, or nothing — none of which are reviewable, re-runnable, or auditable, and the last of which is what "we'll fix it later" usually means in practice.

#339 builds the **first instance** of the pattern (dry-run, idempotent, audited, explicitly scoped) for the ISBN repair. This issue generalises it into the owner-facing capability both rulings asked for.

## User Stories
None directly — a platform-operations capability. Serves US-1.1.x (book identity corrections) and the un-merge recovery leg.

## Goal
A correction to production data is a **reviewed, dry-runnable, audited operation the platform owner invokes** — not an ad-hoc query. The un-merge leg has somewhere to live, and the next bad-data incident starts from a pattern instead of a blank file.

## Scope Check
⚠️ **Scope this carefully before building.** The temptation is a general-purpose admin data editor, which is both a large surface and a security liability. The bar is: enumerate the corrections actually needed (un-merge, ISBN repair, and any others surfaced by then), and support *those* as named operations. Do not build a generic "edit any row" path.

## Wiring
Router wiring: TBD by the scoping decision — a `mix` task family may be sufficient and is the smaller surface. If it becomes owner-facing UI it must sit behind the existing admin/owner authorisation and the break-glass audit path (see #138).

## Feature-Completeness Pre-Check
n/a until scoped — the pre-check is the enumeration in Technical Requirement 1.

## Technical Requirements
1. **Enumerate the corrections first.** At minimum: un-merge two works that were wrongly merged; repair a malformed/unnormalised ISBN (#339). Survey for others before designing — a list of two is a different design from a list of ten.
2. **Inherit #339's shape** for each: dry-run by default with a printed blast radius, idempotent, audited (who, what, from, to, why), scoped by an explicit predicate.
3. **Owner-only, and provably so.** Whatever the entry point, prove the authorisation with a test that fails when the check is removed — not a check that lives only in a view (the defect class #332 records).
4. **Each correction is reversible or explicitly one-way**, and says which. Un-merge in particular must state what it cannot restore.
5. **Write the runbook** alongside it. A correction capability nobody can find at 2am is not operational.

## Reviewer Context
- ⚠️ **Do not start this before #339 lands** — #339 builds the concrete first instance, and generalising from one real case beats designing from imagination.
- Related prior art in-repo: the break-glass production data access work (#138) already reasons about owner-only privileged paths and audit trails — read it before designing a second mechanism.
- The `audit` schema is the intended home for the trail; do not invent a parallel log.
- `gdpr-review` required if any correction touches personal data (un-merge touches placements, which are personal).
- Commit: agent commits are DENIED. Stage, one-line message to scratchpad, never push.

## Test Audit
| Layer | Applies? | Verdict |
|-------|----------|---------|
| Security | yes | ❌ owner-only enforced in the update path, probed by removing the check |
| DB interactions | yes | ❌ each correction: dry-run changes nothing; apply is idempotent; audit row written |
| GDPR | yes | ❌ `gdpr-review` on any correction touching personal data |
| Others | no | n/a until scoped |

## Definition of Done
- [ ] Corrections enumerated and scope decision recorded — evidence: the list + what was excluded
- [ ] Each correction dry-runnable, idempotent, audited — evidence: test names + a dry-run transcript
- [ ] Owner-only proven by probe — evidence: probe output with the check removed
- [ ] Runbook written — evidence: file path
- [ ] `staff-review` verdict recorded below

## Dependencies
**Depends on #339** (builds the first instance of the pattern; generalising before that is speculative). Related to **#138** (break-glass production data access — read before designing). Carries the un-merge recovery leg from the campaign's owner rulings.

## Agent Assignment
elixir-agent, with a scoping pass first.

## Progress Notes
Filed 2026-07-30 by the lead, consolidating two owner rulings that asked for the same capability. Not scheduled — sequence after #339 and after the owner decides which wave it belongs to.

**Wave assignment (owner-approved 2026-07-31): Wave 7.**
Scheduled as item **7d**, deliberately alongside **7c** (owner-only un-merge process): your two rulings — un-merge as "a form of data correction that we should be building processes for" and the ISBN repair "operationalised … for the future" — describe **one** capability. 7c's un-merge is #340's first consumer; do not build two mechanisms.
