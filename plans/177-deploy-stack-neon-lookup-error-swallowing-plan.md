# Plan: deploy-stack.sh masks transient Neon API failures as "parent branch not found"
**Issue**: #177
**Created**: 2026-07-09
**Status**: Approved

## Context
`scripts/deploy-stack.sh` resolves the Neon parent-branch id with an inline
`curl … | python3 … 2>/dev/null || true` pipeline. Any failure of that call (network blip, Neon
API 5xx/429, bad key, malformed body) collapses to an empty id, which the next check reports as
`FAIL deploy: Neon parent branch '<name>' not found`. This conflates "API call failed" with
"branch genuinely absent" — the swallowed error cost a full preview-deploy gate retry on #175.
This issue makes the lookup distinguish the two, with bounded retry on transient failures.

## Research Summary
- Bug site: `scripts/deploy-stack.sh:249–262` (parent-branch lookup) — inline curl→python,
  `2>/dev/null || true`, then `[[ -z "$NEON_PARENT_BRANCH_ID" ]]` → "not found".
- **The identical anti-pattern is at a sibling site** (line ~281, the stale-branch lookup) — same
  swallowing. The DELETE (~292) is fire-and-forget; the POST create (~299) already checks its
  response body and fails clearly.
- Existing `deploy_with_retry()` (lines 63–77) wraps deploy *commands*, not curl API calls — not
  directly reusable for a lookup that must return a value.
- Platform tests use an extract-a-shell-function + eval + stubbed-curl pattern
  (`test/platform/deploy_stack_retry_test.sh` is the model), aggregated by `run_all.sh`.

## Approach Options
- **Option A (chosen): shared `neon_branch_id_by_name()` helper, used for BOTH lookups.** DRY;
  kills the whole swallowing class in one place; both lookups gain HTTP-status awareness + bounded
  retry. Recommended and approved.
- **Option B: fix the parent lookup only.** Matches the issue's literal DoD but leaves the sibling
  stale-lookup swallowing for a later issue. Rejected — same defect, cheap to fix together.
- **Option C: wrap the existing inline pipelines in `deploy_with_retry`.** Rejected — that helper
  retries commands for side effects, not a value-returning lookup, and can't distinguish
  API-failure from absence.

**Human decisions (2026-07-09):** Option A (both lookups via shared helper); run the full 2B-iii
confirmatory deploy (high blast radius — a bug here breaks every future preview deploy).

## Phases

### Phase 1: Distinguish Neon API failure from genuine branch absence
**Objective**: A `neon_branch_id_by_name()` helper resolves a Neon branch id with HTTP-status
capture and bounded retry, returning a distinct failure for API errors vs. genuine absence; used
for both the parent- and stale-branch lookups; covered by a platform test.
**Agent(s)**: platform-agent
**Steps**:
1. Add top-level `neon_branch_id_by_name()` to `scripts/deploy-stack.sh`:
   - `curl` with HTTP-status capture (`-w '%{http_code}'` / `--fail-with-body`), no `2>/dev/null`.
   - Bounded retry with backoff on transient failure (curl network error, HTTP 5xx/429).
   - On success (2xx + parseable `branches`): print the matching branch id, or empty string if the
     name is genuinely absent from a non-empty list; return 0.
   - On persistent API failure: print a distinct `FAIL deploy: Neon API call failed (HTTP <code>)…`
     to stderr and return non-zero (caller aborts — do NOT report "not found").
2. Replace the inline parent-branch lookup (line ~265) with the helper; the existing
   `parent branch not found` message fires only when the helper succeeded AND returned empty.
3. Replace the inline stale-branch lookup (line ~281) with the same helper.
4. Write `test/platform/deploy_stack_neon_lookup_test.sh` (extract-and-eval, stubbed `curl`):
   (a) transient API error (5xx/429/network) → retries then distinct non-"not found" failure,
   non-zero; (b) 200 + branch absent → empty id, exit 0 (caller's "not found" path); (c) 200 +
   branch present → resolves the id. Register in `test/platform/run_all.sh`.
5. Regenerate the issue's embedded test audit to GREEN (final step).
**Test Command**: `bash test/platform/deploy_stack_neon_lookup_test.sh && bash test/platform/run_all.sh`
**DoD Items**:
- [ ] deploy-stack.sh distinguishes "Neon API call failed" from "branch genuinely not found"
- [ ] Transient API failures are surfaced (not swallowed) and retried with a bounded backoff
- [ ] "parent branch not found" only when the API succeeded and the branch is truly absent
- [ ] Platform test covers the three cases (API error / branch absent / branch present)
- [ ] `just verify` passes

## Gate Plan
- 2B-i Regression: platform suite (`run_all.sh`) + `just verify`. Required.
- 2B-ii Spec Coverage: orchestrator-built. Required.
- 2B-iia Fresh DB: **skip** — no migration/schema/dbt/`persisted.exs` changes.
- 2B-iii Deploy-Preview + E2E: **run** (human elected) — confirms the refactored branch-creation
  happy-path still deploys; naturally exercises the real Neon lookup.
- 2F Principal Engineer: required (final phase).

## Open Questions
None.

## Integration Handoffs
None — single phase, single domain (platform). Lands on `feat/124-e2e-auth` via merge.
