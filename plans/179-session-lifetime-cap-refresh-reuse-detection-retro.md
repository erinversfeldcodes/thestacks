# Retrospective — Issue #179 (session cap + refresh-token reuse-detection)

**Date**: 2026-07-11 · **Agents**: security-agent (P1/P2b/GDPR) + database-agent (P2a) · **Cycles**: 1 nit + GDPR/runbook fold-in · **Outcome**: gates green (live reuse-detection PASS), ready to merge

## What worked well
- **Grounding the hard design question BEFORE coding saved the issue from a broken mechanism.** Recon
  surfaced that guardian_db deletes the old row on rotation, so the naive "detect reuse at refresh"
  design is impossible (the replayed token 401s at the pipeline first). The plan pivoted the gate to
  `verify_claims` and — critically — had the implementing agent VERIFY the `verify_claims`-before-
  `on_verify` ordering against `deps/guardian` before building on it. That ordering (Case A) is the
  load-bearing assumption; confirming it with source evidence up front avoided shipping something
  subtly non-functional.
- **Phasing a security-critical change (cap → family plumbing → detection gate) kept each step
  reviewable and RED-testable.** Each phase had behaviour to test in isolation; the family table landed
  with its writers, the gate landed with the table already exercised.
- **Fail-closed by construction.** Login fails closed (revoke + 500 if the family can't persist, so the
  reuse invariant "every live token has a family" holds); the gate fails closed to 401 on any DB error
  (never fail-open, never 500). The security reviewer specifically probed for a fail-open path and
  found none.
- **The live HTTP reuse check was a better 2B-iii than the planned DB-read.** When the preview Neon URL
  turned out to live in the staging project (an infra chase), pivoting to a pure-HTTP
  login→refresh→replay sequence proved the *actual security behaviour* end-to-end on real infra
  (rotation works, current token not falsely revoked, replayed token 401s, family burned) — more
  meaningful than asserting a claim persisted in a jsonb column.
- **SKIP_VISION paid off immediately.** The deploy logged `SKIP warmup: SKIP_VISION set` — the auth/DB
  gate cost zero Modal credit, exactly the intent.

## What caused friction
- **Two subagents died on `FailedToOpenSocket` (API/network) mid-run** — once for the nit-fix, once for
  the GDPR step. Both had actually completed their file edits before the error surfaced, so the fix was
  to VERIFY the on-disk state (compile + run the tests) rather than re-run blind. Lesson: on a subagent
  transport error, inspect the working tree before assuming nothing happened — the edits may be done.
- **`to_string/1` in a guard** — my first cut of the ownership check used `when to_string(user_id) !=
  sub`, which doesn't compile (not guard-safe). Moved the comparison into a `cond` body. A reminder
  that guard clauses only admit guard-safe functions.
- **The preview Neon URL is in a separate (staging) project**, not `NEON_PROJECT_ID` — cost a couple of
  API round-trips to discover. Worth documenting the preview-DB resolution path for future
  `:deployed_only` runs.

## What should change in the agent system
| File to change | Recommended change | Evidence |
|---|---|---|
| `docs/agents/orchestrator-agent.md` (subagent handling) | On a subagent transport error (`FailedToOpenSocket` etc.), VERIFY the on-disk diff + re-run the relevant tests before re-delegating — the edits are often complete; blindly re-running risks double-edits. | Two agents died post-edit this issue; both were actually done. |
| `.claude/skills/write-validation-test/SKILL.md` (deployed tests) | For a live auth check, prefer a pure-HTTP behavioural sequence (login→refresh→replay) over a direct preview-DB read when possible — it needs only BASE_URL (no preview Neon URL, which lives in the staging Neon project) and proves the real behaviour. Document the preview-DB resolution (`NEON_STAGING_PROJECT_ID`) for when a DB read is unavoidable. | The Neon-URL chase vs the clean HTTP proof. |
| `docs/agents/security-agent.md` | When a feature's correctness depends on a dependency's internal call ORDER (e.g. Guardian `verify_claims` vs `on_verify`), require citing the dep source file:line as evidence in the report before building on it. | The Case-A ordering was load-bearing and correctly evidenced. |

## Follow-ups
- **#180** (next): multi-tab / in-flight rotation grace window — softens #179's accepted spurious-logout
  false-positive. #179 was intentionally sequenced first so #180's grace window layers on top.
- Legacy no-`family_id` tokens bypass the reuse gate until they expire/refresh (transitional, self-
  closing) — documented, no action.

## Batch position
Follow-up #4 of #178–182 complete (order 181 → 178 → 182 → 179 → 180, per-issue gates). Next & last:
**#180**.
