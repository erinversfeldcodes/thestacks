# Issue #057b: Elm — Upload Verification Step

## Summary
Add a verification step to the upload flow: after identification, show the user what the system thinks the book is and let them confirm before shelf placement.

## User Stories
US-1.1.1 (upload verification + default WishList), US-1.1.5 (manual ISBN entry), US-1.1.8 (multi-format merge)

## Goal
After a book is identified, the user sees "We think this is…" with the book details and can confirm or reject before choosing a shelf.

## Technical Requirements
- `UploadStep` type: `Uploading → Verifying IdentifiedBook → ChoosingShelf → Complete`
- After identification: side-by-side — uploaded image (left) + identified book (right)
- "We think this is…" heading with book title, author, cover
- "Yes, that's it" (primary) / "No, try again" (secondary)
- After verification: shelf picker with WishList pre-selected
- After placement: "[Title] added to [Shelf]" with "Add another" / "View on shelf"
- Multi-format merge prompt: "You own [Title] as [format]. Add [new format]?"
- Manual ISBN entry fallback (input field + lookup via `GET /api/books/isbn/:isbn`)

## Scope Check
- Modify `Page.Upload` (add step state machine)
- ~250 LOC

## Dependencies
#057a (overlay pattern for consistent UI)

## Definition of Done
- [ ] Upload shows verification step before shelf selection
- [ ] Default shelf is WishList; all 5 shelves available
- [ ] Multi-format merge prompt appears when duplicate detected
- [ ] Manual ISBN entry works as fallback
- [ ] `elm-format --validate src/` passes

## Agent Assignment
elm-agent
