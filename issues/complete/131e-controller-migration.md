# Issue #131e: Migrate Phoenix Controllers to ProtoJSON

## Summary
Replace all inline `format_*` helpers in Phoenix controllers with `StacksWeb.ProtoJSON.*` calls. Pure refactor — JSON output must not change.

## User Stories
N/A — internal refactoring.

## Goal
Zero duplicated format helpers across controllers. Every controller uses the shared ProtoJSON module.

## Scope Check
- Does this issue touch more than 3 controllers? Yes (7 controllers). Acceptable because each change is mechanical (replace format call).
- Does this issue exceed ~300 lines of production code? ~200 lines modified (net reduction).

## Wiring
- [x] This issue is implementation only.

## Technical Requirements

### Controllers to migrate

| Controller | Helpers to remove | Replace with |
|-----------|------------------|-------------|
| `book_controller.ex` | `format_book/1,2`, `format_author/1`, `format_edition/1`, `format_placement_or_nil/1` | `ProtoJSON.book/2`, `ProtoJSON.author/1`, `ProtoJSON.edition/1` |
| `bookshelf_controller.ex` | `format_placement/1`, `format_author/1`, `format_edition/1` | `ProtoJSON.placement/2`, `ProtoJSON.book/2` |
| `bookshelf_placement_controller.ex` | `format_placement/1` | `ProtoJSON.placement/2` |
| `search_controller.ex` | `format_book/1`, `format_edition/1` | `ProtoJSON.book/2` |
| `catalogue_controller.ex` | `format_catalogue_book/1`, `format_author/1`, `format_edition/1` | `ProtoJSON.book/2` |
| `blog_controller.ex` | `format_post/1`, `serialize_association/2` | `ProtoJSON.blog_post/1` |
| `upload_controller.ex` | Inline map construction in `render_status/3` | `ProtoJSON.poll_response/1` |

### Critical constraint
The JSON output shape must NOT change. Every existing Elm decoder and E2E test must continue to pass without modification.

### Drift fixes applied during migration
- `catalogue_controller.ex` `format_author/1` returns only `{id, name}` → ProtoJSON adds `bio`, `website` (backward-compatible, Elm uses `Decode.maybe`)
- `search_controller.ex` `format_book/1` omits `description` and `subjects` → ProtoJSON includes them (backward-compatible)
- These additions are safe because Elm decoders use `oneOf`/`maybe` for optional fields

## Definition of Done
- [ ] All 7 controllers use `ProtoJSON.*` calls
- [ ] No `format_book`, `format_edition`, `format_author`, `format_placement` private functions remain in controllers
- [ ] All 1394+ Elixir tests pass
- [ ] All 170 E2E tests pass
- [ ] All 329 Elm tests pass
- [ ] `mix credo --strict` passes

## Dependencies
- #131d (ProtoJSON module exists)

## Agent Assignment
elixir-agent

## Progress Notes
[Updated by agents during execution.]
