# Issue #130: Upload Pipeline Playwright Tests (Suite 1)

## Summary
Write Playwright UI tests for the upload pipeline covering all 8 user stories (US-1.1.1 through US-1.1.8), using `data-testid` selectors from Issue #108.

## User Stories
- US-1.1.1 Upload a Photo to Add a Book
- US-1.1.2 ISBN Hard Gate — Book Rejection
- US-1.1.3 Non-Book Image Rejection
- US-1.1.4 Age-Gated Content Flagging
- US-1.1.5 Manual ISBN Entry
- US-1.1.6 Duplicate Book Detection
- US-1.1.7 Bulk Upload (multi-book from single image)
- US-1.1.8 Multi-Format Book Merging

## Goal
Suite 1 of Issue #111 is complete. All upload UI flows are tested end-to-end in the browser, using resilient `data-testid` selectors.

## Scope Check
- Does this issue touch more than 3 controllers? No (test files only).
- Does this issue add more than 2 new endpoints? No.
- Does this issue exceed ~300 lines of production code? No (test files only).
- Does this issue combine unrelated concerns? No (all upload pipeline UI).

## Wiring
- [ ] This issue includes router wiring and is user-facing when complete.
- [x] This issue is implementation only. Wired by issue #111 (E2E upload pipeline).

## Technical Requirements

### Test cases (from Issue #111 Suite 1 spec)

**Happy paths:**
- Single photo upload (drag-and-drop): drop → processing → verify → shelf pick → success → navigate
- File picker upload: click → select → same flow
- Shelf selection: verify 5 shelves, WishList pre-selected, change selection

**Sad paths:**
- Upload HTTP failure (500) → error message → retry
- Poll timeout (150 polls) → "Could Not Identify" → manual ISBN / retry
- ISBN not found (hard gate) → rejection message → manual ISBN / retry
- Non-book rejection → "Doesn't Look Like a Book" → retry
- Placement API failure (422) → error → retry
- Unauthenticated → "Sign in" prompt

**Manual ISBN entry (US-1.1.5):**
- Invalid ISBN (bad checksum) → red border + error
- Valid ISBN-10 and ISBN-13 accepted
- API returns book → verify view
- API returns 404 → "Book not found"
- Entry from rejection flow

**Duplicate detection (US-1.1.6):**
- "Already in Your Library" heading
- "Yes, merge" / "No, add as separate" / "View Book" / "Go Back" buttons
- Each button's outcome

**Multi-format merge (US-1.1.8):**
- Merge success → "N editions" view
- Merge failure → retry

**Multi-book extraction (US-1.1.7):**
- Multiple books rendered in verification
- Individual "View Book" links

**ARIA and accessibility:**
- `aria-live="polite"` on status region
- `role="status"` on loading/identified/complete views
- Drop zone keyboard-accessible

### Selector strategy
- All selectors use `data-testid` attributes (from #108)
- Example: `[data-testid="upload-drop-zone"]`, `[data-testid="upload-verify-title"]`
- NO CSS class selectors for test assertions

### API mocking
- Use Playwright `page.route()` to mock vision API poll responses
- Mock different `StatusReceived` payloads for each scenario

## Reviewer Context
- Existing E2E tests in `e2e/tests/` use CSS class selectors — this issue uses `data-testid` exclusively
- The upload page is at `/upload`, requires authentication
- Book detail opens as an overlay (not a full page route)
- `data-testid` attributes are added by Issue #108

## Definition of Done
- [ ] All happy path tests pass
- [ ] All sad path tests pass
- [ ] Manual ISBN entry tests pass
- [ ] Duplicate detection tests pass
- [ ] Multi-format merge tests pass
- [ ] Multi-book extraction tests pass
- [ ] ARIA assertions pass
- [ ] All selectors use `data-testid` (zero CSS class selectors)
- [ ] `npx playwright test` passes
- [ ] `just verify` passes

## Dependencies
- #108 (data-testid migration) — **must be merged first**
- #111 (backend test suites — complete)

## Agent Assignment
playwright-agent

## Progress Notes
[Updated by agents during execution.]
