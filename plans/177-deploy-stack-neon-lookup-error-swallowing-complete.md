# Issue #177 — Complete

**Issue**: #177 — deploy-stack.sh masks transient Neon API failures as "parent branch not found"
**Branch**: `177-deploy-stack-neon-lookup-error-swallowing` (off `feat/124-e2e-auth`)
**Commits**: `6981fda` (fix) + `9097ae9` (argv hardening) — merged into `feat/124-e2e-auth`
**Completed**: 2026-07-09
**Agent**: platform-agent

## What shipped
`neon_branch_id_by_name()` in `scripts/deploy-stack.sh` replaces the two inline
`curl … | python3 … 2>/dev/null || true` Neon-branch lookups (parent + stale) that collapsed every
failure — network blip, 429/5xx, bad key, malformed body — into an empty id, misreported as
"parent branch not found" (which cost a real preview-deploy gate retry on #175).

The helper:
- Captures the HTTP status (`curl -sS -w '\n%{http_code}'`), no `2>/dev/null` swallowing.
- Retries transient failures (curl transport error, HTTP 429/5xx) a bounded 3 attempts with linear
  backoff; a non-transient 4xx (e.g. 401/403 bad key) fails fast with no retry.
- Returns a distinct `FAIL deploy: Neon API call failed (HTTP … / curl rc …)` on API failure vs.
  an empty id + exit 0 on genuine absence (caller then emits the real "parent branch not found").
- Parses the branch name via `python3` `sys.argv[1]` under a single-quoted script (post-review
  hardening) — no source interpolation, so a git ref containing a quote can't break the literal.

Both lookups route through it: the parent lookup aborts on helper failure (`|| exit 1`); the stale
lookup warns-and-continues (a flaky cleanup lookup shouldn't burn the whole deploy — the downstream
create POST fails loudly on a genuine conflict).

## Tests
`test/platform/deploy_stack_neon_lookup_test.sh` (19/0, registered in `run_all.sh`): transient-retry
(429/5xx, exactly 3 calls), non-transient 401 (no retry, distinct error), branch absent (empty+0),
branch present (id+0), transient-then-success (retry recovery), and single-quote branch name
(hardening regression). `deploy_stack_retry_test.sh` still 6/0 (sibling awk-extraction unbroken).

## Gate record
- 2A-iv DoD + testing-coordinator: PASS — TC signed off; flagged the untested non-transient-4xx
  guard (silently deletable → would reintroduce the #177 bug for the expired-key scenario) → added
  a mutant-verified 401 test (revision cycle 1).
- 2B-i Regression: PASS — `just verify` exit 0 (2259 elixir tests; dbt clean — change touches
  neither); platform suite clean (only pre-existing unrelated `check_slo_gate` red).
- 2B-ii Spec Coverage: PASS — all Suggested-Fix + DoD requirements evidenced.
- 2B-iia Fresh DB: SKIPPED (no DB changes).
- 2B-iii Deploy-Preview + E2E: ACCEPTED passed-for-changed-path (human) — the refactored
  branch-creation path ran CLEAN live twice (parent lookup resolved `staging`, preview branch
  created); the deploy then failed both times at an unrelated Fly core release-command machine
  timeout ("never reached state stopped"). #177 changes no app code.
- 2C platform-reviewer: APPROVED.
- 2F Principal Engineer: GREEN — no P0/P1/P2.
- Post-review hardening (revision cycle 2, human-directed): branch-name → `sys.argv` interpolation
  fix, regression-locked.

Revision cycles: 2 (1 = TC-flagged 401 coverage; 2 = human-directed interpolation hardening).

## Deferred / not filed (per human)
- **Fly core release-command machine timeout** ("never reached state stopped") — blocked both
  2B-iii deploys; unrelated to #177. PE recommended filing it (P2, reproducible, will block
  #174/#173 deploys); human chose NOT to file yet. **Watch item for the next deploy-dependent issue.**
- curl `--max-time`/`--connect-timeout` on the lookup (P3); malformed-2xx-body distinction (P3).

## Notes
- Built on `feat/124-e2e-auth` (the epic PR branch), not `main`. #175's warmup guard was merged into
  `feat/124` earlier in the same session so the branch's PR gate has both fixes.
