import { test, expect, Page, Route } from "@playwright/test";
import { suiteAuthFile } from "./helpers";

test.use({ storageState: suiteAuthFile("upload") });

// ---------------------------------------------------------------------------
// Mock data factories
// ---------------------------------------------------------------------------

const FAKE_IMAGE_ID = "img-abc-123";
const FAKE_BOOK_ID = "book-001";
const FAKE_BOOK_ID_2 = "book-002";
const FAKE_BOOK_ID_3 = "book-003";

function fakeBook(overrides: Record<string, unknown> = {}) {
  return {
    id: FAKE_BOOK_ID,
    title: "The Name of the Rose",
    author: { id: "author-1", name: "Umberto Eco", bio: null, website: null },
    description: "A medieval mystery.",
    editions: [],
    primary_edition: {
      isbn: "9780151446476",
      format_label: "Hardcover",
      page_count: 502,
      publication_year: 1983,
      publisher: "Harcourt",
      cover_image_url: "/covers/rose.jpg",
    },
    edition_count: 1,
    subjects: [],
    ...overrides,
  };
}

function fakeBook2() {
  return fakeBook({
    id: FAKE_BOOK_ID_2,
    title: "Foucault's Pendulum",
    author: { id: "author-1", name: "Umberto Eco", bio: null, website: null },
    primary_edition: {
      isbn: "9780151327652",
      format_label: "Paperback",
      page_count: 623,
      publication_year: 1989,
      publisher: "Harcourt",
      cover_image_url: null,
    },
  });
}

function fakeBook3() {
  return fakeBook({
    id: FAKE_BOOK_ID_3,
    title: "Baudolino",
    author: { id: "author-1", name: "Umberto Eco", bio: null, website: null },
  });
}

function fakePlacement(bookId: string = FAKE_BOOK_ID) {
  return {
    id: "placement-1",
    book: null,
    position: null,
    placed_at: "2026-03-23T10:00:00Z",
    formats: ["physical"],
    personal_rating: null,
    notes: null,
    bookshelf_name: "wishlist",
  };
}

// ---------------------------------------------------------------------------
// Route helpers — mock API endpoints
// ---------------------------------------------------------------------------

/** Mock POST /api/upload to accept and return an image ID. */
async function mockUploadAccept(page: Page) {
  await page.route("**/api/upload", (route) => {
    if (route.request().method() === "POST") {
      route.fulfill({
        status: 200,
        contentType: "application/json",
        body: JSON.stringify({ image_id: FAKE_IMAGE_ID }),
      });
    } else {
      route.continue();
    }
  });
}

/** Mock POST /api/upload to return a 500 error. */
async function mockUploadFailure(page: Page) {
  await page.route("**/api/upload", (route) => {
    if (route.request().method() === "POST") {
      route.fulfill({
        status: 500,
        contentType: "application/json",
        body: JSON.stringify({ error: "Internal server error" }),
      });
    } else {
      route.continue();
    }
  });
}

/** Mock GET /api/upload/:id/status with a resolved single book. */
async function mockPollResolved(
  page: Page,
  opts: {
    bookId?: string;
    bookIds?: string[];
    isDuplicate?: boolean;
  } = {}
) {
  const bookId = opts.bookId ?? FAKE_BOOK_ID;
  const bookIds = opts.bookIds ?? [bookId];
  const isDuplicate = opts.isDuplicate ?? false;

  await page.route(`**/api/upload/*/status`, (route) => {
    route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify({
        image_id: FAKE_IMAGE_ID,
        status: "resolved",
        book_id: bookId,
        book_ids: bookIds,
        rejection_reason: null,
        is_duplicate: isDuplicate,
      }),
    });
  });
}

/** Mock GET /api/upload/:id/status to stay pending forever (until unrouted). */
async function mockPollPending(page: Page) {
  await page.route(`**/api/upload/*/status`, (route) => {
    route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify({
        image_id: FAKE_IMAGE_ID,
        status: "pending",
        book_id: null,
        book_ids: [],
        rejection_reason: null,
        is_duplicate: null,
      }),
    });
  });
}

/** Mock GET /api/upload/:id/status with rejected (ISBN not found). */
async function mockPollRejected(page: Page) {
  await page.route(`**/api/upload/*/status`, (route) => {
    route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify({
        image_id: FAKE_IMAGE_ID,
        status: "rejected",
        book_id: null,
        book_ids: [],
        rejection_reason: "isbn_not_found",
        is_duplicate: null,
      }),
    });
  });
}

/** Mock GET /api/upload/:id/status with resolved but no book IDs (not a book). */
async function mockPollNotABook(page: Page) {
  await page.route(`**/api/upload/*/status`, (route) => {
    route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify({
        image_id: FAKE_IMAGE_ID,
        status: "resolved",
        book_id: null,
        book_ids: [],
        rejection_reason: null,
        is_duplicate: null,
      }),
    });
  });
}

/** Mock GET /api/books/:id to return a book. */
async function mockGetBook(
  page: Page,
  bookId: string = FAKE_BOOK_ID,
  book?: Record<string, unknown>
) {
  await page.route(`**/api/books/${bookId}`, (route) => {
    if (route.request().method() === "GET") {
      route.fulfill({
        status: 200,
        contentType: "application/json",
        body: JSON.stringify({
          book: book ?? fakeBook({ id: bookId }),
          placement: null,
        }),
      });
    } else {
      route.continue();
    }
  });
}

/** Mock POST /api/bookshelves/:shelf/placements to succeed. */
async function mockPlacementSuccess(page: Page) {
  await page.route("**/api/bookshelves/*/placements", (route) => {
    if (route.request().method() === "POST") {
      route.fulfill({
        status: 201,
        contentType: "application/json",
        body: JSON.stringify({ placement: fakePlacement() }),
      });
    } else {
      route.continue();
    }
  });
}

/** Mock POST /api/bookshelves/:shelf/placements to fail (422). */
async function mockPlacementFailure(page: Page) {
  await page.route("**/api/bookshelves/*/placements", (route) => {
    if (route.request().method() === "POST") {
      route.fulfill({
        status: 422,
        contentType: "application/json",
        body: JSON.stringify({ error: "Unprocessable entity" }),
      });
    } else {
      route.continue();
    }
  });
}

/** Mock GET /api/books/isbn/:isbn to return a book. */
async function mockIsbnLookupSuccess(page: Page, isbn: string) {
  await page.route(`**/api/books/isbn/${isbn}`, (route) => {
    route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify({
        book: fakeBook(),
        placement: null,
      }),
    });
  });
}

/** Mock GET /api/books/isbn/:isbn to return 404. */
async function mockIsbnLookupNotFound(page: Page, isbn: string) {
  await page.route(`**/api/books/isbn/${isbn}`, (route) => {
    route.fulfill({
      status: 404,
      contentType: "application/json",
      body: JSON.stringify({ error: "Not found" }),
    });
  });
}

/** Mock POST /api/books/:id/merge-format to succeed. */
async function mockMergeFormatSuccess(
  page: Page,
  bookId: string = FAKE_BOOK_ID
) {
  await page.route(`**/api/books/${bookId}/merge-format`, (route) => {
    route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify({
        edition: {
          isbn: "9780151446476",
          format_label: "Paperback",
          page_count: 502,
          publication_year: 1984,
          publisher: "Harcourt",
          cover_image_url: null,
        },
      }),
    });
  });
}

/** Mock POST /api/books/:id/merge-format to fail. */
async function mockMergeFormatFailure(
  page: Page,
  bookId: string = FAKE_BOOK_ID
) {
  await page.route(`**/api/books/${bookId}/merge-format`, (route) => {
    route.fulfill({
      status: 500,
      contentType: "application/json",
      body: JSON.stringify({ error: "Merge failed" }),
    });
  });
}

// ---------------------------------------------------------------------------
// Interaction helpers
// ---------------------------------------------------------------------------

/**
 * Trigger a file upload via the file picker button.
 * Creates a synthetic 1x1 PNG buffer so Elm's File decoder is satisfied.
 */
async function triggerFileUpload(page: Page) {
  const fileChooserPromise = page.waitForEvent("filechooser");
  await page.getByRole("button", { name: "Choose Photo" }).click();
  const fileChooser = await fileChooserPromise;
  // Minimal valid PNG (1x1 transparent pixel)
  const pngBuffer = Buffer.from(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==",
    "base64"
  );
  await fileChooser.setFiles({
    name: "test-book.png",
    mimeType: "image/png",
    buffer: pngBuffer,
  });
}

/**
 * Trigger a file upload via drag-and-drop on the drop zone.
 */
async function triggerDragAndDrop(page: Page) {
  const dropZone = page.getByTestId("upload-drop-zone");
  const pngBuffer = Buffer.from(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==",
    "base64"
  );

  // Playwright does not have native DnD file support, so we dispatch
  // the events programmatically via page.evaluate. The Elm app listens
  // for the "drop" event on the drop zone and reads dataTransfer.files[0].
  const dataTransfer = await page.evaluateHandle(
    async (b64) => {
      const binary = atob(b64);
      const bytes = new Uint8Array(binary.length);
      for (let i = 0; i < binary.length; i++) {
        bytes[i] = binary.charCodeAt(i);
      }
      const file = new File([bytes], "test-book.png", { type: "image/png" });
      const dt = new DataTransfer();
      dt.items.add(file);
      return dt;
    },
    pngBuffer.toString("base64")
  );

  await dropZone.dispatchEvent("dragover", { dataTransfer });
  await dropZone.dispatchEvent("drop", { dataTransfer });
}

// ===========================================================================
// HAPPY PATHS
// ===========================================================================

test.describe("Happy paths", () => {
  test("single photo drag-and-drop: drop -> processing -> verify -> shelf pick -> success", async ({
    page,
  }) => {
    await mockUploadAccept(page);
    await mockPollResolved(page);
    await mockGetBook(page);
    await mockPlacementSuccess(page);

    await page.goto("/upload");

    // Drop a file on the drop zone
    await triggerDragAndDrop(page);

    // Processing spinner should appear
    await expect(page.getByTestId("upload-loading")).toBeVisible();
    await expect(page.getByTestId("upload-loading")).toHaveAttribute(
      "role",
      "status"
    );

    // Verification view should appear with book details
    await expect(page.getByTestId("upload-verify")).toBeVisible({
      timeout: 10_000,
    });
    await expect(page.getByTestId("upload-verify")).toContainText(
      "We think this is"
    );
    await expect(page.getByTestId("upload-verify")).toContainText(
      "The Name of the Rose"
    );
    await expect(page.getByTestId("upload-verify")).toContainText("Eco");

    // Confirm identification
    await page.getByTestId("upload-confirm-btn").click();

    // Shelf picker should appear
    await expect(page.getByTestId("upload-shelf-picker")).toBeVisible();

    // Confirm placement (defaults to Wish List)
    await page
      .getByRole("button", { name: /Add to Wish List/ })
      .click();

    // Success view
    await expect(page.getByTestId("upload-complete")).toBeVisible();
    await expect(page.getByTestId("upload-complete")).toContainText(
      "The Name of the Rose"
    );
    await expect(page.getByTestId("upload-complete")).toContainText(
      "Wish List"
    );
    await expect(page.getByTestId("upload-complete")).toHaveAttribute(
      "role",
      "status"
    );

    // "View on shelf" button should be present
    await expect(
      page.getByRole("button", { name: "View on shelf" })
    ).toBeVisible();

    // "Add another" button should be present
    await expect(
      page.getByRole("button", { name: "Add another" })
    ).toBeVisible();
  });

  test("file picker flow: click -> select -> same pipeline", async ({
    page,
  }) => {
    await mockUploadAccept(page);
    await mockPollResolved(page);
    await mockGetBook(page);
    await mockPlacementSuccess(page);

    await page.goto("/upload");

    // Use file picker
    await triggerFileUpload(page);

    // Processing -> Verification
    await expect(page.getByTestId("upload-loading")).toBeVisible();
    await expect(page.getByTestId("upload-verify")).toBeVisible({
      timeout: 10_000,
    });
    await expect(page.getByTestId("upload-verify")).toContainText(
      "The Name of the Rose"
    );

    // Confirm -> Shelf -> Complete
    await page.getByTestId("upload-confirm-btn").click();
    await expect(page.getByTestId("upload-shelf-picker")).toBeVisible();
    await page
      .getByRole("button", { name: /Add to Wish List/ })
      .click();
    await expect(page.getByTestId("upload-complete")).toBeVisible();
  });

  test("shelf selection: 5 shelves shown, Wish List pre-selected, change selection", async ({
    page,
  }) => {
    await mockUploadAccept(page);
    await mockPollResolved(page);
    await mockGetBook(page);
    await mockPlacementSuccess(page);

    await page.goto("/upload");
    await triggerFileUpload(page);

    await expect(page.getByTestId("upload-verify")).toBeVisible({
      timeout: 10_000,
    });
    await page.getByTestId("upload-confirm-btn").click();

    const shelfPicker = page.getByTestId("upload-shelf-picker");
    await expect(shelfPicker).toBeVisible();

    // All 5 shelves should be visible
    await expect(
      shelfPicker.getByRole("button", { name: "Library" })
    ).toBeVisible();
    await expect(
      shelfPicker.getByRole("button", { name: "Antilibrary" })
    ).toBeVisible();
    await expect(
      shelfPicker.getByRole("button", { name: "Wish List" })
    ).toBeVisible();
    await expect(
      shelfPicker.getByRole("button", { name: "Reading Pile" })
    ).toBeVisible();
    await expect(
      shelfPicker.getByRole("button", { name: "Looking for a Home" })
    ).toBeVisible();

    // Default confirm button says "Add to Wish List"
    await expect(
      shelfPicker.getByRole("button", { name: /Add to Wish List/ })
    ).toBeVisible();

    // Change selection to Library
    await shelfPicker
      .getByRole("button", { name: "Library", exact: true })
      .click();

    // Confirm button should update
    await expect(
      shelfPicker.getByRole("button", { name: /Add to Library/ })
    ).toBeVisible();

    // Place on Library
    await shelfPicker
      .getByRole("button", { name: /Add to Library/ })
      .click();

    await expect(page.getByTestId("upload-complete")).toBeVisible();
    await expect(page.getByTestId("upload-complete")).toContainText("Library");
  });
});

// ===========================================================================
// SAD PATHS
// ===========================================================================

test.describe("Sad paths", () => {
  test("upload HTTP failure (500) -> error -> retry", async ({ page }) => {
    await mockUploadFailure(page);

    await page.goto("/upload");
    await triggerFileUpload(page);

    // Error message should appear
    await expect(page.getByTestId("upload-error")).toBeVisible({
      timeout: 10_000,
    });
    await expect(page.getByTestId("upload-error")).toContainText(
      "Upload failed"
    );

    // "Try Again" button should be present
    await expect(
      page.getByRole("button", { name: "Try Again" })
    ).toBeVisible();

    // Click retry — should reset to initial state
    // First, switch the mock to success for the retry
    await page.unroute("**/api/upload");
    await mockUploadAccept(page);
    await mockPollResolved(page);
    await mockGetBook(page);

    await page.getByRole("button", { name: "Try Again" }).click();

    // Should be back at the upload area
    await expect(page.getByTestId("upload-drop-zone")).toBeVisible();
  });

  test("poll timeout -> Could Not Identify -> manual ISBN / retry", async ({
    page,
  }) => {
    // This test would take too long if we waited for 150 polls at 2s each.
    // Instead, we simulate the IdentificationFailed state by first responding
    // with pending, then after enough polls, the Elm app will give up.
    // For efficiency, we mock the status endpoint to return an error after
    // some polls, which triggers IdentificationFailed.
    await mockUploadAccept(page);

    // Return an error on poll to trigger IdentificationFailed immediately
    await page.route(`**/api/upload/*/status`, (route) => {
      route.fulfill({
        status: 500,
        contentType: "application/json",
        body: JSON.stringify({ error: "timeout" }),
      });
    });

    await page.goto("/upload");
    await triggerFileUpload(page);

    // Should show "Could Not Identify Book"
    await expect(page.getByTestId("upload-error")).toBeVisible({
      timeout: 15_000,
    });
    await expect(page.getByTestId("upload-error")).toContainText(
      "Could Not Identify"
    );

    // "Enter ISBN Manually" button should be present
    await expect(
      page.getByRole("button", { name: /Enter ISBN Manually/ })
    ).toBeVisible();

    // "Try Another Photo" button should also be present
    await expect(
      page.getByRole("button", { name: /Try Another Photo/ })
    ).toBeVisible();
  });

  test("ISBN not found (hard gate) -> rejection -> manual ISBN / retry", async ({
    page,
  }) => {
    await mockUploadAccept(page);
    await mockPollRejected(page);

    await page.goto("/upload");
    await triggerFileUpload(page);

    // Should show identification failed view
    await expect(page.getByTestId("upload-error")).toBeVisible({
      timeout: 10_000,
    });
    await expect(page.getByTestId("upload-error")).toContainText(
      "Could Not Identify"
    );

    // Both options available
    await expect(
      page.getByRole("button", { name: /Enter ISBN Manually/ })
    ).toBeVisible();
    await expect(
      page.getByRole("button", { name: /Try Another Photo/ })
    ).toBeVisible();
  });

  test("non-book rejection -> Doesn't Look Like a Book -> retry", async ({
    page,
  }) => {
    await mockUploadAccept(page);
    await mockPollNotABook(page);

    await page.goto("/upload");
    await triggerFileUpload(page);

    // Should show "not a book" error
    await expect(page.getByTestId("upload-error")).toBeVisible({
      timeout: 10_000,
    });
    await expect(page.getByTestId("upload-error")).toContainText(
      "Doesn't Look Like a Book"
    );

    // "Try Again" button
    await expect(
      page.getByRole("button", { name: "Try Again" })
    ).toBeVisible();
  });

  test("placement API failure (422) -> error -> retry", async ({ page }) => {
    await mockUploadAccept(page);
    await mockPollResolved(page);
    await mockGetBook(page);
    await mockPlacementFailure(page);

    await page.goto("/upload");
    await triggerFileUpload(page);

    await expect(page.getByTestId("upload-verify")).toBeVisible({
      timeout: 10_000,
    });
    await page.getByTestId("upload-confirm-btn").click();

    const shelfPicker = page.getByTestId("upload-shelf-picker");
    await expect(shelfPicker).toBeVisible();

    // Attempt placement — should fail
    await page
      .getByRole("button", { name: /Add to Wish List/ })
      .click();

    // Error message in shelf picker
    await expect(shelfPicker).toContainText("Failed to add book", {
      timeout: 10_000,
    });

    // Retry button should be available
    await expect(
      shelfPicker.getByRole("button", { name: /Add to/ })
    ).toBeVisible();

    // Switch mock to success and retry
    await page.unroute("**/api/bookshelves/*/placements");
    await mockPlacementSuccess(page);

    await shelfPicker.getByRole("button", { name: /Add to/ }).click();
    await expect(page.getByTestId("upload-complete")).toBeVisible({
      timeout: 10_000,
    });
  });

  test("unauthenticated -> Sign in prompt", async ({ browser }) => {
    // Create a fresh context without auth storage state
    const context = await browser.newContext();
    const page = await context.newPage();

    await page.goto("/upload");

    await expect(page.getByTestId("upload-auth-required")).toBeVisible();
    await expect(page.getByTestId("upload-auth-required")).toContainText(
      "sign in"
    );
    await expect(page.getByRole("link", { name: "Sign In" })).toBeVisible();

    await context.close();
  });
});

// ===========================================================================
// MANUAL ISBN ENTRY (US-1.1.5)
// ===========================================================================

test.describe("Manual ISBN entry", () => {
  test("invalid ISBN -> error message", async ({ page }) => {
    await page.goto("/upload");

    // Click "Enter ISBN manually instead"
    await page.getByRole("button", { name: /Enter ISBN manually/ }).click();

    // Manual entry view should appear
    const isbnInput = page.getByTestId("upload-manual-isbn-input");
    await expect(isbnInput).toBeVisible();

    // Type an invalid ISBN
    await isbnInput.fill("1234567890");

    // Submit
    await page.getByTestId("upload-manual-isbn-submit").click();

    // Error should appear (isbn-input--error class on the input, plus error text)
    await expect(page.getByText("Invalid ISBN checksum")).toBeVisible();
  });

  test("valid ISBN-10 accepted", async ({ page }) => {
    // Valid ISBN-10: 0306406152 (checksum valid)
    const isbn10 = "0306406152";

    await mockIsbnLookupSuccess(page, isbn10);

    await page.goto("/upload");
    await page.getByRole("button", { name: /Enter ISBN manually/ }).click();

    const isbnInput = page.getByTestId("upload-manual-isbn-input");
    await isbnInput.fill(isbn10);
    await page.getByTestId("upload-manual-isbn-submit").click();

    // Should transition to verify view
    await expect(page.getByTestId("upload-verify")).toBeVisible({
      timeout: 10_000,
    });
    await expect(page.getByTestId("upload-verify")).toContainText(
      "The Name of the Rose"
    );
  });

  test("valid ISBN-13 accepted", async ({ page }) => {
    // Valid ISBN-13: 9780306406157 (checksum valid)
    const isbn13 = "9780306406157";

    await mockIsbnLookupSuccess(page, isbn13);

    await page.goto("/upload");
    await page.getByRole("button", { name: /Enter ISBN manually/ }).click();

    const isbnInput = page.getByTestId("upload-manual-isbn-input");
    await isbnInput.fill(isbn13);
    await page.getByTestId("upload-manual-isbn-submit").click();

    // Should transition to verify view
    await expect(page.getByTestId("upload-verify")).toBeVisible({
      timeout: 10_000,
    });
    await expect(page.getByTestId("upload-verify")).toContainText(
      "The Name of the Rose"
    );
  });

  test("API returns book -> verify view", async ({ page }) => {
    const isbn = "0306406152";
    await mockIsbnLookupSuccess(page, isbn);

    await page.goto("/upload");
    await page.getByRole("button", { name: /Enter ISBN manually/ }).click();

    await page.getByTestId("upload-manual-isbn-input").fill(isbn);
    await page.getByTestId("upload-manual-isbn-submit").click();

    await expect(page.getByTestId("upload-verify")).toBeVisible({
      timeout: 10_000,
    });
    await expect(page.getByTestId("upload-verify")).toContainText(
      "We think this is"
    );
    await expect(page.getByTestId("upload-verify")).toContainText(
      "The Name of the Rose"
    );

    // Confirm and reject buttons should be available
    await expect(page.getByTestId("upload-confirm-btn")).toBeVisible();
    await expect(page.getByTestId("upload-reject-btn")).toBeVisible();
  });

  test("API returns 404 -> Book not found error", async ({ page }) => {
    const isbn = "0306406152";
    await mockIsbnLookupNotFound(page, isbn);

    await page.goto("/upload");
    await page.getByRole("button", { name: /Enter ISBN manually/ }).click();

    await page.getByTestId("upload-manual-isbn-input").fill(isbn);
    await page.getByTestId("upload-manual-isbn-submit").click();

    // Error should appear
    await expect(page.getByText("Book not found")).toBeVisible({
      timeout: 10_000,
    });
  });

  test("entry from rejection flow", async ({ page }) => {
    await mockUploadAccept(page);
    await mockPollRejected(page);

    await page.goto("/upload");
    await triggerFileUpload(page);

    // Wait for identification failed
    await expect(page.getByTestId("upload-error")).toBeVisible({
      timeout: 10_000,
    });

    // Click "Enter ISBN Manually"
    await page.getByRole("button", { name: /Enter ISBN Manually/ }).click();

    // Should be in manual entry mode
    await expect(page.getByTestId("upload-manual-isbn-input")).toBeVisible();

    // Enter a valid ISBN and look up
    const isbn = "0306406152";
    await page.unroute(`**/api/upload/*/status`);
    await mockIsbnLookupSuccess(page, isbn);

    await page.getByTestId("upload-manual-isbn-input").fill(isbn);
    await page.getByTestId("upload-manual-isbn-submit").click();

    await expect(page.getByTestId("upload-verify")).toBeVisible({
      timeout: 10_000,
    });
    await expect(page.getByTestId("upload-verify")).toContainText(
      "The Name of the Rose"
    );
  });
});

// ===========================================================================
// DUPLICATE DETECTION (US-1.1.6)
// ===========================================================================

test.describe("Duplicate detection", () => {
  async function setupDuplicateFlow(page: Page) {
    await mockUploadAccept(page);
    await mockPollResolved(page, { isDuplicate: true });
    await mockGetBook(page, FAKE_BOOK_ID, fakeBook());

    await page.goto("/upload");
    await triggerFileUpload(page);
  }

  test("Already in Your Library heading and action buttons visible", async ({
    page,
  }) => {
    await setupDuplicateFlow(page);

    // Wait for the duplicate view
    await expect(page.getByText("Already in Your Library")).toBeVisible({
      timeout: 10_000,
    });

    // All four action buttons should be present
    await expect(
      page.getByRole("button", { name: "Yes, merge" })
    ).toBeVisible();
    await expect(
      page.getByRole("button", { name: "No, add as separate" })
    ).toBeVisible();
    await expect(
      page.getByRole("link", { name: "View Book" })
    ).toBeVisible();
    await expect(
      page.getByRole("button", { name: "Go Back" })
    ).toBeVisible();
  });

  test("'No, add as separate' proceeds to shelf picker", async ({ page }) => {
    await setupDuplicateFlow(page);
    await mockPlacementSuccess(page);

    await expect(page.getByText("Already in Your Library")).toBeVisible({
      timeout: 10_000,
    });

    await page
      .getByRole("button", { name: "No, add as separate" })
      .click();

    // Should go to verify view (as a new placement)
    await expect(page.getByTestId("upload-verify")).toBeVisible();
    await expect(page.getByTestId("upload-verify")).toContainText(
      "The Name of the Rose"
    );
  });

  test("'Go Back' resets the upload flow", async ({ page }) => {
    await setupDuplicateFlow(page);

    await expect(page.getByText("Already in Your Library")).toBeVisible({
      timeout: 10_000,
    });

    await page.getByRole("button", { name: "Go Back" }).click();

    // Should return to initial upload area
    await expect(page.getByTestId("upload-drop-zone")).toBeVisible();
  });

  test("'View Book' links to book detail", async ({ page }) => {
    await setupDuplicateFlow(page);

    await expect(page.getByText("Already in Your Library")).toBeVisible({
      timeout: 10_000,
    });

    const viewBookLink = page.getByRole("link", { name: "View Book" });
    await expect(viewBookLink).toBeVisible();
    await expect(viewBookLink).toHaveAttribute("href", /\/books\/book-001/);
  });
});

// ===========================================================================
// MULTI-FORMAT MERGE (US-1.1.8)
// ===========================================================================

test.describe("Multi-format merge", () => {
  test("merge success shows edition count", async ({ page }) => {
    await mockUploadAccept(page);
    await mockPollResolved(page, { isDuplicate: true });
    await mockGetBook(page, FAKE_BOOK_ID, fakeBook());
    await mockMergeFormatSuccess(page);

    await page.goto("/upload");
    await triggerFileUpload(page);

    await expect(page.getByText("Already in Your Library")).toBeVisible({
      timeout: 10_000,
    });

    // Click "Yes, merge"
    await page.getByRole("button", { name: "Yes, merge" }).click();

    // Should show merge success with edition count
    await expect(page.getByText(/2 editions/)).toBeVisible({
      timeout: 10_000,
    });

    // "View book details" link and "Add another" button
    await expect(
      page.getByRole("link", { name: "View book details" })
    ).toBeVisible();
    await expect(
      page.getByRole("button", { name: "Add another" })
    ).toBeVisible();
  });

  test("merge failure -> retry", async ({ page }) => {
    await mockUploadAccept(page);
    await mockPollResolved(page, { isDuplicate: true });
    await mockGetBook(page, FAKE_BOOK_ID, fakeBook());
    await mockMergeFormatFailure(page);

    await page.goto("/upload");
    await triggerFileUpload(page);

    await expect(page.getByText("Already in Your Library")).toBeVisible({
      timeout: 10_000,
    });

    // Click "Yes, merge"
    await page.getByRole("button", { name: "Yes, merge" }).click();

    // Should show merge failure
    await expect(page.getByText("Merge failed")).toBeVisible({
      timeout: 10_000,
    });

    // Retry: switch to success mock and try again
    await page.unroute(`**/api/books/${FAKE_BOOK_ID}/merge-format`);
    await mockMergeFormatSuccess(page);

    await page.getByRole("button", { name: "Yes, merge" }).click();

    await expect(page.getByText(/2 editions/)).toBeVisible({
      timeout: 10_000,
    });
  });
});

// ===========================================================================
// MULTI-BOOK (US-1.1.7)
// ===========================================================================

test.describe("Multi-book extraction", () => {
  test("multiple books rendered in verification view", async ({ page }) => {
    await mockUploadAccept(page);
    await mockPollResolved(page, {
      bookIds: [FAKE_BOOK_ID, FAKE_BOOK_ID_2, FAKE_BOOK_ID_3],
    });
    await mockGetBook(page, FAKE_BOOK_ID, fakeBook());
    await mockGetBook(page, FAKE_BOOK_ID_2, fakeBook2());
    await mockGetBook(page, FAKE_BOOK_ID_3, fakeBook3());

    await page.goto("/upload");
    await triggerFileUpload(page);

    // Wait for all books to appear
    await expect(page.getByText("Books Identified!")).toBeVisible({
      timeout: 10_000,
    });

    // All three book titles should be visible
    await expect(page.getByText("The Name of the Rose")).toBeVisible();
    await expect(page.getByText("Foucault's Pendulum")).toBeVisible();
    await expect(page.getByText("Baudolino")).toBeVisible();

    // Each book should have a "View Book" link
    const viewBookLinks = page.getByRole("link", { name: "View Book" });
    await expect(viewBookLinks).toHaveCount(3);
  });
});

// ===========================================================================
// ARIA / ACCESSIBILITY
// ===========================================================================

test.describe("ARIA and accessibility", () => {
  test("aria-live='polite' on status region", async ({ page }) => {
    await page.goto("/upload");

    // The status region wrapping all upload states should have aria-live="polite"
    const statusRegion = page.locator("[aria-live='polite']");
    await expect(statusRegion).toBeVisible();
  });

  test("role='status' on loading state", async ({ page }) => {
    await mockUploadAccept(page);
    await mockPollPending(page);

    await page.goto("/upload");
    await triggerFileUpload(page);

    const loading = page.getByTestId("upload-loading");
    await expect(loading).toBeVisible();
    await expect(loading).toHaveAttribute("role", "status");
  });

  test("role='status' on complete state", async ({ page }) => {
    await mockUploadAccept(page);
    await mockPollResolved(page);
    await mockGetBook(page);
    await mockPlacementSuccess(page);

    await page.goto("/upload");
    await triggerFileUpload(page);

    await expect(page.getByTestId("upload-verify")).toBeVisible({
      timeout: 10_000,
    });
    await page.getByTestId("upload-confirm-btn").click();
    await page
      .getByRole("button", { name: /Add to Wish List/ })
      .click();

    const complete = page.getByTestId("upload-complete");
    await expect(complete).toBeVisible({ timeout: 10_000 });
    await expect(complete).toHaveAttribute("role", "status");
  });

  test("drop zone is keyboard-accessible via file picker", async ({
    page,
  }) => {
    await page.goto("/upload");

    // The "Choose Photo" button inside the drop zone should be focusable and activatable
    const chooseBtn = page.getByRole("button", { name: "Choose Photo" });
    await expect(chooseBtn).toBeVisible();

    // Tab to it and verify it receives focus
    await chooseBtn.focus();
    await expect(chooseBtn).toBeFocused();
  });
});
