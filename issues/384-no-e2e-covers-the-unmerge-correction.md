# Issue #384: No Playwright test covers the un-merge correction (or its merge inverse end to end)

> **Campaign assignment:** Wave 11 (launch gates) — `plans/staff-campaign-2026-07-30.md`. Tracked in the campaign state; completed as part of epic #321.


## Summary
The owner un-merge (#376) — split a wrongly-merged edition back onto its own work — has **no E2E
coverage**. During #376's staff-review I wrongly claimed there was "no owner API to create a merged
edition"; there is (`POST /api/books/:id/merge-format`, an ordinary reader action), and the reason I
believed otherwise is instructive: nothing drives the merge→unmerge loop through the browser or the
API in the test suite, so its shape was not in front of me.

`merge-format` itself is referenced by `upload-pipeline.spec.ts`, but that spec is Modal-gated and
excluded from the `chromium` project — so in practice the merge path runs in E2E only when the vision
GPU backend is up, and the **un-merge admin correction is not driven anywhere at all.**

## User Stories
Protects US-2.x edition/work integrity and the owner's data-correction guarantees (#340/#376). No new
behaviour.

## Goal
The merge→unmerge round trip is driven by an automated test that fails if either leg breaks, without
depending on the Modal vision backend being deployed.

## Scope Check
- More than 3 controllers? → No. `BookController.merge_format` + `DataCorrectionController` (existing).
- More than 2 new endpoints? → None.
- More than ~300 lines? → No. One E2E spec.
- Unrelated concerns? → No.

## Technical Requirements
- A `chromium`-project Playwright spec (NOT under the Modal-gated upload specs) that:
  1. as an ordinary reader, `merge-format`s a second real ISBN onto an existing work (Open Library
     must resolve it — the ISBN hard gate is real; pick a stable one and skip with a clear message if
     OL is unreachable, the way the deploy preflight does);
  2. as an MFA-verified owner, dry-runs then applies `unmerge_edition` for that edition;
  3. asserts the ISBN resolves to a **different** work afterward, and a second apply refuses.
- ⚠️ The admin leg needs the MFA enrolment dance `admin-session.spec.ts` already implements — reuse
  its `base32Decode`/`totp` helpers rather than reimplementing them.
- ⚠️ The merge leg depends on **Open Library**, which was fully down (503/timeout) on 2026-08-04.
  Gate the spec on an OL reachability check and skip-with-reason, so an OL outage is not a red build —
  the same call the preview preflight makes.

## Reviewer Context
- The correction's *unit* behaviour is exhaustively covered (`unmerge_edition_test.exs`, 41 tests) and
  it was driven live once by hand (#376, 2026-08-04). This issue is about a repeatable guard, not
  first proof.
- `merge_edition/2` sets the new edition `is_primary: false`; the unmerge makes the split-out edition
  primary of its new work. The assertion "resolves to a different work" is the repair; assert that,
  not an intermediate.

## Test Audit
| Layer | Applies? | Verdict |
|-------|----------|---------|
| Elixir unit (unmerge) | yes | ✅ 41 tests — not this issue |
| E2E (merge, chromium) | yes | ❌ merge only runs in the Modal-gated upload spec |
| E2E (unmerge) | yes | ❌ absent — this issue |

## Definition of Done
- [x] A chromium-project spec drives merge→unmerge and asserts the split — evidence: `e2e/tests/unmerge-edition.spec.ts` ("a merged edition can be split onto its own work, exactly once"): reader `merge-format`s a pool ISBN onto a catalogue work, owner (MFA via shared #371 secret + #394 `freshTotp`) dry-runs (mode `dry_run`, count 1, writes nothing — asserted) then applies; the ISBN then resolves to a different work; a second apply 422s naming `primary_edition`. Run against the live preview 2026-08-09: 1 passed (7.5s), and again post-probe (8.9s, different pool ISBN — proving the state-aware idempotence across runs of a persistent preview DB)
- [x] It skips with a clear message when Open Library is unreachable, and does not fail the build — evidence: `openLibraryReachable` probes OL `/search.json` (the preflight's endpoint); forced-skip run (OL host pointed at `.invalid`): `1 skipped`, exit 0. A second guard skips with a reason when the split-ISBN pool is exhausted on a long-lived DB
- [x] Probed: an unmerge that writes nothing reddens it — evidence: apply flag muted → red at exactly `"the split edition lives on its own work now"` (`.not.toBe(target.id)` received the merged-onto work); reverted → green. (Server-side book_id-mutation probing lives in `unmerge_edition_test.exs`'s 41 tests; this probe proves the E2E assertion has the same bite.) Note: the probe run left pool ISBN 9780140449266 merged onto a catalogue work on the throwaway preview DB — harmless, reseeded on next deploy
- [x] The E2E project passes — evidence: setup + chromium runs above; full `just ci` at wave finalize
- [x] `gdpr-review`: n/a — the spec touches edition/work FKs and a minted `.test` user only; no personal data surface added. Stated, not skipped.

## Dependencies
Depends on **#376** (the correction it drives) and **#371** (the admin-session MFA-sharing fix — this
spec enrols MFA the same way and must not collide with the admin-session specs' factor).

## Agent Assignment
`elm-agent` or a test-focused agent; reuse `admin-session.spec.ts` machinery.

## Progress Notes
- 2026-08-04: Filed from #376's review, at the owner's prompting ("why don't we have a playwright test
  for this functionality?"). The absence was load-bearing: it let a reviewer (me) assert a
  non-existent limitation about the merge API and nearly scope #376's live drive down because of it.


## Wave 11 close-out (2026-08-09)
staff-review (Mode B shadow, 2026-08-09): **LGTM WITH NOTES** — state-aware design (ISBN pool + availability probe) makes a destructive round trip repeatable on a persistent DB; skip guards fail open with reasons. Note: pool exhaustion on a long-lived preview is a standing operational caveat, stated in-spec; the probe run left one ISBN merged on the throwaway preview.
