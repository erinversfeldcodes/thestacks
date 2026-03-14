# Issue #002: Implement Elm SPA frontend for MVP shelf and book management

## Summary
Build all Elm pages, components, routing, and API wiring for the MVP. Covers the full reader interface: shelf views, book detail, upload flow, search, settings, and empty states. This is Phase 1C of the consolidated roadmap.

## User Stories
- US-1.1.2 — ISBN Hard Gate (IdentificationFailed variant)
- US-1.1.3 — Non-Book Rejection (NotABook variant)
- US-1.1.5 — Manual ISBN entry with client-side checksum validation
- US-1.1.6 — Duplicate detection with view/move/close actions
- US-1.6.4 — Remove book modal with confirmation
- US-1.6.5 — Per-shelf themed empty states with CTA

## Goal
A fully navigable Elm SPA that communicates with the Phoenix API (or mocked responses) and renders all MVP views correctly. Zero runtime exceptions. All API calls use `RemoteData`. `elm make --optimize` passes with zero warnings.

## Technical Requirements

See roadmap: `plans/consolidated-roadmap.md` § Phase 1C.

**Pages:**
- `Page.Upload` — drag-and-drop / camera capture, progress, result confirmation; `IdentificationFailed`, `NotABook`, `ManualISBNEntry`, `DuplicateDetected` variants
- `Page.Shelf.Library` — dark walnut, green damask theme
- `Page.Shelf.AntiLibrary` — light oak, botanical prints theme
- `Page.Shelf.WishList` — blue-grey, watercolour florals theme
- `Page.Shelf.ReadingPile` — vertical stack, armchair background (`PileView`)
- `Page.BookDetail` — cover, metadata, review summary (stub), price info (stub), author card, shelf mover, format picker, remove action
- `Page.Search` — debounced search bar, filter panel, sort selector
- `Page.Settings.Consent` — toggle switches per consent category
- `Page.Settings.AgeVerification` — self-declaration toggle

**Components:**
- `Components.Spine` — thickness from `page_count`, wear level enum (Pristine|Softened|Cracking|WellRead|WellLoved), bookmark icon, Phase 3 partner dot (stub)
- `Components.EmptyShelf`, `ShelfMover`, `AbandonModal`, `RemoveBookModal`, `FormatPicker`
- `Components.AgeGate`, `ISBNInput` (ISBN-10/13 checksum validation), `DuplicateDetected`
- `Components.SearchBar`, `FilterPanel`, `SortSelector`, `ConsentBanner`

**Navigation & Architecture:**
- `Navigation.ShelfRouter` — URL-driven via `Browser.application`
- `Animation.SlideTransition` (adjacent shelves), `Animation.RoomTransition` (shelf vs pile)
- Swipe gesture detection via ports (mobile)
- `Types/` — `Book.elm`, `Shelf.elm`, `User.elm`, `RemoteData.elm`
- `Api.elm` — central HTTP client module; all calls use `RemoteData`
- No ports except file input interop and swipe gestures

**Constraints:**
- `elm-format` enforced — `elm-format --validate src/` must pass
- No runtime exceptions — use `RemoteData` for all API calls, handle all union type branches
- Can mock Phoenix API responses to develop in parallel with Issue #001; switch to real API before DoD sign-off
- Aesthetic: dark-academic-meets-cottage-core — walnut shelves, botanical prints, parchment textures

## Definition of Done
- [ ] `elm make src/Main.elm --optimize` passes with zero warnings
- [ ] `elm-format --validate src/` passes
- [ ] `elm-test` passes
- [ ] All 5 shelf views render with correct per-shelf themes
- [ ] Empty shelf states display correct per-shelf messages (US-1.6.5)
- [ ] Upload flow: select photo → progress → result confirmation (and all error variants)
- [ ] Manual ISBN entry with client-side checksum validation
- [ ] Duplicate detection shows existing book with view/move/close actions
- [ ] Book detail page renders all sections
- [ ] Shelf navigation with slide and room transitions
- [ ] Search with debounced input, filter panel, and sort selector
- [ ] Remove book modal shows confirmation before acting
- [ ] All API calls use `RemoteData` pattern

## Dependencies
- Issue #001 — context interfaces must be defined before final API wiring (can develop with mocked responses until then)

## Pre-work Required Before This Issue Can Start

The following gaps were identified in the Issue #001 changeset during final verification. They must be resolved before the elm-agent begins, or the Elm work will hit hard blockers mid-flight.

### 1. CORS — hard blocker
No CORS middleware exists in the Phoenix app. The browser will reject every API call from the Elm SPA. Add `Corsica` (or equivalent) to the `:api` pipeline in `core_web/router.ex` before any Elm work begins. This is a one-file change but without it nothing works.

### 2. `page_count` missing from shelf listing — `Components.Spine` goes blind
`ShelfController.format_placement/1` returns minimal book fields: `id`, `isbn`, `title`, `cover_image_url`. It does not include `page_count`. `Components.Spine` uses `page_count` to compute spine thickness — it is the primary visual element of every shelf view. Add `page_count` to the book sub-map in `ShelfController.format_placement/1` before the Spine component is built.

**File:** `apps/core/lib/stacks_web/controllers/shelf_controller.ex`

### 3. `PUT /api/settings/age_verification` route missing
`Page.Settings.AgeVerification` requires an API endpoint to toggle the `age_verified` field on the current user. No such route exists. The `age_verified` field is present on the User schema but there is no controller action or route to set it.

**Required:** Add route + controller action (can live in `AuthController` or a new `UserSettingsController`).

### 4. `PUT /api/placements/:id/formats` route missing
`Components.FormatPicker` requires an endpoint to update `formats` on a placement. `Books.update_placement_formats/2` exists in the domain layer but is not routed.

**Required:** Add route + controller action in `ShelfPlacementController`.

### 5. Async upload result — design decision needed before `Page.Upload`
`POST /api/upload` returns `{status: "accepted", image_id: image_id}` immediately (HTTP 202). The actual identification result is produced asynchronously by `IdentifyBookJob`. `Page.Upload` must show the result (or error variants) to the user — but there is no mechanism for the API to push the result back.

**Decision required:** Does `Page.Upload` poll a `GET /api/upload/:image_id/status` endpoint, or does the app use Phoenix channels / SSE? This decision determines the shape of the upload page's `Model` and `Msg` types. Resolve this before the elm-agent begins `Page.Upload`.

## Agent Assignment
- **elm-agent** (`docs/agents/elm-agent.md`)
- **Reviewer**: elm-reviewer (`docs/agents/reviewers/elm-reviewer.md`)
- **Model**: Sonnet 4.6 (TEA patterns are mechanical once types are defined)

## Progress Notes
<!-- Updated by agents during execution -->
