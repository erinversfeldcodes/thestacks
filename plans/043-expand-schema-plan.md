# Plan: Expand Schema — Social, Blog, Marketplace Tables
**Issue**: #043
**Created**: 2026-03-19
**Status**: Draft

## Context

All Phase 1 tables for social graph, blog, marketplace, and health monitoring must exist before Phase 1B contexts can be written. Issue #042 (works/editions) is confirmed complete. This issue creates the remaining tables in one migration wave, plus stub Ecto schemas (no context logic yet).

## Research Summary

- Migration pattern: `prefix: "op"`, `primary_key: false` + explicit UUID, enums via `DO $$ BEGIN CREATE TYPE ... EXCEPTION WHEN duplicate_object THEN NULL; END $$;`, FK with `type: :binary_id, prefix: "op"`, dbt role grants per table via two-arg `execute/2`.
- Ecto schema pattern: `@primary_key`, `@foreign_key_type`, `@schema_prefix`, `@derive Jason.Encoder`, `@type t`, changesets with `@required_fields`/`@optional_fields`, `validate_inclusion` for enum fields.
- Test pattern: `use Core.DataCase, async: true`, ExMachina factories, changeset unit tests + DB constraint smoke tests.
- 5 factory entries already in `test/support/factory.ex`; new ones needed for each new schema.

## Scope

**Tables to create (12):**
1. `op.user_blocks`
2. `op.groups`
3. `op.group_members`
4. `op.group_invitations`
5. `op.visibility_grants`
6. `op.blog_posts`
7. `op.post_book_associations`
8. `op.offer_threads`
9. `op.offer_messages`
10. `op.listings`
11. `op.transactions`
12. `op.source_health_checks`

**Column additions to existing tables:**
- `users`: 5 notification/onboarding boolean columns
- `discovered_sources`: `'excluded'` enum value, `excluded_at`, `exclusion_email`
- `third_spaces`: `opted_out`, `opted_out_at`

**Ecto schemas (stub, no context logic):**
- `Stacks.Social.UserBlock`, `Group`, `GroupMember`, `GroupInvitation`, `VisibilityGrant`
- `Stacks.Blog.Post`, `PostBookAssociation`
- `Stacks.Marketplace.OfferThread`, `OfferMessage`, `Listing`, `Transaction`
- `Stacks.Monitoring.SourceHealthCheck`

## Approach Options

- **Option A (chosen): Four focused migration files.** Group by domain: (1) alter existing tables, (2) social tables, (3) blog tables, (4) marketplace + monitoring tables. Keeps rollback scoped and readable.
- **Option B: One monolith migration.** Single file is harder to reason about on rollback. Not recommended.
- **Option C: One file per table.** 12+ migration files is noisy. Not recommended.

## Phases

### Phase 1: Schema Expansion (single phase)
**Objective**: Create all 12 new tables, alter 3 existing tables, write stub Ecto schemas, write factory entries, write constraint smoke tests. No context logic.
**Agent(s)**: database-agent (migrations + Ecto schemas + factories + tests)

**Migration files:**
1. `20260319000002_expand_users_discovered_sources_third_spaces.exs`
2. `20260319000003_create_social_tables.exs` — user_blocks, groups, group_members, group_invitations, visibility_grants
3. `20260319000004_create_blog_tables.exs` — blog_posts, post_book_associations
4. `20260319000005_create_marketplace_and_monitoring_tables.exs` — offer_threads, offer_messages, listings, transactions, source_health_checks

**Ecto schema directories:**
- `apps/core/lib/stacks/social/` (5 schemas + stub context `social.ex`)
- `apps/core/lib/stacks/blog/` (2 schemas + stub context `blog.ex`)
- `apps/core/lib/stacks/marketplace/` (4 schemas + stub context `marketplace.ex`)
- `apps/core/lib/stacks/monitoring/` (1 schema + stub context `monitoring.ex`)

**Test steps:**
1. Write factory entries for each new schema in `test/support/factory.ex`
2. Write schema changeset tests + DB constraint smoke tests
3. Tests fail (schemas/tables don't exist yet)
4. Run migrations, create schema modules
5. Tests pass

**Test Command**: `mix test apps/core/test/stacks/social/ apps/core/test/stacks/blog/ apps/core/test/stacks/marketplace/ apps/core/test/stacks/monitoring/`
**Full suite**: `mix test`

**DoD Items**:
- [ ] 4 migration files run without error (forward)
- [ ] `mix ecto.rollback --all && mix ecto.migrate` succeeds
- [ ] All 12 new Ecto schemas compile
- [ ] `users`, `discovered_sources`, `third_spaces` alterations applied
- [ ] Unique constraints verified (user_blocks, group_members, visibility_grants, offer_threads)
- [ ] Factory entries for all new schemas in `test/support/factory.ex`
- [ ] Schema changeset tests pass
- [ ] No existing tests broken (`mix test` passes)
- [ ] `mix credo --strict` passes

**E2E gate**: Skipped — additive schema only, no user-facing behaviour changed.

## Open Questions

None. Research confirmed all column specs against tech-arch section 7. Following issue file specification for offer_messages (type enum + amount_cents approach) over separate offers table in tech-arch — that split can be revisited in #052 marketplace context if needed.

## Integration Handoffs

- #044 immediately follows: needs all new tables to exist for dbt staging models and RLS design
- #046 (Books context): needs `post_book_associations.book_id` FK to `books`
- #047 (Visibility): needs `user_blocks`, `groups`, `group_members`, `visibility_grants`
- #053 (Blog backend): needs `blog_posts`, `post_book_associations`
- #068 (Source health monitoring): needs `source_health_checks`
