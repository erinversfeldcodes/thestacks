# Issue #287: Bookmark Ribbon on Spines for Books with User Writing

## Summary
Implement the bookmark-ribbon / coloured-tabs spine affordance for books that have associated user writing (blog posts) — the US-1.3.2 sub-feature de-scoped from Issue #113. No such element exists in `Components.Spine` today (verified 2026-07-23: no ribbon/bookmark/`book__tab` element in `Spine.elm`).

## User Stories
- US-1.3.2 — Spine Wear by Engagement (the "Books with User Writing" slice only; de-scoped from #113 at epic kickoff 2026-07-23)

## Goal
A book the user has written about shows a visible bookmark ribbon (or coloured tabs) on its spine on any shelf, so writing-linked books are spottable at a glance.

## Scope Check
All four checks: No (one Elm component sub-element + data plumbing for a has-writing flag).

## Wiring
Router wiring: n/a — extends the existing spine rendering; user-facing on completion.

## Feature-Completeness Pre-Check

| User Story | Happy-path hops (file:line) | Live-drive result | Verdict | Resolution |
|-----------|------------------------------|-------------------|---------|------------|
| US-1.3.2 (ribbon slice) | `Blog.book_ids_with_user_writing/2` (blog.ex:386) → `BookshelfController.render_visible_bookshelf` batches the flag (bookshelf_controller.ex:79-86) → `ProtoJSON.shelf_with_placements/3` puts `has_user_writing` per placement (proto_json.ex:561-573) → `Types.Placement.placementDecoder` layers the optional bool (Placement.elm:117-132) → `Page.Bookshelf.Helpers.viewClickableSpine` passes `hasWriting` (Helpers.elm:151,258) → `Components.Spine.book` renders `.book__ribbon` + `, with your notes` aria (Spine.elm) | ✅ spine-rendering.spec.ts:512 on live :4000 — written-about book shows a `.book__ribbon` (count 1) and `, with your notes`; a plain book on the same shelf shows neither. 9 passed / 1 skipped (the pre-existing null-page_count skip). | ✅ | Built end-to-end + observed live. |

Verdict: ✅ implemented (built end-to-end + observed live) · 🟡 partial (enumerate missing hops) · ❌ missing (build in-scope or de-scope).

## Technical Requirements
- Data: the bookshelf/placement payload needs a per-book "has user writing" signal (writing association exists server-side — `my_writing` on book detail; the shelf payload may need a lightweight flag; check `GET /api/bookshelves/:name` response shape and ProtoJSON).
- Elm: new spine sub-element (e.g. `book__ribbon`) rendered when the flag is set, in `Components.Spine.book`; aria-label mention (e.g. ", with your notes").
- Keep the 3D face structure (`book__spine`/`book__top`/`book__cover`) intact — the ribbon is additive.
- elm-test: ribbon renders iff flag set; E2E: seed a book with a blog post, assert ribbon visible on the shelf.

## Reviewer Context
- `Spine.elm` also renders a hidden/owner-only suffix and `book--hidden` class (added post-2026-07-08) — ribbon must compose with it.
- Elm module exposing gotcha: land any new exposed test hook together with its consuming test (elm-review narrows exposures otherwise).

## Test Audit

_Compact audit (format A) — the 13 layers, each `yes` (✅ + a test citation verified by grep/Read against the shipped suites) or `n/a`-with-rationale. The ribbon is a per-placement `has_user_writing` flag (a computed non-persisted boolean over the owner's own Blog associations) plumbed to an additive Elm spine sub-element — no new event, job, migration, or dbt model._

Last generated: 2026-07-25 (post-implementation compact audit)

Legend: ✅ = real coverage | n/a = not applicable (one-line reason).

| Layer | Applies? | Verdict |
|-------|----------|---------|
| 1. API calls | yes | ✅ (payload) `bookshelf_controller_test.exs:360` (`has_user_writing` is true for a book the owner has written a visible association about) + `:379` (false for a book the owner has not written about), both through `GET /api/bookshelves/:name`. |
| 2. Auth & middleware guards | no | n/a — the flag reuses the existing owner-scoped `/api/bookshelves/:name` pipeline (computed for the authenticated owner only, defaults false on non-owner serializer paths); the other-user exclusion is asserted at the context layer (`blog_test.exs:429`). |
| 3. Database interactions | yes | ✅ `blog_test.exs:407` (`book_ids_with_user_writing/2` returns ids of books with a visible association), `:420` (excludes invisible/unconfirmed associations), `:429` (excludes another user's writing about the same book), `:439` (empty book_ids short-circuits to the empty set). |
| 4. Event flow & lifecycle | no | n/a — a computed non-persisted boolean; never written to event_log (GDPR lens). |
| 5. Background jobs (Oban) | no | n/a — the batch lookup is synchronous (no N+1); no job. |
| 6. External service calls | no | n/a — reads local Blog associations only. |
| 7. Storage | no | n/a — no storage operation. |
| 8. Cache | no | n/a — the flag rides the bookshelf response; not cached independently. |
| 9. dbt models | no | n/a — non-persisted boolean layered outside the proto (like `visibility`); no migration/dbt model. |
| 10. Elm frontend state machine | yes | ✅ `SpineBookTest.elm:415` (a written-about book renders a `.book__ribbon` element), `:420` (the ribbon is decorative/aria-hidden), `:429` (a book with no writing renders no ribbon), `:445` (written-about book aria ends with ", with your notes"), `:450` (no writing → no notes suffix), `:455` (wear/notes/hidden compose in order); E2E `spine-rendering.spec.ts:518` (ribbon present on the written-about book, absent on a plain book on the same shelf — live). |
| 11. Operational metrics | no | n/a — SLO gate (`scripts/check-slo-gate.sh`). |
| 12. Performance & usability | no | n/a — SLO gate. |
| 13. Cost tracking | no | n/a — pure client render over local data. |

Tally: 3 ✅ / 10 n/a — 0 ❌, 0 ⚠️. GREEN.

## Definition of Done
- [x] Ribbon renders on spines of books with user writing, absent otherwise — evidence: elm-test (`SpineBookTest.writingRibbonRendering` asserts `.book__ribbon` present iff `hasWriting`, absent otherwise; `writingSuffixInAriaLabel` pins the exact `, with your notes` aria in the fixed pages→wear→notes→hidden order) + `mix test` (`blog_test` book_ids_with_user_writing/2 true-with-visible-assoc, false without, other-user-excluded, invisible-excluded; `bookshelf_controller_test` `has_user_writing` true/false in payload) + E2E live drive (spine-rendering.spec.ts:512 on :4000 — ribbon count 1 + notes suffix on the written book, count 0 + no suffix on a plain book on the same shelf).
- [x] **Feature-Completeness Pre-Check (above) is ✅ for every named user story** — US-1.3.2 ribbon slice ✅ built end-to-end + observed live.
- [x] Every behaviour has a validation path — component render (elm-test), server payload (mix test), full-stack (E2E live).
- [x] Tests written and passing — `npx elm-test` scoped to SpineBookTest/SpineHiddenTest/Bookshelf*/Library/UpdateTest = 88 passed; `just run mix test blog_test bookshelf_controller_test` = 72 passed, 0 failures.
- [x] Standards compliance verified — elm-format clean; `elm-review --config elm-review src/ tests/` = "no errors"; `mix format --check-formatted` clean; `mix credo` = no issues; `prettier --check` on e2e = clean.
- [x] **Test audit is GREEN** — compact audit generated + citations verified 2026-07-25 (this section).
- [x] **`completion-audit` skill passed on the integrated branch** — pending integration (run by orchestrator on the integrated branch). — evidence: epic completion-audit PASS 2026-07-25 — adversarial spot-verification of all 16 children found zero false evidence tokens; its 3 finalization blockers cleared (CVE fix 32b2a18c + ci green, compact audits 8eaf4bb6, preview E2E below)
- [x] **Meets the Completion Bar** (`docs/agents/standards/completion-bar.md`) — pending integration-level validation. — evidence: Completion Bar met at epic level 2026-07-25 — every deliverable driven live locally (per-issue Pre-Check) AND on the deployed preview: full run 250 passed/10 failed/10 skipped (all 10 failures = helper-502 machine-churn signature) with all 10 passing the single documented environmental retry (12/12, exit 0); logs scratchpad/preview-e2e-run2.log + preview-e2e-retry10b.log

> Note: full-suite `npx elm-test` is currently blocked by an unrelated, uncommitted partial in `tests/Page/SearchProgramTest.elm` (search track / #289 — two suite entries with no backing functions) that breaks compilation. Flagged to main; not part of #287 and not committed here. #287 modules were validated by explicit-file elm-test.

## Dependencies
- Issue #113 (spine E2E harness — `spine-rendering.spec.ts` lands there)
- Blog/writing association data on the shelf payload (may need a proto field → `mix proto.sync`)

## Agent Assignment
`elm-agent` (+ `elixir-agent` if the shelf payload needs the flag).

## Progress Notes
- 2026-07-23 — Created at #115/#114/#113 epic kickoff: ribbon sub-feature de-scoped from #113 (unimplemented; #113 is test-only).
- 2026-07-24 — Implemented (elm-agent). Server: `Blog.book_ids_with_user_writing/2` batches the has-writing set for a whole bookshelf (no N+1); `BookshelfController` looks it up for the authenticated owner only and `ProtoJSON.shelf_with_placements/3` layers `has_user_writing` onto each PlacementDetail (outside the proto, per the existing `visibility` precedent — no proto/migration change). Client: `Types.Placement` gains `hasUserWriting` (optional decode, defaults false); `Components.Spine.book` renders an additive `.book__ribbon` child + a `, with your notes` aria suffix composed in the fixed pages→wear→notes→hidden order; `.book__ribbon` CSS (main.css) is a swallowtail cloth ribbon poking above the spine head. E2E helper `POST /api/test/book-writing` (STACKS_E2E_TEST_HELPERS-gated, `.test`-domain allowlist) seeds a visible association deterministically. Gates: elm-test 88 (scoped) green, mix test 72 green, elm-review/format/credo/prettier clean, spine-rendering.spec.ts:512 driven live on :4000 (9 passed/1 skipped). GDPR: n/a — computed non-persisted boolean over the user's own Blog associations (already export/erasure-governed), shown only to the owner's own shelf; never persisted, never in event_log/warehouse, defaults false for any non-owner serializer path. Not yet done: `test-audit` baseline, `completion-audit`, Completion Bar (integration-level).
