# Phase 3 Completion: Issue #043 — Expand Schema

**Completed**: 2026-03-19
**Status**: APPROVED (second-pass review, no further revisions required)
**Tests**: 383 tests, 0 failures (34 new tests added)
**Credo**: Clean (`mix credo --strict`)
**E2E gate**: Skipped — additive schema only

---

## What Was Built

### Migrations (5 files)
| File | Content |
|------|---------|
| `20260319000002_expand_users_discovered_sources_third_spaces.exs` | 5 boolean columns to `op.users`, `opted_out*` to `op.third_spaces`, `excluded*` to `op.discovered_sources`, `ALTER TYPE op.source_status ADD VALUE 'excluded'`; `@disable_ddl_transaction true`, `@migration_lock false` |
| `20260319000003_create_social_tables.exs` | `op.user_blocks`, `op.groups`, `op.group_members`, `op.group_invitations`, `op.visibility_grants`; 4 enum types guarded |
| `20260319000004_create_blog_tables.exs` | `op.blog_posts`, `op.post_book_associations` |
| `20260319000005_create_marketplace_and_monitoring_tables.exs` | `op.offer_threads`, `op.offer_messages`, `op.listings`, `op.transactions`, `op.source_health_checks`; `op.monitored_source_type` enum (renamed from erroneous `op.source_type` to avoid collision) |
| `20260319000006_fix_marketplace_monitoring_constraints.exs` | Fix migration: creates `op.monitored_source_type`, alters `transactions.buyer_id`/`seller_id` FKs to `ON DELETE SET NULL` (GDPR pattern), ensures unique index on `source_health_checks.source_name` |

### Ecto Schemas (16 modules)
- `Stacks.Social`: `UserBlock`, `Group`, `GroupMember`, `GroupInvitation`, `VisibilityGrant`, `Social` (stub context)
- `Stacks.Blog`: `Post`, `PostBookAssociation`, `Blog` (stub context)
- `Stacks.Marketplace`: `OfferThread`, `OfferMessage`, `Listing`, `Transaction`, `Marketplace` (stub context)
- `Stacks.Monitoring`: `SourceHealthCheck`, `Monitoring` (stub context)

### Updated Schemas
- `Stacks.Accounts.User` — 5 new notification/onboarding boolean fields

### Test Files (9 new + 2 updated)
- New: `user_block_test.exs`, `group_test.exs`, `group_member_test.exs`, `group_invitation_test.exs`, `visibility_grant_test.exs`, `users_notification_columns_test.exs`
- New: `post_test.exs`, `post_book_association_test.exs`
- New: `offer_thread_test.exs`, `offer_message_test.exs`, `listing_test.exs`, `transaction_test.exs`
- New: `source_health_check_test.exs` (updated with DB smoke test)
- Updated: `test/support/factory.ex` — 12 new factory entries

---

## Issues Found and Fixed During Review

| Issue | Fix |
|-------|-----|
| `@migration_lock false` missing in _000002_ | Added alongside `@disable_ddl_transaction true` |
| `op.source_type` name collision with `discovered_sources` | Renamed to `op.monitored_source_type` |
| `transactions.buyer_id`/`seller_id` `on_delete: :nothing` | Changed to `on_delete: :nilify_all` (GDPR erasure) via migration _000006_ |
| Soft `offer_id` FK undocumented | Added comment explaining intent; deferred hard FK to #052 |
| `down/0` silent on irreversible `ALTER TYPE ADD VALUE` | Added explanatory comment |
| Missing tests: `GroupInvitation`, `OfferThread`, `OfferMessage`, `Transaction` | 4 new test files written |
| `SourceHealthCheck` missing DB smoke test | Added unique constraint smoke test |
| `Transaction.changeset` used `validate_change` for `:shipping_status` | Replaced with `validate_inclusion` |
| `unique_constraint` missing from `SourceHealthCheck` schema | Added `unique_constraint(:source_name)` |

---

## Integration Handoffs

- **#044** (RLS design + dbt staging for new tables) — all tables now exist; can proceed
- **#046** (Books context) — `post_book_associations.book_id` FK to `books` ready
- **#047** (Visibility context) — `user_blocks`, `groups`, `group_members`, `visibility_grants` ready
- **#053** (Blog backend) — `blog_posts`, `post_book_associations` ready
- **#068** (Source health monitoring) — `source_health_checks` ready
