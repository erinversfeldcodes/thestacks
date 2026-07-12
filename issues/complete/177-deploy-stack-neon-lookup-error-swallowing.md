# Issue #177: deploy-stack.sh masks transient Neon API failures as "parent branch not found"

## Priority: P2

## Problem
`scripts/deploy-stack.sh` resolves the Neon parent branch id with a `curl … | python3 … 2>/dev/null || true` pipeline (around lines 249–259). Any failure of that call — network blip, Neon API 5xx/429, a bad/expired `NEON_STAGING_API_KEY`, or a malformed response — collapses to an empty `branches` list and therefore an empty `NEON_PARENT_BRANCH_ID`, which the next check reports as:

```
FAIL deploy: Neon parent branch '<name>' not found in project <id>
```

This conflates "the Neon API call failed" with "the branch genuinely does not exist" — two very different conditions with different fixes. The `2>/dev/null || true` swallows the real error entirely, so there is nothing in the log to distinguish them.

## Impact
- Misleading failure message sends whoever is debugging down the wrong path (checking/recreating a branch that already exists).
- Transient API errors become hard deploy failures with no retry and no diagnostic.
- Concretely cost a wasted preview-deploy gate cycle on Issue #175: the `staging` branch existed and the API was healthy on immediate recheck (3/3), but one transient call aborted the whole deploy as "branch not found."

## Evidence
- `scripts/deploy-stack.sh:249-262` — the curl→python pipeline and the `[[ -z "$NEON_PARENT_BRANCH_ID" ]]` not-found check.
- Issue #175 gate log: first 2B-iii attempt died at `FAIL deploy: Neon parent branch 'staging' not found in project royal-boat-46711655`; direct Neon API query immediately afterwards returned `staging` (id `br-icy-boat-anxeoufm`, default=true) on 3/3 attempts. Retry of the identical gate then deployed and passed.

## Suggested Fix
Distinguish API failure from genuine absence before concluding "not found":
- Capture the curl HTTP status (`-w '%{http_code}'` / `--fail-with-body`) and the raw body; on non-2xx or a body lacking a `branches` array, emit a distinct `FAIL deploy: Neon API call failed (HTTP <code>) …` and (optionally) retry a bounded number of times with backoff.
- Only emit "parent branch '<name>' not found" when the API call succeeded AND the branch is genuinely absent from a non-empty branch list.
- Do not `2>/dev/null` away the error output from the lookup.
- Add a `test/platform/` case (extract-and-eval, stubbed curl) asserting: (a) API error → distinct non-"not found" message + non-zero exit (or retry); (b) successful lookup with the branch absent → the existing not-found message; (c) successful lookup with the branch present → resolves the id.

## Agent Assignment
platform-agent (platform-reviewer).

## Definition of Done
- [x] deploy-stack.sh distinguishes "Neon API call failed" from "branch genuinely not found" with distinct messages
- [x] Transient API failures are surfaced (not swallowed) and, ideally, retried with a bounded backoff
- [x] "parent branch not found" is only reported when the API succeeded and the branch is truly absent
- [x] Platform test covers the three cases (API error / branch absent / branch present)
- [x] `just verify` passes

## Dependencies
- None. Surfaced during Issue #175 (preview-E2E warmup guard); independent of it.

## Progress Notes
- 2026-07-09: Filed from Issue #175 close-out (orchestrator + principal-engineer both flagged). Out of #175's locked scope (warmup guard), tracked here.
- 2026-07-09: Gates — platform-reviewer APPROVED; Principal Engineer GREEN (no P0/P1/P2). Post-review hardening (human-directed, on-branch): `branch_name` is now passed to the lookup's `python3 -c` via `sys.argv[1]` under a single-quoted script instead of being string-interpolated (eliminates the SyntaxError/injection surface a single-quote in a git ref would hit); regression-locked by `branch_name_with_quote` (suite 19/0). Deferred follow-ups (not filed per human): Fly release-command machine timeout; curl `--max-time` on the lookup. 2B-iii deploy gate: accepted passed-for-changed-path (Neon lookup ran clean live twice; deploy blocked by an unrelated Fly release-command timeout).
- 2026-07-09: Implemented via orchestrator (platform-agent). Added `neon_branch_id_by_name()` (HTTP-status-aware, bounded retry: 3 attempts, transient=429/5xx/network only) and routed BOTH the parent- and stale-branch lookups through it; stale-lookup API failure → WARNING+continue (not abort). TDD (RED→GREEN); testing-coordinator sign-off + added a non-transient-4xx (401) test case (mutant-verified). Gates: `just verify` exit 0 (2259 elixir tests); platform suite 17/0; 2B-iii deploy-preview confirmed the refactored branch-creation happy-path live (parent lookup resolved `staging`, preview branch created). Built on branch `177-…` off `feat/124-e2e-auth`.
