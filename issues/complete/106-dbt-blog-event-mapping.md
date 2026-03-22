# Issue #106: Add Blog Events to DbtRefreshHandler

## Summary
DbtRefreshHandler's `@model_mapping` is missing blog events. `blog.post_published` and `blog.post_updated` should trigger rebuild of `int_blog_engagement` and `mart_blog_activity`.

## Scope Check
- 2 lines added to `@model_mapping`
- 2 entries added to Events.Registry
- ~5 min

## Technical Requirements
- Add to `@model_mapping` in `dbt_refresh_handler.ex`:
  ```
  "blog.post_published" => ["int_blog_engagement", "mart_blog_activity"]
  "blog.post_updated" => ["int_blog_engagement", "mart_blog_activity"]
  ```
- Register `DbtRefreshHandler` for `blog.post_published` and `blog.post_updated` in Events.Registry
- Note: `blog.post_published` already has `BlogAssociationHandler` registered — add DbtRefreshHandler to the same list

## Definition of Done
- [ ] Blog events mapped to correct dbt models
- [ ] Registry updated
- [ ] Existing tests pass
- [ ] `just verify` passes

## Priority
Quick fix — do pre-Wave E or early Wave E

## Agent Assignment
elixir-agent
