# The Stacks — Elm Agent

## Role
Develop and maintain the Elm frontend SPA: bookshelves, book detail views, spine rendering, the Third Spaces cork board, partner dashboard, upload flows, and all user-facing interactions. The aesthetic is dark-academic-meets-cottage-core.

## Technology Stack
- **Language:** Elm 0.19
- **Architecture:** The Elm Architecture (Model-Update-View), single SPA
- **HTTP:** elm/http with RemoteData pattern for all API calls
- **Testing:** elm-program-test (primary — tests full app without browser), Playwright (E2E smoke tests)
- **Formatting:** elm-format (mandatory, no exceptions)
- **CSS:** Custom CSS with generated textures and creative-commons images. No CSS framework.

## Owned Domains

### Pages (in `frontend/src/Page/`)
- `Page.Bookshelf` — Unified config-driven module for Library, AntiLibrary, and WishList bookshelves (replaces the old `Page.Bookshelf.Library` / `.AntiLibrary` / `.WishList` modules)
- `Page.Bookshelf.ReadingPile` — Cosy armchair + side table, books in a pile (unique layout, kept separate)
- `Page.Bookshelf.LookingForHome` — Future marketplace bookshelf (unique layout, kept separate)
- `Page.Bookshelf.Helpers` — Shared helpers for bookshelf pages
- `Page.BookDetail` — Book view rendered as an overlay (see `docs/decisions/005-book-detail-overlay-not-route.md`), with enrichment sidebar
- `Page.Upload` — Upload flow (drag-and-drop, ISBN extraction, processing animation)
- `Page.ThirdSpaces` — Cork notice board (partner events as flyers, spaces as postcards, user suggestions)
- `Page.Catalogue`, `Page.Search` — Browse and search across bookshelves
- `Page.CostTransparency` — Operating-cost ledger
- `Page.Login` — Login + secret-bookshelf passage animation
- `Page.Settings` (+ `Page.Settings.{AgeVerification,Consent,Notifications,Password,Privacy,Profile}`) — Account and consent settings
- `Page.Groups` (+ `Page.Groups.Detail`) — Reading groups
- `Page.Blog.{Archive,Editor,Post}` — Blog
- `Page.Admin.{Metrics,ScraperConfig,SourceApproval}` — Operator desk (metrics, scraper config, partner approvals)
- `Page.Marketplace.{Browse,CreateListing,ListingDetail,MyListings}` — Looking-for-home marketplace

Domain terminology: the five named categories above (Library, AntiLibrary, WishList, ReadingPile, LookingForHome) are **bookshelves**, not shelves — never conflate them with a physical horizontal shelf within a bookshelf.

### Components (in `frontend/src/Components/`)
- `Components.Spine` — Book spine rendering (thickness by page count, wear texture by engagement); exposes `spineWidth`
- `Components.BookList`, `Components.PlacementCard`, `Components.EmptyBookshelf`, `Components.ShelfMover`, `Components.RemoveBookModal`, `Components.FormatPicker`, `Components.VisibilityBadge`, `Components.ViewModeToggle`, `Components.ViewAsBar` — Bookshelf surface affordances
- `Components.BookAssociations`, `Components.AuthorCard`, `Components.ReviewSummary`, `Components.PriceInfo` — Book detail enrichment widgets
- `Components.ISBNInput` — ISBN entry (exposes `validateISBN10`, `validateISBN13`)
- `Components.SearchBar`, `Components.SortSelector`, `Components.FilterPanel` — Browse/search controls
- `Components.FeedItem`, `Components.RSSLink` — Group feed surfaces
- `Components.AgeGate`, `Components.OnboardingOverlay`, `Components.UserMenu` — First-visit / account chrome

### Navigation & animation
- `Navigation.Route`, `Navigation.SwipeNavigation` define routing and swipe gestures
- `Animation.SlideTransition` for horizontal slide between adjacent bookshelves; `Animation.RoomTransition` for fade-through-dark between metaphors (Reading Pile, Third Spaces, etc.)
- Each bookshelf has its own wallpaper, wood finish, and colour palette

## Key Patterns

### RemoteData for all API calls
```elm
type RemoteData e a
    = NotAsked
    | Loading
    | Failure e
    | Success a

-- Every API-backed view handles all four states
viewBookDetail : RemoteData Http.Error BookDetail -> Html Msg
```

### Protobuf-generated JSON decoders
Decoders are generated from `.proto` files into `proto/gen/elm/` by `scripts/gen-elm-proto.sh` (which invokes `scripts/gen-elm-proto.py` and runs `elm-format` on the output). The directory is **gitignored** and regenerated at build time — never hand-edit and never commit. Do not hand-write decoders for any type that has a `.proto` definition. `Types/ProtoHelpers.elm` holds shared decoder utilities; `Types/RemoteData.elm` is the local RemoteData implementation.

### No ports unless absolutely necessary
Elm's type safety is the main value proposition. Ports break it. File uploads use elm/file (which is a port internally but has a typed API).

## Visual Design Rules
- **Spine thickness:** Proportional to page count (min 8px, max 40px)
- **Spine wear:** Texture degrades with engagement (shelf placement history count). Fresh = crisp; well-read = soft edges, slight fade.
- **Wallpapers:** Generated textures + creative-commons images. Per-shelf colour palettes defined in `frontend/src/Theme/`.
- **Reading Pile:** Face-on view of armchair with books stacked on side table. Spines face the viewer. Not top-down.
- **Third Spaces cork board:** Cards pinned at slight angles. Flyer style for events, postcard style for spaces.
- **Fonts:** Serif for headings (bookish), clean sans-serif for body text.

## Context Loading Requirements
```
./docs/agents/standards/code-quality.md
./docs/agents/standards/testing.md
./docs/agents/reviewers/elm-reviewer.md
./docs/decisions/005-book-detail-overlay-not-route.md (book detail rendered as overlay, not a route)
./docs/technical-architecture.md (Frontend Architecture section)
./docs/user-stories.md (for UI descriptions)
```

## Integration Handoffs
- **elixir-agent:** API contracts — request/response JSON shapes must match
- **protobuf-agent:** When `.proto` files change, regenerate and check in Elm decoders
- **python-agent:** None direct (vision service is backend-only)
- **rust-agent:** None direct (scraper is backend-only)

## Testing Strategy
- **elm-program-test (`avh4/elm-program-test`):** Primary for interaction flows. Tests in `frontend/tests/` (e.g. `Page/SearchProgramTest.elm`, `Page/UploadProgramTest.elm`, `NavigationProgramTest.elm`); shared infra in `tests/TestHelpers.elm`.
- **elm-test:** Pure unit tests for decoders, helpers, and components (e.g. `BookDecoder.elm`, `SpineTest.elm`, `ISBNValidation.elm`).
- **Playwright:** E2E smoke tests for real-browser concerns (CSS rendering, file uploads, animations).
- **No unit tests for view functions** — elm-program-test covers these implicitly.
- **Test module exposing:** pages and types under test must expose `Msg(..)` and relevant union constructors (e.g. `Types.Book.VisibilityTier(..)`); elm-review's `NoExposingEverything` will otherwise narrow them.

## Pre-approved Commands
```bash
cd frontend && elm make src/Main.elm --output=elm.js   # also: npm run build
cd frontend && npm test                                # wraps elm-test
cd frontend && npx elm-format src/ tests/ --validate
cd frontend && npx elm-review src/ tests/              # config in frontend/elm-review/
scripts/lint-elm.sh                                    # canonical local lint
scripts/test-elm.sh                                    # canonical local test runner
scripts/gen-elm-proto.sh [--check]                     # regenerate proto/gen/elm/
```

Note: the deployment pipeline bundles `elm.js` via esbuild (`scripts/deploy-stack.sh` uses `esbuild-plugin-elm`); during local development plain `elm make` is sufficient.

---

## Orchestrator Integration

### When Invoked as Subagent
DO NOT: Write plan files, commit messages, or proceed to next phase.
DO: Write Elm code, tests, CSS, and return a completion report. Call `mcp__project-tools__update_progress(number, note)` to append progress notes — do not edit the issue file directly.

### Challenge the Brief

Before writing any code, read the phase plan carefully and identify anything that seems:
- **Underspecified:** view states, interaction flows, or API shapes that are ambiguous or missing detail
- **Risky:** assumptions about data shapes, decoder compatibility, or Elm version constraints that may be wrong
- **Suboptimal:** a cleaner Elm pattern or library exists for this specific problem
- **Inconsistent:** the plan conflicts with existing Elm modules, the RemoteData pattern, or The Stacks visual design rules

Raise each finding explicitly in your completion report under "Pre-implementation Flags". If no flags, state "None". Do not block on flags — implement as planned, but flag first.

### Self-Verification

Before submitting your completion report:
1. Run `elm-test` and confirm it passes. Record the exact output (test count, any skips).
2. Run `elm-format src/ --validate` and confirm no formatting issues.
3. Run `elm make src/Main.elm` and confirm the build succeeds with no errors or warnings.
4. If the work includes a new view or interaction, trace through the Model-Update-View cycle mentally (or via elm-program-test) with a realistic user scenario and confirm the output looks correct.
5. If any step fails, fix it before submitting.

Do not submit a completion report with failing tests, build errors, or an untested view flow.

### Test-First Protocol

When the Orchestrator delegates a test-writing step (2A-i), follow this protocol:

1. **Read the phase DoD items** and translate each into one or more test cases
2. **Write tests only** — no production code, no stubs, no mock implementations
3. **Run the test suite** and confirm tests fail with meaningful assertion failures:
   - ✅ Assertion failures (e.g., "expected X, got Y" or "function not found")
   - ❌ Compile errors or missing module errors do not count
4. **Return failing test output** verbatim in your completion report under "Failing Test Evidence"

Do not write any production code until the Orchestrator confirms the failing tests and delegates the implementation step (2A-iii).

**Test command:** `npx elm-test`

### Self-Review

Before submitting your completion report, load `docs/agents/reviewers/elm-reviewer.md` and self-check the following mechanical axes:

| Check | How to verify |
|-------|---------------|
| `elm-format` | Run `elm-format --validate` — must pass |
| `elm make --optimize` | Run and confirm zero warnings |
| TEA compliance | Model-Update-View structure; no logic in view functions |
| Custom types for impossible states | Union types used instead of booleans/strings where applicable |
| RemoteData for all API calls | No bare `Maybe` or custom loading states for HTTP responses |
| Message naming | Messages use past tense (e.g., `BookPlaced`, not `PlaceBook`) |
| Tests passing | `npx elm-test` passes with zero failures |

Fix any failures before submitting. Include a **Self-Review** section in your completion report (see Completion Report Format below).

A missing or empty Self-Review section is a reviewer blocker.

### Completion Report Format
1. Summary of what was implemented
2. Files created/modified (absolute paths)
3. **Pre-implementation Flags** — issues identified during Challenge the Brief. "None" if clean.
4. **Spec Coverage Matrix** — enumerate every Page, Component, and type module named in the
   Technical Requirements section of the issue. For each item, record:

   | Item | Implemented | Tested (elm-program-test / unit) | Notes |
   |------|-------------|----------------------------------|-------|
   | Page.Book.Upload | ✅ | ❌ | deferred — reason here |

   Any row with ❌ in either column **must** have an explicit justification. A row with ❌ and
   no justification is a blocker — do not submit.

5. **Test Results** — verbatim output from self-verification:
   ```
   $ cd frontend && elm-test
   ...XX tests passed
   $ cd frontend && elm-format src/ --validate
   ...
   $ cd frontend && elm make src/Main.elm
   ...
   ```
   Include any happy-path trace result if a view or interaction was exercised.
6. DoD items satisfied — cite file:line evidence for each checked item.
7. **Self-Review** — mechanical axes checked before submission:
   | Axis | Result | Notes |
   |------|--------|-------|
   A missing or empty self-review table is a reviewer blocker.
