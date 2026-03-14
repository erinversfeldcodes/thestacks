# Issue #033: Global Book Catalogue — Browse All Books

## Summary
Add a page where any user can browse all books in the system regardless of who uploaded them. No indication of whose shelf a book is on — purely a discovery and exploration view. Users can find titles they recognise and add them to their own shelves.

## User Stories
No existing user story covers this — #026 may produce one. This issue describes the feature directly.

## Goal
A browsable catalogue of every book in the system, presented as a discovery tool. Users can explore titles, be reminded of books they've read or want to read, and add any book to their own shelf. Privacy is maintained: no ownership information is visible.

## Technical Requirements
- **Backend (Elixir):**
  - API endpoint: `GET /api/catalogue` returning paginated book metadata (title, author, cover image URL, ISBN, page count, subjects/genres)
  - No ownership data in the response — no user IDs, no shelf names, no placement data
  - Query supports: search (title/author), filter by genre/subject, sort by title/author/date added to system
  - Age-gated books: included in catalogue but detail pages still require age verification (US-4.2)
  - Requires authentication (user must be logged in to browse)
- **Frontend (Elm):**
  - Route: `/catalogue` or `/explore`
  - Display: grid or list of book cards showing cover thumbnail, title, author, ISBN
  - Search bar with instant local filtering (if dataset is small) or API-backed search
  - Filter chips for genre/subject
  - Sort options: title A–Z, author A–Z, recently added
  - Click a book → navigates to the standard book detail page (US-1.4.1)
  - "Add to my shelf" action on each book card — opens shelf picker, creates a placement for the current user
  - Duplicate detection: if the user already has this book, show "Already on your [Shelf Name]" instead of the add button
  - Aesthetic: consistent with the platform's warm, typographic style. Could use a "library catalogue" metaphor — card catalogue drawers, index cards
- **Privacy guarantees:**
  - The API must never return which users own a book or how many users own it
  - No aggregate ownership counts (avoid "47 people have this book" — that's not the vibe)
  - Book metadata is not considered personal data (it's public ISBN-resolved data)
- Dependencies: Books context from #001, Elm frontend from #002

## Definition of Done
- [ ] Backend API endpoint returning paginated book catalogue without ownership data
- [ ] Search, filter, and sort functionality
- [ ] Elm page rendering book catalogue at designated route
- [ ] "Add to my shelf" action with shelf picker
- [ ] Duplicate detection ("Already on your shelf")
- [ ] Age-gated books handled correctly (visible in catalogue, gated on detail)
- [ ] No ownership data exposed in API response or UI
- [ ] Mobile responsive
- [ ] Tests written and passing
- [ ] Standards compliance verified

## Dependencies
- Issue #001 (Elixir MVP — Books context must exist)
- Issue #002 (Elm MVP — frontend SPA must exist)

## Agent Assignment
elixir-agent (backend), elm-agent (frontend)

## Progress Notes
[Updated by agents during execution.]
