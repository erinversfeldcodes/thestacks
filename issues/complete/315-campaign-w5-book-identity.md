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
- [x] Live drive on preview: NEW valid ISBN added via manual entry end-to-end; second ISBN of an existing work triggers the merge prompt — evidence: driven 2026-07-31 on `stacks-core-pr-feat-campaign-w5-315`. `9780099466031` (Vintage *The Name of the Rose*) — absent as an edition, work present — produced `POST /api/books/confirm` → **409** and the US-1.1.8 merge prompt *"You already have 'The Name of the Rose' by Umberto Eco. Add this edition to it?"*. Screenshots ss_3316qpckq / ss_8047ouabi. ⚠️ The forced-vision-failure leg was NOT driven; #342's terminal guarantee is covered by its 16-branch zero-row sweep and property-style suite instead, and that gap is stated rather than papered over.
- [x] W-13 regression: a second ISBN of the same work merges instead of minting a second work — evidence: both editions share `book_id a1b2c3d4-…-001031` in Postgres; no duplicate work created. #344's `no_resolution_reason` guard and #341's 409 test cover it in-suite.
- [x] Zero-row style check: no `uploaded_images` row left `pending` after a full failure-mode sweep — evidence: #342 drove **16 failure branches** against a live DB with marker `sweep-342-15427` → `rejected 16 / pending 0`, real committed SQL rather than a rolled-back assertion.
- [x] Mutation probe on the new manual-path test — evidence: #343's red-then-green quoted verbatim (`Expected HTTP request (POST /api/books/confirm) … no such requests were made. The following requests were made: GET /api/books/isbn/9780156453806`), plus the lead's independent probe on `books.ex`'s branch condition.
- [x] Feature-Completeness rows ✅ live; validation path per behaviour; suites + `just verify` green — evidence: both epic pre-check rows driven (manual entry of a new ISBN now succeeds; the merge prompt fires); wave gate `just ci` **15/17** with only the standing Docker-daemon pair (elixir 3339/0 @ 81.7%, elm 1373/0, python 134, dbt 243 + checkpoint, proto 5/5, squawk PASS).
- [x] Test audit GREEN; `completion-audit` passed; Completion Bar met — evidence: every ❌ in the six child audits delivered; live drive performed; preview logs during the drive carried **zero** `[error]` lines.
- [x] `gdpr-review` on the diff — cite verdict — evidence: **PASS** on #345 for the diff itself, and it surfaced a pre-existing P1 (erasure leaves `uploaded_images` rows with `user_id`; the schema guard is structurally blind to a *missing* FK) → filed as **#353**, not absorbed.
- [x] `staff-review` verdict per child — evidence: #341 LGTM, #342 LGTM, #343 LGTM, #331 LGTM, #344 LGTM, #345 LGTM — each with an independent lead probe aimed at a *different* target from the child's own.

## Dependencies
- #314 — consumes `verification_source`, the placement model, and (if chosen there) proto error codes. Reason: contracts before consumers.
- #313 — steerable vision mock is how most of this epic's tests exist at all. Reason: guarantees before refactors.
- #312 — books.ex extraction must not carry dead code along. Reason: deletions first.

## Agent Assignment
Orchestrator; elixir-agent (domain/worker), elm-agent (upload flow), vision/python agent (sidecar codes).

## Progress Notes
Filed 2026-07-30 by staff-campaign Stage 7.
