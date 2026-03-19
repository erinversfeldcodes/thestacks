# ADR 005: Book Detail as Overlay, Not a Routed Page

**Status:** Accepted
**Date:** 2026-03-17
**Deciders:** Platform owner
**Technical area:** Frontend UX, routing

---

## Context

When a user clicks a book spine on the shelf, they need to see detailed information: cover image, editions list, reviews, prices per edition per store, author card, reading history, and shelf management actions (move, remove, format picker).

Two implementation approaches were considered:

**Option A — Routed page (`/books/:id`):**
- Clicking a spine navigates to a new URL (`/books/abc-123`).
- Back button returns to the shelf.
- Standard SPA routing pattern.

**Option B — Overlay (modal) over the shelf:**
- Clicking a spine opens a detail panel over the current shelf view.
- The URL does not change.
- The shelf remains visible (dimmed) beneath the overlay.
- Dismissable via X button, click-outside, or Escape key.

**Key UX considerations:**

1. **Spatial context:** The shelf is the user's visual mental model. A book lives *on* a shelf. Opening a full-page route breaks the spatial relationship — the user "leaves" the shelf to look at a book and must navigate back. An overlay preserves the sense that you're inspecting something from where it sits.

2. **Back button semantics:** With a routed page, the back button works as expected but creates a navigation stack item. With an overlay, there is no navigation — closing the overlay is an in-place action. Both are acceptable, but the overlay avoids the edge case where the user navigates forward from the detail page and then tries to go back multiple steps.

3. **Multi-book workflow:** The reading pile and shelf browsing workflows often involve quick-checking multiple books. Overlay opens and closes without page transitions, enabling faster multi-book inspection.

4. **Search results context:** When opening a book from search results, the overlay preserves the search results page behind it. A routed page would require the user to re-enter their search query after viewing the detail.

**Implementation note (2026-03-17):** This decision replaced the earlier plan for a routed `/books/:id` page. The Elm model stores `Maybe BookDetailOverlay` — `Nothing` when closed, `Just overlay_data` when open.

---

## Decision

**Book detail is a `Maybe BookDetailOverlay` in the Elm model — an overlay that opens on top of the current page. The URL does not change when the overlay opens.**

**Elm model shape:**
```elm
type alias Model =
    { bookDetailOverlay : Maybe BookDetailOverlay
    -- ... other model fields
    }

type alias BookDetailOverlay =
    { book : Book
    , editions : RemoteData Http.Error (List Edition)
    , prices : RemoteData Http.Error (List PriceInfo)
    , reviews : RemoteData Http.Error ReviewSummary
    }
```

**Opening the overlay:** Any spine click, search result click, or "View book" CTA enqueues a `Cmd` to fetch book data and sets `bookDetailOverlay = Just { book = clickedBook, ... }` with `RemoteData.Loading` for enrichment fields.

**Closing the overlay:**
- Click the X button → `Msg.CloseBookDetail`
- Click outside the overlay panel → `Msg.CloseBookDetail`
- Press Escape key → `Msg.CloseBookDetail`
- (Overlay is dismissed via the `keydown` subscription in `Main.elm`)

**Accessibility:** Focus is trapped within the overlay while open (US-19.1.1). When the overlay closes, focus returns to the spine or element that triggered it.

**Content loaded in overlay:**
- Cover image, title, author
- Editions list with per-edition format badges
- Price info per edition per store (stub → real in Wave 2)
- Review summary (stub → real in Wave 2)
- Author card (stub → real in Wave 2)
- Shelf mover (all 5 shelves)
- Format picker (creates new editions via US-1.1.8)
- Remove action (opens confirmation modal)

---

## Consequences

**Positive:**
- Spatial context preserved — the shelf is visible behind the overlay.
- No browser history pollution — back button on the shelf goes to the previous page, not back through a book detail view.
- Faster multi-book browsing — no page transitions between opening different books.
- Search result context preserved — closing the overlay returns to the search page with results intact.

**Negative:**
- The overlay URL does not change — users cannot share a link to a specific book's detail view directly. Acceptable for Phase 1 (single-user + close friends context). A shareable URL (`/books/:id`) can be added alongside the overlay in a future phase if social sharing becomes a priority.
- Deep linking to a book detail view from an external source (email notification, partner referral) is not possible without a separate route. Mitigation: notification emails link to the shelf, not a specific book overlay.
- Screen readers must be explicitly handled — `aria-modal="true"`, `role="dialog"`, and focus trapping are required to ensure the overlay is accessible. This is not optional — see US-19.1.1.

**Not a constraint:**
- A routed `/books/:id` page can coexist with the overlay in a future phase for shareable links and deep links from email. The overlay pattern and the routed pattern are not mutually exclusive — the overlay would be the preferred in-app interaction; the route would be the canonical URL for linking.
