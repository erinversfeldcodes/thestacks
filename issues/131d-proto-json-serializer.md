# Issue #131d: Create Shared ProtoJSON Serializer Module

## Summary
Create `StacksWeb.ProtoJSON` — a shared module that renders Ecto structs as proto-shaped JSON, replacing the duplicated `format_book/format_edition/format_author` helpers scattered across 5+ controllers.

## User Stories
N/A — internal refactoring.

## Goal
One module, one source of truth for how domain entities are serialized to JSON. The JSON output matches the `.proto` message shapes exactly.

## Scope Check
- Does this issue touch more than 3 controllers? No (new module only, controllers migrated in #131e).
- Does this issue exceed ~300 lines of production code? ~200 lines.

## Wiring
- [x] This issue is implementation only. Wired by #131e.

## Technical Requirements

### Module: `apps/core/lib/stacks_web/proto_json.ex`

Functions for each domain entity:
- `book(book_struct, opts)` → map matching `stacks.common.v1.Book` + computed fields (editions, primary_edition, edition_count, community_read_count)
- `author(author_struct)` → map matching `stacks.common.v1.Author` (id, name, bio, website)
- `edition(edition_struct)` → map matching `stacks.common.v1.Edition` (id, isbn, format_label, cover_image_url, page_count, publisher, publication_year, is_primary)
- `placement(placement_struct, opts)` → map matching `stacks.common.v1.Placement`
- `listing(listing_struct)` → map matching `stacks.common.v1.Listing`
- `blog_post(post_struct)` → map matching `stacks.common.v1.BlogPost`
- `user(user_struct)` → map matching `stacks.common.v1.User`
- `poll_response(attrs)` → map matching `stacks.common.v1.PollResponse`

### Enum serialization
- Enums output as lowercase strings: `"public"`, `"age_gated"`, `"hardcover"`, etc.
- NOT proto-convention SCREAMING_SNAKE_CASE — matches current API output and Elm decoder expectations

### Golden snapshot tests
Create `apps/core/test/stacks_web/proto_json_test.exs`:
- For each serializer function, capture the CURRENT controller output as the expected shape
- Verify ProtoJSON produces identical output
- This ensures #131e (controller migration) is safe

### Key reconciliation decisions
- `Edition.format_label` stays as string (not enum) in JSON output
- `Author.bio` always included (some controllers currently omit it)
- `visibility_tier` always included (some controllers currently omit it)
- Nil/missing optional fields rendered as `null` (matching current behavior)

## Definition of Done
- [ ] `StacksWeb.ProtoJSON` module with functions for all domain entities
- [ ] Golden snapshot tests verify output matches current controller output
- [ ] `mix test test/stacks_web/proto_json_test.exs` passes
- [ ] `mix credo --strict` passes

## Dependencies
- #131a (proto definitions exist as the reference contract)

## Agent Assignment
elixir-agent

## Progress Notes
[Updated by agents during execution.]
