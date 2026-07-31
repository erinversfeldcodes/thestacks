# Retrospective — Issue #176 (rate limiter → trusted Fly client IP)

**Date**: 2026-07-10 · **Agent**: security-agent · **Revision cycles**: 2 (+ human-directed scope
expansion + a live-stack validation pass) · **Outcome**: merged into `feat/124-e2e-auth`

## What worked well
- **Gates kept catching real gaps, escalating in value.** The testing-coordinator flagged
  `:password_change` keying (MISSING) and the auth_controller migration (WEAK, green-before-and-after)
  — both real, both closed with RED-against-old-impl tests. Then all three reviewers independently
  flagged the same `AuthController.get_ip/1` audit-log weakness, which became an in-issue fix.
- **Mutation testing was the bar throughout.** Every "is this non-vacuous?" was answered by reverting
  the impl and confirming RED — for the rate limiter, the audit-IP fix, and both live-stack tests.
- **The `test-audit` re-baseline earned its keep.** Applying it under the new live-stack bar exposed
  that the local tests *set `fly-client-ip` by hand* — impossible on real Fly — so they proved the app
  *reads* the header, not that production *supplies* it. That gap would otherwise have shipped silently.
- **The live-stack tests validated the production topology the unit tests structurally cannot**, and
  did it via realistic user/attacker behaviour (login flood, register with spoofed XFF) — no artificial
  pokes. Both passed green against a real Fly-fronted preview.
- **Dogfooding the new skills worked.** `test-audit` → `write-validation-test` → `create-issue`'s
  philosophy drove the enhancement, and the exercise fed four concrete lessons back into the skill.

## What caused friction
- **Deployed Elixir tests are a minefield the harness doesn't advertise.** TEST B took four rounds:
  (1) SQL Sandbox `:manual` mode needs an explicit checkout; (2) `Core.Repo` is pinned to `localhost`
  in `test.exs` with no deployed override, so `DATABASE_URL` silently doesn't repoint it → the test
  queried localhost and reported "not found" while the row sat in the preview DB; (3) cold-start 502 on
  the first request; (4) `$1::uuid` param encoding. Each was a distinct dead end. None were documented.
- **The live rate-limit test can't be isolated by faking IPs — because the fix works.** On real Fly you
  can't spoof a distinct `Fly-Client-IP`, so the test must saturate the *real* shared `:auth` bucket and
  run last/alone. This is inherent, but non-obvious until you hit it.
- **A bash quote-nesting bug in the ad-hoc verify runner** cost a wasted deploy cycle (`read <<<"$(… "…" …)"`).
- **The confirmatory deploy gates remain Fly-flaky** (the release-command timeout earlier in #177),
  though this run's deploy succeeded.

## What should change in the agent system
| File to change | Recommended change | Evidence |
|---|---|---|
| `.claude/skills/write-validation-test/SKILL.md` | **(done)** Added a "Deployed Elixir tests" section: direct Postgrex not `Core.Repo`; cold-start `Req` retry; `user_id::text` params; saturating-test isolation. | TEST B's four dead ends. |
| `apps/core/config/` (candidate follow-up) | Consider a `TEST_TARGET=deployed` Repo override in `runtime.exs`/`test.exs` so `:deployed_only` tests can use `Core.Repo` against `DATABASE_URL` instead of hand-rolled Postgrex — or document the direct-Postgrex pattern as the sanctioned one. | `Core.Repo` pinned to localhost silently defeats deployed reads. |
| `docs/agents/orchestrator-agent.md` (or a runner helper) | A reusable "run deployed test against preview" helper that fetches the Neon branch connection URI (validated pattern: `/branches` → `/databases` → `/connection_uri`) instead of ad-hoc bash. | Quote-nesting bug + repeated DB-URL plumbing. |
| `docs/agents/standards/testing.md` | Note that per-IP rate-limit/lockout behaviour on a shared preview can only be validated by saturating the real bucket (can't fake IPs once trusted-IP keying lands) → run such tests isolated/last. | The `ratelimit` project's forced isolation. |

## Candidate follow-ups (not filed)
- Deployed-test Repo ergonomics (above) — small platform/testing issue.
- The Fly release-command machine timeout (from #177) — still unfiled; watch on the next deploy.
