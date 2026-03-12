# Issue #012: Playwright E2E Smoke Tests — Phase 1 User Stories

## Summary

Add Playwright as a dev dependency and write browser-level smoke tests for all Phase 1 user stories. Tests use `page.route()` to intercept API calls and return canned responses — no running backend required. Executable locally (`just test-e2e`) and in CI by end of Phase 1.

## Why Playwright after elm-program-test

`elm-program-test` (Issue #011) covers `update` logic and view rendering without a browser. Playwright adds the browser layer that program tests cannot reach:

- Real file upload via the file picker (`<input type="file">`) and the browser FileList API
- Drag-and-drop file zone
- SPA client-side routing (History API, back/forward)
- CSS class rendering and visibility (`toBeVisible`, `toHaveClass`)
- The actual spinner/animation CSS (not just the element being in the DOM)

Playwright tests are intentionally few and smoke-only. Deep business logic is tested at the program test and API layers. Each Playwright test proves end-to-end browser wiring for one happy path or one critical rejection path per user story.

## Setup

### 1. Install

```bash
cd frontend
npm install --save-dev @playwright/test
npx playwright install chromium  # chromium only for CI speed
```

### 2. `frontend/playwright.config.ts`

```ts
import { defineConfig } from '@playwright/test';

export default defineConfig({
  testDir: './e2e',
  use: {
    baseURL: 'http://localhost:4001',
    headless: true,
  },
  // Start the static server before tests run (no Phoenix required).
  webServer: {
    command: 'npx serve -s . -l 4001 --no-clipboard',
    url: 'http://localhost:4001',
    reuseExistingServer: true,
    cwd: '../frontend',
  },
});
```

### 3. `justfile` recipe

```just
test-e2e:
    cd frontend && npx playwright test
```

### 4. API mocking strategy

All tests use `page.route()` to intercept Phoenix API calls. This means:

- No backend required — tests run against the static Elm build
- Canned JSON responses mirror the real API contract
- HTTP contract is verified by `apps/core/test/stacks_web/` tests — Playwright does not re-test it

Example pattern:
```ts
await page.route('/api/upload', route =>
  route.fulfill({ status: 200, body: JSON.stringify({ image_id: 'test-uuid' }) })
);
await page.route('/api/upload/test-uuid/status', route =>
  route.fulfill({ status: 200, body: JSON.stringify({ status: 'resolved', book_id: 'book-uuid' }) })
);
```

## Tests to write

### `frontend/e2e/upload.spec.ts` — US-1.1.1, US-1.1.2, US-1.1.3

**US-1.1.1 — Upload happy path**
1. Navigate to `/upload`
2. Mock `POST /api/upload` → `{ image_id: "test-uuid" }`
3. Mock `GET /api/upload/test-uuid/status` → `{ status: "resolved", book_id: "book-uuid", is_duplicate: false }`
4. Mock `GET /api/books/book-uuid` → `{ id: "book-uuid", title: "Dune", author: { name: "Frank Herbert" }, isbn: "9780441013593" }`
5. Upload a file via `page.setInputFiles()`
6. Assert spinner (`"Identifying your book..."`) appears
7. Assert confirmation card renders `"Dune"` and `"Frank Herbert"`
8. Assert `"View Book"` link is visible

**US-1.1.2 — ISBN rejection**
1. Navigate to `/upload`
2. Mock upload accepted → status `rejected`
3. Upload file
4. Assert `"Could Not Identify Book"` heading visible
5. Assert `"Try Another Photo"` and `"Enter ISBN Manually"` buttons visible
6. Assert no book is displayed

**US-1.1.3 — Not a book**
1. Navigate to `/upload`
2. Mock upload accepted → status `resolved` with no `book_id`
3. Upload file
4. Assert `"That Doesn't Look Like a Book"` heading visible
5. Assert `"Try Again"` button visible

**Duplicate detection — US-1.1.1 variant**
1. Mock status → `{ status: "resolved", book_id: "book-uuid", is_duplicate: true }`
2. Mock book fetch → book data
3. Upload file
4. Assert `"Already in Your Library"` heading visible
5. Assert shelf selector dropdown visible

**Manual ISBN entry**
1. Navigate to `/upload`
2. Click `"Enter ISBN manually instead"`
3. Assert ISBN input visible
4. Type invalid ISBN → assert error message
5. Type valid ISBN (`9780441013593`) → assert `"Look Up Book"` button enabled

### `frontend/e2e/bookshelf.spec.ts` — US-1.2.x

**Bookshelf renders books**
1. Navigate to `/bookshelves/library`
2. Mock `GET /api/bookshelves/library` → array of 3 placements with book data
3. Assert 3 spine elements (`.spine`) are visible

**Empty bookshelf**
1. Navigate to `/bookshelves/antilibrary`
2. Mock → empty array
3. Assert empty state message visible

**Navigation between bookshelves**
1. Start at `/bookshelves/library`
2. Click nav link to `Antilibrary`
3. Assert URL is `/bookshelves/antilibrary` (SPA routing — no page reload)
4. Assert page heading changes

### `frontend/e2e/search.spec.ts` — US-1.4.x

**Search returns results**
1. Navigate to `/search`
2. Mock `GET /api/search?q=dune` → 2 books
3. Type `"dune"` into search bar (debounce fires)
4. Assert 2 result cards rendered

**Search empty state**
1. Mock → empty array
2. Type query
3. Assert `"No results"` message

### `frontend/e2e/navigation.spec.ts` — routing smoke

| Test | Assert |
|------|--------|
| `/` → home renders | Page renders without 404 |
| `/upload` → upload page | Drop zone visible |
| `/bookshelves/library` → library | Library heading visible |
| `/search` → search page | Search bar visible |
| Unknown route | Not-found message visible |
| Back button | Navigates to previous page without reload |

## CI integration

Add to `.github/workflows/` (when CI is re-enabled in Phase 1E):

```yaml
- name: Build Elm
  run: cd frontend && npm run build

- name: Run Playwright tests
  run: cd frontend && npx playwright test
```

Or add `e2e` group to `scripts/ci.sh` alongside `elm`.

## Definition of Done

- [ ] `@playwright/test` installed as dev dependency in `frontend/package.json`
- [ ] `frontend/playwright.config.ts` configured with static server + chromium only
- [ ] `just test-e2e` recipe in `justfile`
- [ ] `frontend/e2e/upload.spec.ts` — all 5 tests pass (happy, ISBN rejection, not-a-book, duplicate, manual entry)
- [ ] `frontend/e2e/bookshelf.spec.ts` — all 3 tests pass
- [ ] `frontend/e2e/search.spec.ts` — all 2 tests pass
- [ ] `frontend/e2e/navigation.spec.ts` — all 5 routing tests pass
- [ ] All tests run headless in CI without a Phoenix backend
- [ ] `scripts/ci.sh` includes `e2e` group

## Dependencies

- Issue #011 (elm-program-test) complete — program tests confirm update logic is correct before Playwright tests the browser wiring
- Issue #002 (Elm frontend) complete ✅ — static build must exist for Playwright to load

## Sequencing note

Tests use `page.setInputFiles()` for file upload, which requires the `<input type="file">` to be reachable in the DOM. Verify the upload component renders the file input (even if visually hidden) after Issue #011 is complete — if it does not, a minor view change may be needed.

## Agent Assignment

- **elm-agent** for `playwright.config.ts`, test files, and `justfile` recipe
- **Reviewer**: security-agent (verify no secrets in test fixtures), elm-agent reviewer pass
