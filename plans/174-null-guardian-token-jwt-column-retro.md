# Retrospective — Issue #174 (null the guardian_tokens.jwt column)

**Date**: 2026-07-10 · **Agent**: database-agent · **Revision cycles**: 0 · **Outcome**: merged into `feat/124-e2e-auth`

## What worked well
- **A clean first pass** — no revision cycles. The likely reasons: (1) research nailed the approach
  *before* coding — reading guardian_db 3.0's `Token.create`/`find_by_claims`/`purge` confirmed `jwt`
  is write-only and that a nil/NULL passes `@required_fields`, so the trigger approach was chosen with
  evidence, not guessed; (2) the plan surfaced the on_refresh gap up front, which is exactly why the
  DB-trigger (path-independent) beat the app-side null.
- **The right guarantee for a security invariant.** A `BEFORE INSERT OR UPDATE` trigger enforces the
  property at the data layer, so it can't be bypassed by any code path — the PE verified this covers
  the dormant #173 refresh with no extra work. Data-layer enforcement > remembering to null in code.
- **Mutation testing adapted to the obstacle.** The `mix test` alias auto-migrates, defeating a
  rollback-based mutant — the TC pivoted to a direct-SQL mutant (drop trigger → raw token persists)
  to prove the trigger is load-bearing. Good instinct not to accept a green rollback at face value.
- **The live-stack `:deployed_only` test paid off immediately** — it confirmed `jwt IS NULL` on real
  Neon after a live login, using the direct-Postgrex + cold-start-retry pattern the #176 exercise
  folded into the `write-validation-test` skill. The skill enhancement was used the very next issue.

## What caused friction
- **Minor:** the rollback-mutant false-negative (test alias re-migrates) briefly looked like the tests
  weren't load-bearing until the cause was identified. The `write-validation-test` skill could note
  this alias behaviour so future mutants go straight to direct-SQL.
- **Environmental (not this change):** none — the Fly deploy cooperated this time (contrast #177/#176).

## What should change in the agent system
| File to change | Recommended change | Evidence |
|---|---|---|
| `.claude/skills/write-validation-test/SKILL.md` (or `test-audit`) | Note that `mix test` re-migrates via its alias, so **rollback-based mutants don't work** — for DB-object (trigger/constraint) fixes, prove load-bearingness with a **direct-SQL mutant** (drop the object → observe the raw behaviour → restore). | The rollback mutant stayed green until diagnosed. |
| `docs/agents/standards/migrations.md` (optional) | Add a short "data-layer enforcement of security invariants" note: prefer a trigger/constraint over app-side nulling when the guarantee must hold across all code paths. | #174's trigger-vs-app-null decision. |

## Candidate follow-ups (not filed, P3)
- A scrub-specific migration test (near-tautological; low value).
- Nulling the decoded `claims` column too, for strict minimalism (not a replay vector).
