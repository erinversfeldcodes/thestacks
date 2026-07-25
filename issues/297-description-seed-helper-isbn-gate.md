# Issue #297: Constrain the book-description E2E Helper Against Catalogue Pollution

## Summary
PE finding (epic 2F review, 2026-07-25, P2): `POST /api/test/book-description` (`test_helper_controller.ex:270-310`, added in #284) is the only `/api/test/*` helper that (a) has no `.test`-domain scoping and (b) inserts PUBLIC books with synthetic checksum-valid ISBNs that never pass Open Library/Google Books verification — bypassing the ISBN Hard Gate's spirit. On a preview with `STACKS_E2E_TEST_HELPERS=1` these unverified books persist in the shared catalogue, indistinguishable from verified ones, visible in everyone's search. Low risk (flag-gated, rate-limited, preview-only, no PII) but it needs a tracked decision + mechanism.

## User Stories
None — test-infrastructure hardening. Validation: the chosen mechanism proven by a test + a preview drive.

## Goal
E2E-seeded catalogue rows are identifiable and cannot masquerade as verified catalogue: tag-and-filter, cleanup-on-teardown, or an explicitly documented acceptance — decided and implemented.

## Scope Check
All four checks: No.

## Wiring
Router wiring: n/a — existing gated helper.

## Feature-Completeness Pre-Check
n/a — test infra; validation = mechanism test + preview drive.

## Technical Requirements
Options (owner decision at pickup): (a) tag seeded books (e.g. a `source: "e2e_seed"` marker or a reserved ISBN prefix range) and exclude them from public search/catalogue for non-test viewers; (b) teardown deletion (helpers register created ids; cleanup endpoint or preview-reset removes them); (c) documented acceptance (preview DBs are Neon copy-on-write branches discarded per PR — verify that lifecycle actually bounds the pollution, and write the acceptance into the helper doc). Verify what the preview DB lifecycle really is before choosing — (c) may be free if previews never persist.

## Reviewer Context
- The helper routes through `Books.create` so tagging must not weaken real-path validations; the ISBN Hard Gate is CLAUDE.md-non-negotiable in spirit even where seeds bend it.

## Test Audit
| Layer | Applies? | Verdict |
|-------|----------|---------|
| test-infra | yes | ❌ mechanism + test → ✅ when done |
| others | no | n/a |

## Definition of Done
- [ ] Mechanism decided + implemented + tested — evidence: test + preview observation
- [ ] Helper doc updated with the decision rationale
- [ ] `just verify` passes

## Dependencies
- #284 (introduced the helper).

## Agent Assignment
`elixir-agent`.

## Progress Notes
- 2026-07-25 — Created from the epic PE review P2 (hard question 1 of the finalization stop).
