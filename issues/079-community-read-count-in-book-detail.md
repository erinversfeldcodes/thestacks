# Issue #079: Community Read Count in Book Detail

## Summary
`Books.get_book_detail/1` was specified in Issue #046 to return a community read count sourced from `wh.mart_community_read_count`, with a graceful fallback if the mart doesn't exist yet. This was not implemented. The `GET /api/books/:id` response is missing the `community_read_count` field.

## User Stories
US-18.1.1 (book detail overlay — community engagement data)

## Goal
`get_book_detail/1` returns a `community_read_count` integer on the book struct (or a merged map returned to the controller). If the `wh` schema or `mart_community_read_count` view does not yet exist, it falls back gracefully to `0` rather than raising.

## Technical Requirements

**`Books.get_book_detail/1`:**
- After fetching the book, issue a second query against `wh.mart_community_read_count` filtered by `book_id`
- Wrap in a `try/rescue` or use `Repo.one/2` with a fallback — if the table/view doesn't exist (Postgrex `UndefinedTableError`) or returns nil, use `0`
- Return value: augment the book struct or return `{book, community_read_count}` — use whatever shape the controller/view already expects; prefer adding a virtual field to `Book` if the struct is used directly

**`BookController.show/2`:**
- Include `community_read_count` in the JSON response alongside the existing `book` fields

**`BookView` / JSON rendering:**
- Add `"community_read_count"` key to the book JSON

**dbt mart (not in scope here):** `wh.mart_community_read_count` is a dbt model that will be built separately. This issue only needs the graceful consumer side. The fallback to 0 must not break if the mart is absent.

## Definition of Done
- [ ] `GET /api/books/:id` response includes `"community_read_count": <integer>`
- [ ] Returns `0` gracefully when `wh.mart_community_read_count` does not exist
- [ ] `BookControllerTest` asserts `community_read_count` is present and is an integer
- [ ] `mix test` passes, `mix credo --strict` clean

## Dependencies
Issue #046 (get_book_detail/1 must exist — complete). `wh.mart_community_read_count` dbt model is a soft dependency (graceful fallback required when absent).

## Agent Assignment
elixir-agent

## Progress Notes

**2026-03-19 — Complete. All gates passed.**

- `Books.community_read_count/1` added with `rescue _ -> 0` fallback for missing mart
- `GET /api/books/:id` response now includes `"community_read_count": <integer>`
- `format_book/2` accepts optional second arg (default 0) — no change to other callers
- `BookControllerTest` asserts `community_read_count` is an integer
- 542 tests, 0 failures; Credo clean
