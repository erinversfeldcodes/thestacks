# Issue #281: Shelving/Books hardening follow-ups from the #116 PE gate

## Summary
Three small, related hardening items the #116 Principal Engineer gate identified (P3-1/2/3), plus a
recorded refactor candidate. None are user-visible defects today; each is a latent inconsistency
worth aligning while the #116 context is fresh.

## User Stories
US-1.6.x robustness — no new behaviour.

## Goal
Uniform not-found semantics across Shelving's placement operations, a deterministic page-count
ceiling, and the pile-full message on the direct-place path.

## Scope Check
1 context + 1 controller-adjacent area, 0 new endpoints, <300 LOC, one theme (hardening). ✅

## Feature-Completeness Pre-Check
n/a — hardening of shipped features (each behaviour exists; this aligns edges).

## Technical Requirements
1. **not-found alignment (PE P3-1):** `remove_book/2` (`shelving.ex:437`),
   `update_placement_formats/3` (`:482`), `move_placement_to_shelf/3` (`:887`) still `Repo.get!`
   (raise → 500 on a missing id at the context layer; HTTP-safe today only via controller
   pre-checks). Convert to `Repo.get` → `{:error, :not_found}` matching `move_book/3`/`reread_book/2`
   (#116 Phase 3 pattern), map in controllers, drop now-redundant pre-checks if that simplifies.
2. **Deterministic primary edition (PE P3-2):** `Books.primary_edition/1` (`books.ex:120-130`) has
   no tiebreak — a multi-edition book with no/multiple `is_primary` yields an unspecified pick, now
   load-bearing for the #116 page-count ceiling (`shelving.ex:759-763`). Add a deterministic order
   (`is_primary desc, inserted_at asc` or similar) in both the query and in-memory clauses + test.
3. **Pile-full copy on the direct-place path (PE P3-3, also #276 scoping note):** `Api.placeBook`
   consumers (Upload/Catalogue/BookDetail "Add to Collection") show a generic failure when the
   reading pile is full (`books.ex:959/:995` degrade cleanly; UX gap only). Surface the specific
   full-pile message on that path, reusing the `#276` copy.
4. **Record only (no work here):** `Stacks.Shelving` is ~1089 lines spanning
   placements/shelves/visibility/progress/capacity (PE P3-4). If it keeps growing, split along
   `Shelving.Placements`/`.Shelves`/`.Visibility`. Revisit when next touched.
5. **Frontend polish (deferred P3s from the #116 Phase-2 reviews — batch when touching these
   files):** past-tense Msg naming (`DismissFinishedPrompt`/`DismissFinishedRead` →
   `*Dismissed`); `progressDecoder`'s `oneOf … succeed Nothing` wrappers swallow type mismatches
   (prefer fail-loudly `field (nullable …)`); extract the byte-identical `foldProgress` +
   near-identical save-state/prompt views shared by the two hosts; ReadingPile `books`/`cards`
   dual source of truth (matters when US-1.3.2 spine progress lands); dead
   `book-detail__status--loading`/`--success` CSS; optional `aria-describedby` on the inline
   progress error; warmer bridge-prompt copy.

## Reviewer Context
- The same-bookshelf no-op, capacity `FOR UPDATE`, and shelf_id re-home logic in `move_book/3` are
  deliberate (#116 Phases 1/3) — don't "simplify" them away while aligning not-found handling.
- `check_move_capacity/3`'s same-bookshelf clause is unreachable defensive dead code (documented);
  removing it is in-scope here if touched.

## Test Audit
| Layer | Applies? | Verdict |
|-------|----------|---------|
| API/context (L1/L3) | yes | ❌ → ✅ — not-found tuples asserted for all three ops; ceiling determinism test |
| Elm (L10) | item 3 | ❌ → ✅ — full-pile message on the place path |
| others | no | n/a |

## Definition of Done
- [ ] All placement ops return `{:error, :not_found}` (no context-layer raises) — evidence: tests
- [ ] `primary_edition/1` deterministic with test — evidence: test name + output
- [ ] Full-pile message on the direct-place path — evidence: elm test + live-drive artifact
- [ ] `just verify` passes

## Dependencies
Follows #116 (this branch). Item 3 relates to #276 (shipped).

## Agent Assignment
`elixir-agent` + `elm-agent` (item 3). Reviewer: `elixir-reviewer`.

## Progress Notes
Filed 2026-07-23 from the #116 PE gate (P3-1/2/3, P3-4 recorded).
