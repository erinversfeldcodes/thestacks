# Issue #131a: Write Missing Proto Messages + Fix Drift

## Summary
Create `.proto` definitions for all API types that currently lack them (User, Placement, Listing, BlogPost, Upload, API responses, Admin). Fix drift in existing `book.proto` by adding `AGE_GATED` to VisibilityTier and `bio` to Author.

## User Stories
N/A — internal architecture.

## Goal
Every JSON type served by the Phoenix API has a corresponding `.proto` message definition. These definitions become the single source of truth for field names, types, and structure.

## Scope Check
- Does this issue touch more than 3 controllers? No (proto files only).
- Does this issue add more than 2 new endpoints? No.
- Does this issue exceed ~300 lines of production code? Yes (~350 lines of .proto), but all declarative schema definitions.
- Does this issue combine unrelated concerns? No (all proto authoring).

## Wiring
- [ ] This issue includes router wiring and is user-facing when complete.
- [x] This issue is implementation only. Wired by issues #131d, #131e, #131f.

## Technical Requirements

### New proto files

**`proto/stacks/common/v1/user.proto`**
- UserRole enum (OWNER, USER)
- ProfileVisibility enum (OWNER, GROUP, PLATFORM)
- User message (id, email, display_name, role, country_code, city, consent_analytics, age_verified, profile_visibility)

**`proto/stacks/common/v1/placement.proto`**
- PlacementFormat enum (PHYSICAL, EBOOK, AUDIOBOOK)
- Placement message (id, book_id, position, placed_at, formats, personal_rating, notes, bookshelf_name)
- Imports book.proto for Book embedding in responses

**`proto/stacks/common/v1/listing.proto`**
- Condition enum (NEW, LIKE_NEW, GOOD, FAIR, POOR)
- PricingMode enum (FIXED, OFFER)
- ListingStatus enum (DRAFT, ACTIVE, SOLD, EXPIRED, REMOVED)
- Listing message (id, book_id, condition, pricing_mode, price_zar, contact_info, description, status, created_at)

**`proto/stacks/common/v1/blog.proto`**
- BlogVisibility enum (OWNER, GROUP, PLATFORM)
- AssociationStatus enum (PENDING, CONFIRMED, REJECTED)
- BookAssociation message (book_id, isbn, status, association_type, notes)
- BlogPost message (id, title, body, visibility, published, user_id, associations, inserted_at)
- BlogPostSummary message (id, title, published, visibility, inserted_at)

**`proto/stacks/common/v1/upload.proto`**
- PollStatus enum (PENDING, RESOLVED, REJECTED)
- UploadAccepted message (status, image_id)
- PollResponse message (image_id, status, book_id, book_ids, rejection_reason, is_duplicate)

**`proto/stacks/api/v1/responses.proto`**
- AuthResponse (token, user)
- BookDetailResponse (book, placement)
- BookshelfResponse (bookshelf_name, count, placements)
- CatalogueResponse (total, page, per_page, books)
- MergeFormatResponse (edition)
- PlacementResponse (placement)
- SearchResponse (query, count, results)

**`proto/stacks/api/v1/admin.proto`**
- MetricsDashboard, CostItem, SourceHealth, QualityTrends etc.

### Modifications to existing protos

**`proto/stacks/common/v1/book.proto`**
- Add `VISIBILITY_TIER_AGE_GATED = 4` to VisibilityTier enum
- Add `string bio = 5` to Author message
- Add `string format_label = 10 [json_name = "format_label"]` to Edition message (pragmatic: keeps string alongside enum for API compatibility)

### Conventions
- All messages must have full field-level comments (required by `buf lint` COMMENTS rule)
- All enums must have `_UNSPECIFIED = 0` zero value
- `json_name` annotations where field names must match current API output
- Package structure: `stacks.common.v1` for domain entities, `stacks.api.v1` for response wrappers

## Reviewer Context
- `buf lint` uses STANDARD + COMMENTS rules — every field needs a comment
- `buf breaking` uses FILE rules — additive changes only (new fields, new messages OK)
- Adding `AGE_GATED = 4` to an existing enum is additive and buf-safe
- Adding `bio = 5` to Author uses field number 5 (next available)

## Definition of Done
- [ ] All new .proto files compile with `buf build`
- [ ] `buf lint proto/` passes
- [ ] `buf breaking proto/ --against .git#branch=main` passes
- [ ] Existing Ecto codegen (`mix proto.sync --check`) still passes
- [ ] No changes to Elixir or Elm code (proto definitions only)

## Dependencies
None — can start immediately.

## Agent Assignment
protobuf-agent

## Progress Notes
[Updated by agents during execution.]
