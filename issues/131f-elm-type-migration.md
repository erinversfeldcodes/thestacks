# Issue #131f: Migrate Elm App to Generated Proto Decoders

## Summary
Replace hand-written `Types/*.elm` modules with thin adapters over generated proto decoders. Update `Api.elm` to use generated response types.

## User Stories
N/A — internal refactoring.

## Goal
The Elm app's type system derives from `.proto` definitions. Hand-written `Types/Book.elm` etc. become adapters that re-export generated types, bridging any shape differences.

## Scope Check
- Does this issue touch more than 3 controllers? No (Elm only).
- Does this issue exceed ~300 lines of production code? ~400 lines modified across Elm.
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
