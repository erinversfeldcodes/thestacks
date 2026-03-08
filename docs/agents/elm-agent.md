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
- `Page.Shelf.Library` — Dark walnut shelves, green damask wallpaper
- `Page.Shelf.AntiLibrary` — Lighter oak, botanical prints
- `Page.Shelf.WishList` — Blue-grey, watercolour florals
- `Page.Shelf.ReadingPile` — Cosy armchair + side table, books in a pile (face-on, spines visible)
- `Page.Shelf.LookingForHome` — Future marketplace shelf
- `Page.Book.Detail` — Full book view with enrichment sidebar (reviews, prices, author, events, partner availability)
- `Page.Book.Upload` — Upload modal (drag-and-drop, shelf selector, processing animation)
- `Page.ThirdSpaces` — Cork notice board (partner events as flyers, spaces as postcards, user suggestions)
- `Page.Metrics` — Curator's desk (operational metrics, partner requests)
- `Page.Search` — Search and sort across shelves
- `Page.Settings` — Privacy, consent, audit log
- `Page.Partner.Register` — Partner registration form
- `Page.Partner.Dashboard` — Partner inventory, events, spaces, metrics, key management
- `Page.Partner.InventoryImport` — CSV upload with preview table
- `Page.Partner.Events` — Event list + form
- `Page.Partner.Metrics` — Aggregate engagement sparklines

### Components (in `frontend/src/Components/`)
- `Components.Spine` — Book spine rendering (thickness by page count, wear texture by engagement)
- `Components.Shelf` — Horizontal shelf row with slide-in animation
- `Components.BookPile` — Face-on pile on side table (spines visible, not covers)
- `Components.CorkBoard` — Pin-board layout for third spaces
- `Components.PartnerEventCard` — Hand-lettered flyer style
- `Components.PartnerSpaceCard` — Vintage postcard style
- `Components.CommunitySpaceCard` — Handwritten style, "suggested by a reader"
- `Components.PartnerAvailability` — "Available at [Shop] for R149" sidebar widget
- `Components.UploadModal` — Parchment background, dotted border, processing states
- `Components.ConsentBanner` — First-visit consent collection

### Navigation
- Horizontal slide between adjacent shelves (Library <-> AntiLibrary <-> WishList)
- Room transition (fade through dark) for different metaphors (Reading Pile, Third Spaces, Metrics)
- Each shelf has its own wallpaper, wood finish, and colour palette

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
Decoders in `frontend/src/Api/Generated/` are checked in (generated from `.proto` files). Do not hand-write decoders for any type that has a `.proto` definition.

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
/Users/erinversfeld/thestacks/docs/agents/standards/code-quality.md
/Users/erinversfeld/thestacks/docs/agents/standards/testing.md
/Users/erinversfeld/thestacks/docs/technical-architecture.md (section 14 — Frontend Architecture)
/Users/erinversfeld/thestacks/docs/user-stories.md (for UI descriptions)
```

## Integration Handoffs
- **elixir-agent:** API contracts — request/response JSON shapes must match
- **protobuf-agent:** When `.proto` files change, regenerate and check in Elm decoders
- **python-agent:** None direct (vision sidecar is backend-only)
- **rust-agent:** None direct (scraper is backend-only)

## Testing Strategy
- **elm-program-test:** Primary. Tests full app Model-Update-View cycle without a browser. Covers user story interaction flows.
- **Playwright:** E2E smoke tests for real-browser concerns (CSS rendering, file uploads, animations). Separate, optional.
- **No unit tests for view functions** — elm-program-test covers these implicitly.

## Pre-approved Commands
```bash
cd frontend && elm make src/Main.elm
cd frontend && elm-test
cd frontend && elm-format src/ --validate
cd frontend && npx elm-program-test
cd frontend && npx playwright test
```

---

## Orchestrator Integration

### When Invoked as Subagent
DO NOT: Write plan files, commit messages, or proceed to next phase.
DO: Write Elm code, tests, CSS, and return a completion report.

### Completion Report Format
1. Summary of what was implemented
2. Files created/modified (absolute paths)
3. **Spec Coverage Matrix** — enumerate every Page, Component, and type module named in the
   Technical Requirements section of the issue. For each item, record:

   | Item | Implemented | Tested (elm-program-test / unit) | Notes |
   |------|-------------|----------------------------------|-------|
   | Page.Book.Upload | ✅ | ❌ | deferred — reason here |

   Any row with ❌ in either column **must** have an explicit justification. A row with ❌ and
   no justification is a blocker — do not submit.

4. Test commands run with **verbatim exit code**:
   ```
   $ cd frontend && elm-test
   ...XX tests passed
   $ cd frontend && elm-format src/ --validate
   ...
   ```
5. DoD items satisfied — cite file:line evidence for each checked item.
