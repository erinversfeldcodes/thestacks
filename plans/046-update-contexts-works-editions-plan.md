# Plan: Update Core Contexts for Works/Editions + Two-Step Upload
**Issue**: #046
**Created**: 2026-03-19
**Status**: In Progress

## Context
The works/editions schema (Issue #042) introduced `op.books` (work-level) and `op.book_editions` (edition-level). This issue wires the Elixir contexts up to that model: two-step upload (identify → confirm), duplicate detection, multi-format merge, and updated shelving/spine data. Wave B pre-work already delivered AI.Client additions, InternalController, and `confirm_cover_association/2`.

## Research Summary
- `Books.confirm_cover_association/2`, `AI.Client.associate_isbn/4`, `AI.Client.extract_from_url/1`, and `InternalController` are **already implemented** (Wave B pre-work).
- Elixir stdlib `String.jaro_distance/2` provides Jaro distance; Jaro-Winkler prefix boost can be computed inline — **no external dependency needed**.
- `ISBNResolver` currently returns `open_library_id` (edition-level); needs to also extract `open_library_work_id` from Open Library's `key` field.
- Old `POST /api/upload` + polling flow is kept unchanged; new endpoints are additive.
- `Shelving.update_placement_formats/3` is deprecated-in-place (Elm still calls it; full removal comes with Elm wave).
- `Books.search_platform/2` implemented as a public-catalogue stub for now (real visibility gating wired in by Issue #047).

## Approach Options
- **A (chosen):** New `identify/confirm` endpoints alongside old upload flow — no breaking changes. Old `POST /api/upload` keeps working. Safest migration path.
- **B:** Replace old upload flow entirely. Cleaner but breaks polling-based Elm upload page; requires coordinated Elm PR.
- **C:** Make identify/confirm async via Oban. Defeats purpose — clients need synchronous candidate list to present choice to the user.

## Phases

### Phase 1: Core Books Context
**Objective**: Implement the missing context functions that drive the two-step upload flow and edition management.
**Agent**: elixir-agent
**Steps**:
1. Add `Books.find_same_work/2` — Jaro-Winkler similarity (inline, using `String.jaro_distance/2` + prefix boost) across existing works by title+author; threshold 0.8
2. Add `Books.identify/2` — calls `AI.Client` vision + `ISBNResolver.resolve/1`, returns candidate list without committing to DB
3. Add `Books.confirm/2` — ISBN duplicate check → existing book; fuzzy match → merge prompt (409); else create work + edition + placement; default shelf: `"wishlist"`
4. Add `Books.merge_edition/2` — creates new `book_editions` row (is_primary=false) under existing work; validates ISBN unique
5. Add `Books.search_platform/2` — stub: paginated public catalogue only (graceful fallback; Issue #047 wires in visibility)
6. Update `ISBNResolver.resolve/1` and `search_by_title/3` to also return `open_library_work_id` when available from OL `key` field
**Test Command**: `cd apps/core && mix test test/stacks/books_test.exs`
**DoD Items**:
- [ ] `Books.identify/2` returns candidate list from vision + ISBN resolver, no DB commit
- [ ] `Books.confirm/2` creates work + edition + placement (default: wishlist)
- [ ] Duplicate detection: existing ISBN returns existing book data (no new placement)
- [ ] Multi-format merge: same title+author Jaro-Winkler > 0.8 → merge prompt response
- [ ] `Books.merge_edition/2` creates new edition row under existing work
- [ ] ISBNResolver returns `open_library_work_id` when available
- [ ] All new functions have `@spec` and `@doc`

### Phase 2: Controllers + Router
**Objective**: Expose the two-step upload flow and edition merge as HTTP endpoints.
**Agent**: elixir-agent
**Steps**:
1. Add `UploadController.identify/2` — `POST /api/upload/identify`; accepts multipart or `{image_url}` JSON body; calls `Books.identify/2`; returns `{status: "identified", candidates: [...]}`
2. Add `BookController.confirm/2` — `POST /api/books/confirm`; params `{isbn, shelf_name?}`; calls `Books.confirm/2`; 200 for new/existing, 409 for merge prompt
3. Add `BookController.merge_format/2` — `POST /api/books/:id/merge-format`; params `{isbn, format_label?, ...}`; calls `Books.merge_edition/2`
4. Wire routes in router (authenticated scope)
5. Write controller tests for all three endpoints (happy path + error paths)
**Test Command**: `cd apps/core && mix test test/stacks_web/`
**DoD Items**:
- [ ] `POST /api/upload/identify` returns identified candidates (with mocked vision)
- [ ] `POST /api/books/confirm` creates work + edition + placement
- [ ] `POST /api/books/:id/merge-format` creates new edition
- [ ] All controller tests include auth (401 without token) and validation (422 for bad params)

### Phase 3: Shelving Updates
**Objective**: Update spine_data/1 to derive formats from editions; deprecate update_placement_formats/3.
**Agent**: elixir-agent
**Steps**:
1. Update `Shelving.spine_data/1` — derive format list from `book.editions[].format_label` (via preloaded editions on placement); keep `page_count` from primary edition
2. Add `@deprecated` annotation to `Shelving.update_placement_formats/3` with deprecation note; keep function body intact (Elm still calls it)
3. Update `get_bookshelf_books/2` preload to ensure editions are included in placement preloads (if not already)
4. Verify all existing Shelving tests pass; add tests for updated `spine_data/1`
**Test Command**: `cd apps/core && mix test test/stacks/shelving_test.exs`
**DoD Items**:
- [ ] `spine_data/1` derives formats from `book_editions.format_label`
- [ ] `update_placement_formats/3` annotated as deprecated
- [ ] All existing Shelving tests pass
- [ ] `get_bookshelf_books/2` includes edition preloads

## Open Questions
- None — resolved in research.

## Integration Handoffs
- Phase 1 functions are called by Phase 2 controllers — Phase 2 starts after Phase 1 is committed.
- Phase 3 is independent of Phases 1 and 2 (shelving is a separate context).
- Issue #047 wires real visibility into `search_platform/2` stub.
- Issue #072 (Python vision sidecar `/associate` endpoint) is assumed live for `identify/2` happy path; mock client used in tests.
