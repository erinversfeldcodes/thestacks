# Issue #131f: Migrate Elm App to Generated Proto Decoders

## Summary
Replace hand-written `Types/*.elm` modules with thin adapters over generated proto decoders. Update `Api.elm` to use generated response types.

## User Stories
N/A — internal refactoring.

## Goal
The Elm app's type system derives from `.proto` definitions. Hand-written `Types/Book.elm` etc. become adapters that re-export generated types, bridging any shape differences.

## Scope Check
- Does this issue touch more than 3 controllers? No (Elm only).
- Does this issue exceed ~300 lines of production code? Yes — 40+ files, ~800 LOC. Justified: all changes are mechanical type/enum renames.
- Does this issue combine unrelated concerns? No (all Elm type migration).

## Wiring
- [x] This issue is implementation only.

## Technical Requirements

### Adapter pattern
Each `Types/*.elm` module becomes a thin wrapper:

```elm
module Types.Book exposing (..)

import Stacks.Common.V1.Book as Proto

type alias Author = { id : String, name : String, bio : Maybe String, website : Maybe String }
type alias Book = { id : String, title : String, author : Maybe Author, ... }

-- Decoder delegates to proto decoder, then maps to app-level type
bookDecoder : Decoder Book
bookDecoder = Decode.map fromProto Proto.decodeBookDetailResponse
```

This is the safe interim step. The adapter handles mismatches like:
- Proto `Author.websiteUrl` (String) → App `Author.website` (Maybe String)
- Proto `Book.authorId` (String) → App `Book.author` (Maybe Author, embedded)
- Proto enum constructors (`VisibilityTierPublic`) → App constructors (`Public`)

### Files to migrate

| File | Strategy |
|------|----------|
| `Types/Book.elm` | Adapter over `Stacks.Common.V1.Book` + `Stacks.Api.V1.Responses` |
| `Types/Placement.elm` | Adapter over `Stacks.Common.V1.Placement` |
| `Types/Listing.elm` | Adapter over `Stacks.Common.V1.Listing` |
| `Types/BlogPost.elm` | Adapter over `Stacks.Common.V1.Blog` |
| `Types/User.elm` | Adapter over `Stacks.Common.V1.User` |
| `Types/RemoteData.elm` | No change (infrastructure, not domain) |
| `Api.elm` | Replace inline type aliases with imports from generated modules |

### Api.elm migration
- Replace inline `type alias BookDetailResponse` with import from `Stacks.Api.V1.Responses`
- Replace inline `type alias PollResponse` with import from `Stacks.Common.V1.Upload`
- Replace inline decoders with generated decoders (may need adapter wrappers for shape differences)

### ProtoDecoderTest.elm update
- Extend to cover all generated modules (Book, User, Placement, Listing, Blog, Upload)
- Round-trip tests: decode JSON → Elm type → encode → decode again

---

## Maybe-to-Zero-Value Migration Table

### Book domain (10 fields)

| Type.Field | Hand-written | Proto generated | Consumer files |
|-----------|-------------|----------------|---------------|
| Book.author | `Maybe Author` | `Author` | Types/Book.elm (authorName helper), Bookshelf/Helpers.elm, Components/BookList.elm |
| Book.description | `Maybe String` | `String` | Page/BookDetail.elm, Page/CostTransparency.elm |
| Book.primaryEdition | `Maybe Edition` | `Edition` | Types/Book.elm (bookIsbn, bookCoverImageUrl, bookPageCount helpers) |
| Edition.formatLabel | `Maybe String` | `String` | Page/Marketplace/CreateListing.elm |
| Edition.coverImageUrl | `Maybe String` | `String` | Page/BookDetail.elm |
| Edition.pageCount | `Maybe Int` | `Int` (0=unknown) | Components/Spine.elm (width calc), Bookshelf/Helpers.elm (withDefault 200) |
| Edition.publisher | `Maybe String` | `String` | Page/BookDetail.elm |
| Edition.publicationYear | `Maybe Int` | `Int` (0=unknown) | Page/BookDetail.elm |
| Author.bio | `Maybe String` | `String` | Page/BookDetail.elm |
| Author.website | `Maybe String` | `String` | Page/BookDetail.elm |

### Placement domain (5 fields)

| Type.Field | Hand-written | Proto generated | Consumer files |
|-----------|-------------|----------------|---------------|
| Placement.book | `Maybe Book` | `Book` (in PlacementDetail) | Bookshelf/Helpers.elm (3x), Components/BookList.elm (4x), ReadingPile.elm, LookingForHome.elm |
| Placement.position | `Maybe Int` | `Int` | Components/BookList.elm |
| Placement.notes | `Maybe String` | `String` | Page/BookDetail.elm |
| Placement.personalRating | `Maybe Int` | `Int` (0=unrated) | Page/BookDetail.elm, Components/BookList.elm |
| Placement.bookshelfName | `Maybe String` | `String` (in PlacementSummary/BookPlacement) | Page/BookDetail.elm, Api.elm |

### User domain (2 fields)

| Type.Field | Hand-written | Proto generated | Consumer files |
|-----------|-------------|----------------|---------------|
| User.countryCode | `Maybe String` | `String` | Page/Settings (location) |
| User.city | `Maybe String` | `String` | Page/Settings (location) |

### Listing domain (2 fields)

| Type.Field | Hand-written | Proto generated | Consumer files |
|-----------|-------------|----------------|---------------|
| Listing.description | `Maybe String` | `String` | Page/Marketplace/ListingDetail.elm, CreateListing.elm |
| Listing.createdAt | `Maybe String` | `String` | Page/Marketplace/Browse.elm |

### Blog domain (2 fields + structural changes)

| Type.Field | Hand-written | Proto generated | Change |
|-----------|-------------|----------------|--------|
| BlogPost.published | `Bool` | REMOVED (reserved) | Use `publishedAt != ""` instead |
| BlogPost.insertedAt | `String` | `createdAt` (renamed) | Update all field references |

**Total: 21 Maybe→non-Maybe fields + 2 structural changes across 40+ consumer files.**

---

## Enum Constructor Rename Table

| Enum | Hand-written | Generated | Files referencing |
|------|-------------|-----------|-------------------|
| VisibilityTier | `Public` | `VisibilityTierPublic` | BookDecoder.elm, Page/CostTransparency.elm, Page/Search.elm, Components/BookList.elm |
| VisibilityTier | `AgeGated` | `VisibilityTierAgeGated` | BookDecoder.elm |
| VisibilityTier | `Unlisted` | `VisibilityTierUnlisted` | Page/Settings/Privacy.elm |
| VisibilityTier | `Private` | `VisibilityTierPrivate` | Page/Settings/Privacy.elm |
| Visibility (Blog) | `Owner` | `BlogVisibilityOwner` | Types/BlogPost.elm, Page/Blog/Editor.elm, Page/Blog/Post.elm |
| Visibility (Blog) | `Group` | `BlogVisibilityGroup` | Types/BlogPost.elm, Page/Blog/Editor.elm |
| Visibility (Blog) | `Platform` | `BlogVisibilityPlatform` | Types/BlogPost.elm, Page/Blog/Editor.elm |
| Format (Placement) | `Physical` | `PlacementFormatPhysical` | Components/FormatPicker.elm |
| Format (Placement) | `EBook` | `PlacementFormatEbook` | Components/FormatPicker.elm |
| Format (Placement) | `Audiobook` | `PlacementFormatAudiobook` | Components/FormatPicker.elm |

**21 constructor renames across ~15 consumer files.**

---

## Consumer Files by Impact (prioritized)

**CRITICAL (enum + Maybe + structural):**
1. `Types/Book.elm` — authorName/bookIsbn/etc helpers, visibilityTierDecoder
2. `Types/Placement.elm` — placementDecoder, formatDecoder
3. `Types/BlogPost.elm` — published bool→timestamp, enum renames, decoder
4. `Types/Listing.elm` — price_zar→price_cents, enum→string, decoder
5. `Types/User.elm` — countryCode/city Maybe removal
6. `Api.elm` — 30+ decoders
7. `Components/FormatPicker.elm` — Physical/EBook/Audiobook constructors

**HIGH (Maybe pattern matching):**
8. `Page/Bookshelf/Helpers.elm` — `case p.book of Just bk` (3x)
9. `Components/BookList.elm` — `case p.book of Just bk` (4x)
10. `Page/Bookshelf/ReadingPile.elm` — `case p.book of Just bk`
11. `Page/Bookshelf/LookingForHome.elm` — `case p.book of Just book`
12. `Page/BookDetail.elm` — Maybe.andThen .bookshelfName, formats
13. `Page/Blog/Editor.elm` — Visibility enum + published bool
14. `Page/Blog/Post.elm` — Visibility enum + published bool

**TESTS:**
15. `tests/BookDecoder.elm` — Public→VisibilityTierPublic assertions
16. `tests/PlacementDecoder.elm` — Just/Nothing assertions
17. `tests/UploadTest.elm` — VisibilityTier constructor references

## Definition of Done
- [ ] All `Types/*.elm` modules are adapters over generated proto types
- [ ] `Api.elm` uses generated response type decoders
- [ ] All 329+ Elm tests pass
- [ ] All 170 E2E tests pass
- [ ] `elm make` succeeds
- [ ] `elm-review` passes (except pre-existing proto gen issue if still present)
- [ ] `elm-format` clean

## Dependencies
- #131c (generated Elm modules exist)
- #131e (controllers serve proto-shaped JSON)

## Agent Assignment
elm-agent

## Progress Notes
[Updated by agents during execution.]
