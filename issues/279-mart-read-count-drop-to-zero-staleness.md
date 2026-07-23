# Issue #279: mart_community_read_count never drops to zero under incremental refresh

## Summary
`mart_community_read_count` is an incremental dbt table (delete+insert keyed on `updated_at`)
whose body filters `where removed_at is null`. When a book's **last** active placement is removed,
the recompute yields **no row** for that `book_id`, so delete+insert leaves the previous non-zero
row in place — the community read count never drops to zero without a `--full-refresh`. Found
during Issue #116 Phase 6 (which wired `placement.removed` → `DbtRefreshHandler`; that change
corrects the common case — book retains other active placements — and left this last-placement
case as the documented residual, `apps/core/lib/stacks/workers/dbt_refresh_handler.ex`
@model_mapping comment).

Related coupling (database-reviewer P3, #116 Phase 6): the singular test
`dbt/tests/singular/test_mart_community_read_count_excludes_removed.sql` uses
`m.read_count > expected`, which a drop-to-zero stale row also trips — so against a
production incrementally-maintained mart this test will (correctly) fail until this issue is
fixed. Fixing this issue also stabilises that test in prod contexts.

## User Stories
US-1.6.4 (Remove a Book) / community read-count surfaces (US-2.x book detail) — data-accuracy
follow-up. No new user-facing behaviour.

## Goal
Removing a book's last active placement is reflected in `mart_community_read_count` (row deleted
or zeroed) on the next triggered/scheduled incremental run — no `--full-refresh` required — and
the exclusion singular test passes against an incrementally-maintained mart.

## Scope Check
- Controllers: 0. Endpoints: 0. LOC: dbt model strategy change (+ possibly a small handler tweak)
  — well under 300. Single concern. ✅

## Wiring
- [ ] User-facing.
- [x] Implementation only (warehouse accuracy).

## Feature-Completeness Pre-Check
n/a — data-pipeline defect fix; the "signal" is the mart row. Proving gate: remove a book's last
placement, trigger the refresh, observe the mart row gone/zero (per #110-style far-end
observation).

## Technical Requirements (approach options — decide at pickup)
1. **Emit tombstones from the model** (preferred candidate): have the incremental recompute
   include affected book_ids with `read_count = 0` (e.g. derive the incremental key set from ALL
   placements — including soft-deleted — with `count(...) filter (where removed_at is null)`), so
   delete+insert replaces the stale row with a zero row (or keep-and-zero semantics).
2. `delete+insert` with an explicit pre-delete of book_ids present in the batch's source scan
   (dbt `incremental_predicates` / custom strategy).
3. Scheduled `--full-refresh` cadence as a stopgap (document staleness window) — least preferred.

Whichever lands: keep the singular test green under incremental maintenance, and update the
`dbt_refresh_handler.ex` comment to drop the KNOWN LIMITATION note.

## Reviewer Context
- The mart's incremental predicate keys on `updated_at`; `Shelving.remove_book/2` bumps it via
  `Multi.update`, so the affected book IS selected into the batch — the gap is purely that the
  filtered recompute then produces no row for it.
- `DbtRefreshJob` dedups via `unique: [period: 300, keys: [:models]]` — burst behaviour is fine.
- GDPR bulk erasure hard-deletes placements without emitting `placement.removed`
  (`deletion.ex:126-129`) — decide whether erasure-driven count corrections ride the scheduled
  refresh or need their own trigger (they currently ride the schedule; likely acceptable, state it).

## Test Audit
| Layer | Applies? | Verdict |
|-------|----------|---------|
| dbt (L9) | yes | ❌ → ✅ — a test proving last-placement removal zeroes/drops the mart row under INCREMENTAL run (not full-refresh) |
| Background jobs (L5) | maybe | verify the triggered refresh path covers the fix; existing firing test stands |
| 1–13 others | no | n/a — no app-code surface expected |

## Definition of Done
- [ ] Last-placement removal reflected in `mart_community_read_count` on the next incremental run — evidence: test + a live-triggered observation
- [ ] `test_mart_community_read_count_excludes_removed` passes under incremental maintenance — evidence: dbt test run after an incremental cycle exercising the case
- [ ] `dbt_refresh_handler.ex` KNOWN LIMITATION comment updated — evidence: diff
- [ ] `just verify` passes — evidence: output

## Dependencies
- Follows #116 Phase 6 (`placement.removed` → DbtRefreshHandler wiring).

## Agent Assignment
`database-agent`. Reviewer: `database-reviewer`.

## Progress Notes
Filed 2026-07-23 by the #116 Phase 6 review (database-reviewer P3 ×2 folded here).
