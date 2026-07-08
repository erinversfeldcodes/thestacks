# Issue #162: Scheduled cleanup of stale `pre-rollback-*` Neon branches

## Summary
The composite action's Neon LSN restore (introduced in Issue #137)
creates a `pre-rollback-<sha>-<timestamp>` preserved branch every time
it fires. Neon's self-restore API requires `preserve_under_name`, so
the branch is unavoidable on each auto-rollback. These accumulate over
time. Add a scheduled GitHub Actions workflow that runs weekly and
deletes preserved branches older than 30 days from the prod Neon
project.

## User Stories
N/A (platform / operational).

## Goal
Prevent unbounded growth of `pre-rollback-*` branches in the prod Neon
project. 30-day retention is a reasonable safety net for "the rollback
itself was wrong" (operator can promote the preserved branch back to
default) while bounding the operational overhead of an accumulating
list of dead branches.

## Scope Check
- One new workflow file. Zero controllers, zero endpoints, zero new
  application code.
- ~80–120 LOC of YAML + inline shell. Well under the 300 LOC ceiling.
- Single concern: scheduled cleanup of one branch-name pattern. No
  bundled scope.

## Wiring
- [x] Implementation only. Wired by this issue (workflow runs on its
      schedule once merged; no router or UI surface).

## Technical Requirements

### New workflow file: `.github/workflows/cleanup-pre-rollback-branches.yml`

Triggers:
- `schedule:` weekly cron (e.g. `cron: '0 6 * * 0'` — Sundays at 06:00
  UTC).
- `workflow_dispatch:` for ad-hoc invocation, with a boolean `dry_run`
  input (default `true`) so operators can preview what would be deleted
  before running for real.

Steps:
1. Resolve all branches under `NEON_PROJECT_ID` via
   `GET https://console.neon.tech/api/v2/projects/$NEON_PROJECT_ID/branches`.
2. Filter to branches whose `name` matches `pre-rollback-*`.
3. Filter to branches whose `creation_time` is older than 30 days
   (compare against `now() - 30d` in UTC).
4. For each match: log `<branch-id> <branch-name> <creation_time>`. If
   `dry_run == false`, issue
   `DELETE https://console.neon.tech/api/v2/projects/$NEON_PROJECT_ID/branches/<id>`
   and assert HTTP 200/202. If `dry_run == true`, just log "would
   delete".
5. Print a summary line: `pruned N branches (kept M younger than 30d)`.

Secrets used:
- `NEON_API_KEY`
- `NEON_PROJECT_ID`

Both already configured (introduced in Issue #137).

### Failure modes

- Neon API 5xx during list → fail loudly (exit non-zero); the next
  scheduled run picks it up.
- Individual branch delete returns 4xx → log the error, continue with
  the rest, exit non-zero at the end so the failure is visible. The
  branch can be retried next week.
- `creation_time` parsing edge case (timezone, missing field) → skip
  the branch and log; do not delete on incomplete data.

## Reviewer Context

- Neon's branch list endpoint paginates above 100 branches. The
  workflow should follow `cursor`-based pagination if the response
  contains a `pagination.cursor` field. For a single-region prod stack
  with weekly pruning, paging probably isn't needed in practice — but
  handle it defensively.
- The `pre-rollback-*` naming convention is set by
  `scripts/rollback-production.sh` (search for `PRESERVE_NAME`). If
  that pattern changes, this workflow's filter must move with it.
  Cross-link from the script's comment to this workflow.
- 30 days is the chosen retention. The trade-off: longer windows give
  operators more time to detect "the rollback was wrong"; shorter
  windows reduce Neon storage cost. 30d is a reasonable default; it
  can be parameterised later if needed.

## Definition of Done
- [ ] `.github/workflows/cleanup-pre-rollback-branches.yml` lands.
- [ ] `dry_run` workflow_dispatch input defaults to `true` so the first
      manual invocation is observably safe.
- [ ] Scheduled cron triggers weekly.
- [ ] Workflow lints clean under `actionlint`.
- [ ] Manual invocation (with `dry_run=true`) on the prod project
      produces a non-empty list (after at least one auto-rollback has
      fired) — verified once before merge.
- [ ] `just verify` passes (no new code paths to test).

## Dependencies
Issue #137 (introduces the `pre-rollback-*` branch pattern via the
composite action's Neon LSN restore).

## Agent Assignment
platform-agent.

## Progress Notes
2026-04-29: Filed as a follow-up to Issue #137 Phase 6. The composite
action's preserved-branch behaviour is intentional (Neon's API requires
it on self-restore) but accumulates without bound; this issue
addresses the cleanup gap noted in #137 Section 4 ("Reset on rollback")
and the DoD checkbox `pre-rollback-*` preserved branches… document
cleanup as a follow-up issue".
