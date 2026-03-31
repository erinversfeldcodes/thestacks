# Issue #141: Groups — Content Feed

## Summary
Build the group activity feed: a chronological timeline of members' shelf activity and blog posts, scoped to a specific group and filtered by visibility rules. Covers US-11.1.5 (Group Content Feed).

## User Stories
US-11.1.5

## Goal
A group's feed page shows recent shelf placements, moves, and blog posts from group members, newest first. Items are only shown if the content's visibility permits the viewer (group-visible or platform-visible items from members).

## Scope Check
- Does this issue touch more than 3 controllers? → No — 1 new endpoint on `GroupFeedController`.
- Does this issue add more than 2 new endpoints? → No — 1 endpoint.
- Does this issue exceed ~300 lines of production code? → Query logic ~150 LOC, controller ~50 LOC, Elm feed component ~150 LOC.
- Does this issue combine unrelated concerns? → No.

## Wiring
- [x] This issue includes router wiring and is user-facing when complete.

## Technical Requirements

**`Stacks.Social.feed_for_group/3`:**
```elixir
feed_for_group(group_id, viewer_id, opts \\ [])
# opts: [limit: 20, before: datetime]
# → {:ok, [FeedItem]} | {:error, :unauthorized | :not_found}
```

`FeedItem` is a tagged union across event types:
```elixir
%{type: :placement_created, placement: Placement, book: Book, user: User, occurred_at: DateTime}
%{type: :placement_moved,   placement: Placement, book: Book, user: User, occurred_at: DateTime}
%{type: :blog_post,         post: Post,           user: User, occurred_at: DateTime}
```

**Query strategy:**
- Pull recent events from `event_log` scoped to `aggregate_type IN ["placement", "blog_post"]` and `user_id IN (group member IDs)`
- Join to relevant tables for denormalised display data
- Filter by `placement.visibility IN ["group", "platform"]` and `post.visibility IN ["group", "platform"]`
- Order by `occurred_at DESC`, limit + cursor pagination

**API endpoint:**
```
GET /api/groups/:id/feed?before=<iso8601>&limit=<n>
```
Returns `{ data: [FeedItem], next_cursor: iso8601 | null }`.

**Elm additions:**
- `Page.Groups.Detail` extended with a feed tab (members tab + feed tab)
- `Components.FeedItem` — renders a single feed entry (placement card or blog post preview)
- Infinite scroll or "Load more" pagination

## Reviewer Context
- Visibility filtering must use `Stacks.Visibility.resolve/2` — do not re-implement.
- The event_log table uses the `op` Postgres schema prefix: `from(e in "event_log", prefix: "op", ...)` or use the generated `Stacks.Events.EventLog` schema.
- Cursor pagination uses `occurred_at` as the cursor — store as ISO8601 in the response.

## Definition of Done
- [ ] `feed_for_group/3` returns items from all three types in correct order
- [ ] Items from members who have since left the group are excluded
- [ ] Visibility filtering excludes owner-only content
- [ ] API returns correct JSON shape with `next_cursor`
- [ ] Elm renders feed with load-more pagination
- [ ] Elm renders empty state when feed is empty
- [ ] Tests for query logic including visibility filtering
- [ ] `just verify` passes

## Dependencies
#138 (Groups context), #139 (Groups API), #140 (Groups Elm)

## Agent Assignment
elixir-agent (query + API), elm-agent (feed component)

## Progress Notes
