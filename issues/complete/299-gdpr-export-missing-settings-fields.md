# Issue #299: GDPR export omits settings personal-data fields

## Summary
`GDPR.Export.export_user_data/2`'s user block omits several user-provided personal-data fields: the four `notify_*` notification preferences, `website_url`, `country_code`, `city`, and `handle`. A user exercising their right to export does not receive the very fields the settings screens write.

## User Stories
None directly (GDPR right-to-export is a platform invariant, not a numbered story). Surfaced by the gdpr-review lens during the #125/#126 epic (2026-07-25) and elevated to a must-file P1 by the epic-level PE review (2026-07-26).

## Goal
`export_user_data/2` includes every personal-data field stored on the user row: add `notify_wishlist_availability`, `notify_marketplace`, `notify_group_invitations`, `notify_event_matches`, `website_url`, `country_code`, `city`, and `handle` to the export's `user` map (`apps/core/lib/stacks/gdpr/export.ex` ~lines 67-80), with a test proving each field appears with its stored value. Sweep the user schema for any OTHER personal field missing from the export while there (the fix must be a completeness pass, not just these eight).

## Scope Check
- Does this issue touch more than 3 controllers? No (context + one test file; export is context-level).
- Does this issue add more than 2 new endpoints? No.
- Does this issue exceed ~300 lines of production code? No (~10 lines + tests).
- Does this issue combine unrelated concerns? No (export completeness only).

## Wiring
Implementation-only: the existing `POST /api/gdpr/export` flow (`GDPRController` → `DataExportJob` → `Export.export_user_data/2`) already delivers the payload; this issue only completes its contents.

## Feature-Completeness Pre-Check
n/a — no user stories; the deliverable is an invariant-completeness fix. Validation path: the export test asserts each field, and a live-drive requests an export and inspects the payload.

## Technical Requirements
- Extend the `user:` map in `Stacks.GDPR.Export.export_user_data/2` with the eight fields above (plus any others found by the schema sweep — compare `Stacks.Gen.Accounts.User` fields against the export map; every `personal`-classified column must appear or carry a written exclusion rationale).
- Tests in `apps/core/test/stacks/gdpr/export_test.exs` (or sibling): a user with non-default values for all eight fields exports them verbatim; regression-guard style preferred (iterate a field list so a future schema addition fails loudly — mirror the erasure schema-guard pattern).
- Run the `gdpr-review` skill on the diff (export surface change).
- No new endpoints, events, or stored data.

## Definition of Done
- [x] Export includes all personal user-row fields (evidence: `apps/core/test/stacks/gdpr_test.exs:150` asserts handle/website_url/country_code/city + 4 notify_* verbatim; map at `apps/core/lib/stacks/gdpr/export.ex:75-96`)
- [x] Schema-sweep guard: a personal column missing from the export fails a test (evidence: `apps/core/test/stacks/gdpr_test.exs:179` iterates `User.__schema__(:fields)` minus `@export_excluded_fields`; perturbation red confirmed — removing `handle` from the map fails with "op.users personal fields missing from GDPR export: [:handle]")
- [x] `just run just verify` passes (evidence: run 2026-07-26, exit 0 — full suite + format + credo + proto sync + dbt-checkpoint "All blocking checks passed"; full backend suite 2957/0 in the specialist run, gdpr file 19/0 fresh orchestrator run)
- [x] gdpr-review PASS recorded on the diff (evidence: orchestrator lens 2026-07-26 — portability-only surface, secrets/live tokens correctly excluded with in-code rationale, sweep guard derives exported keys from the real map [no dual-list drift, reviewer-verified], no storage/event/audit/warehouse change; elixir-reviewer APPROVED)

## Dependencies
None. Context: found during the #125/#126 epic; see `issues/126-e2e-settings.md` GDPR Review Record and `plans/125-126-e2e-epic-state.json` notes.

## Agent Assignment
elixir-agent

## Priority
P1 (right-to-export completeness — GDPR-by-default core convention)

## Progress Notes
- 2026-07-26: Filed by the orchestrator at the #125/#126 epic PE gate (pre-existing gap, out of that epic's build scope; elevated from epic-state note to tracked issue per PE requirement).
