# Issue #315: [EPIC] Campaign Wave 5 — Book identity: wire the deep verb

## Summary
Epic for Wave 5 of `plans/staff-campaign-2026-07-30.md`. `Books.confirm/2` (books.ex:974) already implements duplicate detection, `find_same_work` merge, and atomic create-and-place — and has zero frontend/E2E callers. Wire it into the manual path, delete the client-side reassembly, and close the silent-failure holes in the vision pipeline.

## User Stories
US-1.1.5 (manual entry), US-1.1.6 (duplicate awareness), US-1.1.8 (same-work merge), US-1.1.2 (gate provenance/D1), US-1.1.1 (failure UX foundations).

## Goal
Manual ISBN entry can add books not yet in the catalogue (today it 404s valid ISBNs); the W-13 two-works duplicate stops being creatable on any path; no upload can leave its image row non-terminal; deterministic vision failures stop being retried on GPU; resolver outages stop being recorded as `:invalid_book`.

## Scope Check
Epic; children below, each within scope rules.

## Wiring
Router wiring: uses existing `POST /api/books/confirm`; deletes the two superseded DIY hops from the client. User-facing on completion.

## Feature-Completeness Pre-Check
| User Story | Happy-path hops | Live-drive result | Verdict | Resolution |
|-----------|------------------|-------------------|---------|------------|
| US-1.1.5 add a NEW book via manual ISBN | `find_existing` only (book_controller.ex:246) — no external resolve | driven 2026-07-30: valid new ISBN → 404 "check the number" | ❌ | build in-scope (wire confirm/2) |
| US-1.1.8 same-work merge prompt on ISBN path | `find_same_work` only called by dead confirm/2 | two Name-of-the-Rose works live in search | ❌ | build in-scope |

## Technical Requirements (child phases)
1. **Wire the verb**: `Page.Upload.elm` manual path calls `POST /api/books/confirm` (`Api.elm` gains the client fn); delete the DIY `lookupByIsbn`→`placeBook` flow; surface `confirm/2`'s duplicate/merge outcomes in the UI (informational per the multi-shelf ruling in #314; merge prompt per US-1.1.8 copy).
2. **Unify creates**: collapse `create/1` (books.ex:175-227) and `create_confirmed_book/4` (books.ex:1019-1070) into one transaction; restores the dropped `google_books_id`; `merge_edition/2` keeps its resolved metadata instead of discarding it (books.ex:1085).
3. **Terminal failure, shape B then A**: (B) final-attempt wrapper — no exit path of `IdentifyBookJob` may leave the row `pending` (`identify_book_job.ex:125-128` is the gap; `mark_rejected/2` exists and is idempotent); align `sse_max_timeout_ms` with actual job death. (A) closed vision error set (`:circuit_open | :budget_exceeded | {:undecodable_image,_} | {:upstream_status,_} | {:transport,_}`) mirroring `ISBNResolver`'s documented pattern; sidecar returns distinguishable codes; deterministic → `{:cancel}` with user-meaningful reason, transient → retry.
4. **Resolver truth + extraction**: fix the four `_`-collapse sites (books.ex:1089, book_controller.ex:33/94, moderation.ex:467-471 — a GB 503 must not record `:invalid_book`; match the closed error type); give `title_fallback/5` its missing catch-all; provisional-title UI treatment for `"ISBN …"` placeholder books (D1: never reads as a normal entry); extract `Stacks.Books.ISBN` (pure, books.ex:1218-1372) and `Stacks.Uploads` (books.ex:344-534) so `books.ex`'s contract is statable.

## Reviewer Context
- W-11-class regression guard: the wired manual path's test must use a checksum-valid ISBN ABSENT from the DB with a seamed resolver mock — red against today's code first.
- `confirm/2` calls `find_same_work` (Jaro-Winkler >0.8) — the merge prompt consumes its result; do not re-implement matching client-side.
- Vision pipeline changes cross into `apps/vision` (distinguishable error codes) — Modal deploy needed for the E2E leg; budget GPU cold start.
- Praise-worthy patterns to preserve: idempotent `mark_resolved/rejected` scoping, telemetry PII whitelisting, `interpret/2`'s determination split.

## Test Audit
| Layer | Applies? | Verdict |
|-------|----------|---------|
| API calls | yes | ❌ manual-new-ISBN 201 path (seamed resolver); merge-prompt path; dup-notice path |
| Oban jobs | yes | ❌ final-attempt terminal test (no exit leaves pending — property-style over the error branches); deterministic-vs-transient retry split |
| External services | yes | ❌ resolver-outage → NOT :invalid_book (funnel counter asserted); sidecar error-code contract test |
| Elm | yes | ❌ manual-path program test on the new flow; provisional-title rendering |
| Event flow | yes | ❌ image.rejected emitted on terminal failure (registry per #314) |
| Others | n/a at epic level | full audits per child |

Punch: 9 items above; each ❌ names its suite at spin-out.
Verdict: baseline ❌ ×9.

## Definition of Done
- [ ] Live drive on preview: NEW valid ISBN added via manual entry end-to-end (screenshot); second ISBN of an existing work triggers the merge prompt (screenshot); a forced vision failure surfaces a user-visible failure state in seconds, not minutes — evidence: screenshots + logs
- [ ] W-13 regression: creating the second Name-of-the-Rose ISBN merges/prompts instead of minting a second work — evidence: catalogue query before/after
- [ ] Zero-row style check: no `uploaded_images` row left `pending` after a full failure-mode sweep — evidence: SQL output
- [ ] Mutation probe on the new manual-path test (break the wiring → red) — evidence: probe transcript
- [ ] Feature-Completeness rows ✅ live; validation path per behaviour; suites + `just verify` green
- [ ] Test audit GREEN; `completion-audit` passed; Completion Bar met
- [ ] `gdpr-review` on the diff (event payloads + image lifecycle touched) — cite verdict
- [ ] `staff-review` verdict per child in Progress Notes

## Dependencies
- #314 — consumes `verification_source`, the placement model, and (if chosen there) proto error codes. Reason: contracts before consumers.
- #313 — steerable vision mock is how most of this epic's tests exist at all. Reason: guarantees before refactors.
- #312 — books.ex extraction must not carry dead code along. Reason: deletions first.

## Agent Assignment
Orchestrator; elixir-agent (domain/worker), elm-agent (upload flow), vision/python agent (sidecar codes).

## Progress Notes
Filed 2026-07-30 by staff-campaign Stage 7.
