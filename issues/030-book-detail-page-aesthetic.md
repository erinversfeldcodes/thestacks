# Issue #030: Book Detail Page Aesthetic

## Summary
Implement the full visual aesthetic for the book detail page as described in US-1.4.1 — the slide-out animation from shelf, parchment-toned background, cover display, section layouts (About, What People Think, Where to Buy, The Author, My Writing), format indicators, and the "Move to Shelf" control.

## User Stories
- US-1.4.1 Open a Book's Detail Page

## Goal
The book detail page feels like pulling a book off the shelf and opening it. The visual treatment is rich, warm, and typographically elegant. Each section is clearly delineated with the platform's physical-object aesthetic. The page is a single scrollable view that invites browsing.

## Technical Requirements
- **Entry animation:** Book spine tilts forward from shelf, cover reveals, expands into detail view
- **Background:** Parchment-toned with the originating shelf's wallpaper visible as a blurred border
- **Header:** Large cover image (left-aligned), title in serif, author, ISBN, format indicators (hardcover/softcover/Kindle/e-book/audiobook as toggleable icons), aggregate rating
- **About section:** Synopsis in readable paragraph, warm cream background, generous line spacing
- **What People Think:** Per-source sentiment cards (GoodReads, Reddit, Storygraph) with colour-coded sentiment bars and outbound links
- **Where to Buy (ZAR):** Bookshop cards sorted by price, price trend sparklines in muted gold
- **The Author:** Author name, website link, RSS feed card, upcoming events
- **My Writing:** User's linked blog posts, "Add post" button
- **Move to Shelf:** Dropdown styled as wooden shelf labels
- **Format Indicators:** Row of toggleable format icons (filled = owned, outlined = not)
- All implemented in Elm
- Mobile responsive
- No `unsafe-eval` in CSP

## Definition of Done
- [ ] Book detail page layout implemented per US-1.4.1
- [ ] Entry animation (slide-out from shelf) implemented
- [ ] All sections (About, What People Think, Where to Buy, The Author, My Writing) styled
- [ ] Format indicators toggleable
- [ ] Move to Shelf dropdown functional and styled
- [ ] Mobile responsive
- [ ] Tests written and passing
- [ ] Standards compliance verified

## Dependencies
- Issue #002 (Elm MVP frontend — base page structure must exist)

## Agent Assignment
elm-agent

## Progress Notes
[Updated by agents during execution.]
