# Issue #044: dbt Staging Models Expansion + RLS Design

## Summary
Create dbt staging models for all new tables from Issues #042 and #043. Write the RLS policy design document (`docs/rls-design.md`) specifying row-level security policies for all user-data tables.

## User Stories
Cross-cutting — supports all Phase 1 stories that touch user data.

## Goal
Every operational table has a corresponding dbt staging model. RLS policies are designed, documented, and ready to be enabled after visibility infrastructure (Issue #047) is built.

## Technical Requirements

**New dbt staging models:**
- `stg_book_editions` — join to `stg_books` via `book_id`
- `stg_user_blocks`
- `stg_groups`, `stg_group_members`, `stg_group_invitations`
- `stg_visibility_grants`
- `stg_blog_posts`, `stg_post_book_associations`
- `stg_offer_threads`, `stg_offer_messages`
- `stg_listings`, `stg_transactions`
- `stg_event_log` (if not already present)
- `stg_partners`, `stg_partner_inventory`, `stg_partner_events`, `stg_partner_spaces` (tables exist from earlier migrations)
- Update `sources.yml` and `schema.yml` with all new sources
- Add `dbt-assertions` row-level checks for new staging models: `stg_book_editions` ISBN is 10 or 13 digits, `stg_listings` price > 0, `stg_blog_posts` visibility is valid enum

**RLS design document — `docs/rls-design.md`:**
- Policy per table: who can SELECT, INSERT, UPDATE, DELETE
- `bookshelf_placements`: owner can CRUD their own; platform users can SELECT where visibility allows
- `blog_posts`: owner can CRUD their own; readers can SELECT where visibility + ceiling allow
- `offer_threads` / `offer_messages`: only buyer + seller of that listing
- `listings`: owner can CRUD; platform users can SELECT active listings
- **Marketplace exception**: active listings on `looking_for_home` are visible to all platform users regardless of `users.profile_visibility`
- Document when RLS will be enabled (after Issue #047 visibility contexts pass tests)
- Include SQL for each policy (ready to paste into a migration)

## Definition of Done
- [ ] `dbt run --select staging` succeeds with all new models
- [ ] `dbt test` passes with row-level assertions on new models
- [ ] `docs/rls-design.md` exists with policies for all user-data tables
- [ ] RLS SQL is written and ready to apply (not yet applied)
- [ ] `sources.yml` lists all operational tables

## Dependencies
Issues #042, #043 (tables must exist)

## Agent Assignment
database-agent

## Progress Notes
