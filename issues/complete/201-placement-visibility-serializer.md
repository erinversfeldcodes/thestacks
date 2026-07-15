# Issue #201: Emit placement visibility in book_placement serializer + proto

## Summary
Child of the #122 epic (integration branch `feat/122-e2e`), discovered during #194. The placement-visibility frontend (#194) is built and unit-tested, but the backend `ProtoJSON.book_placement/1` serializer and the `BookPlacement` proto message do **not** emit `visibility` or the parent shelf's `bookshelf_visibility`. Until they do, the per-placement dropdown, client-side ceiling-greying, and faint-outline owner-only spine cannot light up live. This issue adds those two fields so US-10.2.2 works end-to-end.

## User Stories
Supports US-10.2.2 (Override Placement Visibility) — the backend data hop that #194's frontend consumes.

## Goal
`GET` responses that include placements (book-detail + bookshelf/placement payloads that feed the spine) carry each placement's `visibility` and its parent bookshelf's `visibility` (as the ceiling), so the #194 frontend renders the current selection, greys ceiling-exceeding options, and draws the faint owner-only spine. Backwards-compatible (additive proto fields).

## Scope Check
- Controllers touched: 0 new (serializer + proto only). OK.
- New endpoints: 0. OK.
- ~<150 LOC + proto regen. OK.
- Single concern (serialize placement visibility). OK.

## Wiring
- [ ] This issue includes router wiring and is user-facing when complete.
- [x] This issue is implementation only — activates #194's already-built frontend.

## Feature-Completeness Pre-Check
n/a — backend serialization hop for an already-claimed story (US-10.2.2, built in #194). This issue is what makes that story's happy path reachable live; #200 (E2E placement) hard-depends on it.

## Technical Requirements
- Add `visibility` (string) to the `BookPlacement` proto message and to `ProtoJSON.book_placement/1` (source: `placement.visibility`). Field numbers are forever — append, never reuse. Run `mix proto.sync` and regenerate Elm/other decoders.
- Add the parent bookshelf's visibility as `bookshelf_visibility` (string) on the same placement payload (the ceiling the frontend greys against) — join through `op.bookshelves.visibility`.
- Confirm the field names match what #194's frontend already decodes: placement `visibility`, and `bookshelf_visibility` on the book-detail placement shape (see #194 `Api.BookDetailResponse.bookshelfVisibility` + `Types.Placement.visibility`).
- GDPR: `visibility` is not personal free-text; ensure the new fields flow through export/erasure only as they already do for placements (no new personal data class). Run the `gdpr-review` lens on the diff.

## Reviewer Context
- The Elm side (#194) already decodes both fields optionally and defaults safely when absent, so this change is additive and cannot break existing clients.
- `bookshelf_visibility` is the shelf ceiling used for client-side option greying that mirrors the server `validate_visibility_ceiling/3` 422.

## Test Audit
| Layer | Applies? | Verdict |
|-------|----------|---------|
| API/serializer (placement payload includes `visibility` + `bookshelf_visibility`) | yes | ❌ needs a controller/serializer test asserting both fields present with correct values (→ ✅ when done) |
| proto.sync drift | yes | ❌ `mix proto.sync --check` clean after regen (→ ✅) |
| E2E | yes (downstream) | delivered by #200 (hard-depends on this) |
| 1–13 app/US layers | mostly n/a | n/a — additive serialization; visibility semantics already tested in #122's Elixir suite |

## Definition of Done
- [ ] `BookPlacement` proto + `ProtoJSON.book_placement/1` emit `visibility` and `bookshelf_visibility`
- [ ] `mix proto.sync --check` clean; Elm/other decoders regenerated
- [ ] Serializer test asserts both fields present with correct values (happy + absent-defaults)
- [ ] gdpr-review lens clean (no new personal data class)
- [ ] `just verify` passes
- [ ] #194's frontend renders live against a preview (validated jointly with #200)

## Dependencies
Epic #122. Consumes: #194 (frontend already built). Blocks: #200 (E2E placement visibility).

## Agent Assignment
elixir-agent (proto + serializer), with contract-reviewer (cross-boundary data shape).

## Progress Notes
- 2026-07-14: Created mid-epic from #194's flag #1 (serializer gap). Added to the #122 DAG; #200 now depends on #194 + #201.
