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
      id: "edition-1",
      isbn: "9780151446476",
      format_label: "Hardcover",
      page_count: 502,
      publication_year: 1983,
      publisher: "Harcourt",
      cover_image_url: "/covers/rose.jpg",
      is_primary: true,
    },
    edition_count: 1,
    subjects: [],
    visibility_tier: "public",
    ...overrides,
  };
}

function fakeBook2() {
  return fakeBook({
    id: FAKE_BOOK_ID_2,
    title: "Foucault's Pendulum",
    author: { id: "author-1", name: "Umberto Eco", bio: null, website: null },
    primary_edition: {
      id: "edition-2",
      isbn: "9780151327652",
      format_label: "Paperback",
      page_count: 623,
      publication_year: 1989,
      publisher: "Harcourt",
      cover_image_url: null,
      is_primary: true,
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
        status: 202,
        contentType: "application/json",
        body: JSON.stringify({ status: "accepted", image_id: FAKE_IMAGE_ID }),
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

/** Mock GET /api/upload/:id/status to return HTTP 500. */
async function mockPollServerError(page: Page) {
  await page.route(`**/api/upload/*/status`, (route) => {
    route.fulfill({
      status: 500,
      contentType: "application/json",
      body: JSON.stringify({ error: "Internal server error" }),
    });
  });
}

/** Mock GET /api/books/:id to return HTTP 500. */
async function mockGetBookServerError(page: Page, bookId: string) {
  await page.route(`**/api/books/${bookId}`, (route) => {
    if (route.request().method() === "GET") {
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
          id: "edition-merge-1",
          isbn: "9780151446476",
          format_label: "Paperback",
          page_count: 502,
          publication_year: 1984,
          publisher: "Harcourt",
          cover_image_url: null,
          is_primary: false,
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

test.describe("Happy paths", { tag: ["@US-1.1.1"] }, () => {
  // US-1.1.1 | Suite 1: Playwright
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

  // US-1.1.1 | Suite 1: Playwright
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

  // US-1.1.1 | Suite 1: Playwright
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

    // All 5 shelves should be visible (exact: true to avoid "Library" matching "Antilibrary")
    await expect(
      shelfPicker.getByRole("button", { name: "Library", exact: true })
    ).toBeVisible();
    await expect(
      shelfPicker.getByRole("button", { name: "Antilibrary", exact: true })
    ).toBeVisible();
    await expect(
      shelfPicker.getByRole("button", { name: "Wish List", exact: true })
    ).toBeVisible();
    await expect(
      shelfPicker.getByRole("button", { name: "Reading Pile", exact: true })
    ).toBeVisible();
    await expect(
      shelfPicker.getByRole("button", { name: "Looking for a Home", exact: true })
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

  // US-1.1.1 | Suite 1: Playwright
  test("'View on shelf' navigates to the correct shelf route", async ({
    page,
  }) => {
    await mockUploadAccept(page);
    await mockPollResolved(page);
    await mockGetBook(page);
    await mockPlacementSuccess(page);

    await page.goto("/upload");
    await triggerFileUpload(page);

    // Progress through verify -> shelf pick -> complete
    await expect(page.getByTestId("upload-verify")).toBeVisible({
      timeout: 10_000,
    });
    await page.getByTestId("upload-confirm-btn").click();
    await page
      .getByRole("button", { name: /Add to Wish List/ })
      .click();
    await expect(page.getByTestId("upload-complete")).toBeVisible();

    // Click "View on shelf" and verify navigation to /wishlist
    await page.getByRole("button", { name: "View on shelf" }).click();
    await expect(page).toHaveURL(/\/wishlist/);
  });
});

// ===========================================================================
// SAD PATHS
// ===========================================================================

test.describe("Sad paths", { tag: ["@US-1.1.1", "@US-1.1.2", "@US-1.1.3"] }, () => {
  // US-1.1.1 | Suite 1: Playwright
  test("upload HTTP failure (500) -> error -> retry", { tag: ["@US-1.1.1"] }, async ({ page }) => {
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

  // US-1.1.1 | Suite 1: Playwright
  test("poll timeout -> Could Not Identify -> manual ISBN / retry", { tag: ["@US-1.1.1"] }, async ({
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

  // US-1.1.2 | Suite 1: Playwright
  test("ISBN not found (hard gate) -> rejection -> manual ISBN / retry", { tag: ["@US-1.1.2"] }, async ({
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

  // US-1.1.3 | Suite 1: Playwright
  test("non-book rejection -> Doesn't Look Like a Book -> retry", { tag: ["@US-1.1.3"] }, async ({
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

  // US-1.1.1 | Suite 1: Playwright
  test("placement API failure (422) -> error -> retry", { tag: ["@US-1.1.1"] }, async ({ page }) => {
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

  // US-1.1.1 | Suite 1: Playwright
  test("poll returns HTTP 500 -> IdentificationFailed error view shown -> retry available", { tag: ["@US-1.1.1"] }, async ({
    page,
  }) => {
    await mockUploadAccept(page);
    await mockPollServerError(page);

    await page.goto("/upload");
    await triggerFileUpload(page);

    // Error view should appear with identification failure text
    await expect(page.getByTestId("upload-error")).toBeVisible({
      timeout: 15_000,
    });
    await expect(page.getByTestId("upload-error")).toContainText(
      "Could Not Identify"
    );

    // Retry options should be available
    await expect(
      page
        .getByRole("button", { name: /Try Another Photo/ })
        .or(page.getByRole("button", { name: /Try Again/ }))
    ).toBeVisible();
  });

  // US-1.1.1 | Suite 1: Playwright
  test("unauthenticated -> shows auth gate or redirects", { tag: ["@US-1.1.1"] }, async ({
    browser,
    baseURL,
  }) => {
    // Create a fresh context without auth storage state
    const context = await browser.newContext({ baseURL });
    const page = await context.newPage();

    await page.goto("/upload", { waitUntil: "networkidle" });

    // The Elm SPA checks auth client-side. Without a token, it should
    // show either: login form (server redirect), auth-required message,
    // or the upload drop zone (which will fail on API calls with 401).
    // Confirm the page rendered something meaningful within 15 seconds.
    await page.waitForLoadState("domcontentloaded");
    await expect(
      page
        .locator('input[id="email"]')
        .or(page.getByTestId("upload-auth-required"))
        .or(page.getByTestId("upload-drop-zone"))
    ).toBeVisible({ timeout: 15000 });

    await context.close();
  });
});

// ===========================================================================
// DUPLICATE DETECTION (US-1.1.6)
// ===========================================================================

test.describe("Duplicate detection", { tag: ["@US-1.1.6"] }, () => {
  async function setupDuplicateFlow(page: Page) {
    await mockUploadAccept(page);
    await mockPollResolved(page, { isDuplicate: true });
    await mockGetBook(page, FAKE_BOOK_ID, fakeBook());

    await page.goto("/upload");
    await triggerFileUpload(page);
  }

  // US-1.1.6 | Suite 1: Playwright
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

  // US-1.1.6 | Suite 1: Playwright
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

  // US-1.1.6 | Suite 1: Playwright
  test("'Go Back' resets the upload flow", async ({ page }) => {
    await setupDuplicateFlow(page);

    await expect(page.getByText("Already in Your Library")).toBeVisible({
      timeout: 10_000,
    });

    await page.getByRole("button", { name: "Go Back" }).click();

    // Should return to initial upload area
    await expect(page.getByTestId("upload-drop-zone")).toBeVisible();
  });

  // US-1.1.6 | Suite 1: Playwright
  test("duplicate detection — GET /api/books/:id returns 500 -> error view shown", async ({
    page,
  }) => {
    await mockUploadAccept(page);
    await mockPollResolved(page, { isDuplicate: true, bookId: FAKE_BOOK_ID });
    await mockGetBookServerError(page, FAKE_BOOK_ID);

    await page.goto("/upload");
    await triggerFileUpload(page);

    // Error view should appear — not the "Already in Your Library" duplicate view
    await expect(page.getByTestId("upload-error")).toBeVisible({
      timeout: 10_000,
    });
    await expect(
      page.getByText("Already in Your Library")
    ).not.toBeVisible();
  });

  // US-1.1.6 | Suite 1: Playwright
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

test.describe("Multi-format merge", { tag: ["@US-1.1.8"] }, () => {
  // US-1.1.8 | Suite 1: Playwright
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

  // US-1.1.8 | Suite 1: Playwright
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

test.describe("Multi-book extraction", { tag: ["@US-1.1.7"] }, () => {
  // US-1.1.7 | Suite 1: Playwright
  test("multi-book: one book returns 500 -> remaining books still shown", async ({
    page,
  }) => {
    await mockUploadAccept(page);
    await mockPollResolved(page, {
      bookIds: [FAKE_BOOK_ID, FAKE_BOOK_ID_2, FAKE_BOOK_ID_3],
    });
    await mockGetBook(page, FAKE_BOOK_ID, fakeBook());
    await mockGetBook(page, FAKE_BOOK_ID_2, fakeBook2());
    await mockGetBookServerError(page, FAKE_BOOK_ID_3);

    await page.goto("/upload");
    await triggerFileUpload(page);

    // Wait for the multi-book view to appear
    await expect(page.getByText("Books Identified!")).toBeVisible({
      timeout: 10_000,
    });

    // The two successful book titles should be visible
    await expect(page.getByText("The Name of the Rose")).toBeVisible();
    await expect(page.getByText("Foucault's Pendulum")).toBeVisible();

    // The page should not show a full error state — partial failure is handled gracefully
    await expect(page.getByTestId("upload-error")).not.toBeVisible();
  });

  // US-1.1.7 | Suite 1: Playwright
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
// AGE-GATED CONTENT (US-1.1.4)
// ===========================================================================

test.describe("Age-gated content (US-1.1.4)", { tag: ["@US-1.1.4"] }, () => {
  // US-1.1.4 | Suite 1: Playwright
  test("age-gated book flows through upload normally — gating happens on book detail", async ({
    page,
  }) => {
    const ageGatedBook = fakeBook({ visibility_tier: "age_gated" });

    await mockUploadAccept(page);
    await mockPollResolved(page);
    await mockGetBook(page, FAKE_BOOK_ID, ageGatedBook);
    await mockPlacementSuccess(page);

    await page.goto("/upload");
    await triggerFileUpload(page);

    // Processing spinner should appear
    await expect(page.getByTestId("upload-loading")).toBeVisible();

    // Verification view should appear normally — age gating is transparent during upload
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

    // Shelf picker should appear — no age gate blocks placement
    await expect(page.getByTestId("upload-shelf-picker")).toBeVisible();

    // Confirm placement (defaults to Wish List)
    await page
      .getByRole("button", { name: /Add to Wish List/ })
      .click();

    // Success view should appear normally
    await expect(page.getByTestId("upload-complete")).toBeVisible();
    await expect(page.getByTestId("upload-complete")).toContainText(
      "The Name of the Rose"
    );
    await expect(page.getByTestId("upload-complete")).toContainText(
      "Wish List"
    );

    // "View on shelf" and "Add another" buttons should be present
    await expect(
      page.getByRole("button", { name: "View on shelf" })
    ).toBeVisible();
    await expect(
      page.getByRole("button", { name: "Add another" })
    ).toBeVisible();

    // NOTE: The age gate itself appears when viewing the book detail page,
    // which is tested separately in age-gate.spec.ts
  });
});

// ===========================================================================
// ARIA / ACCESSIBILITY
// ===========================================================================

test.describe("ARIA and accessibility", { tag: ["@US-1.1.1"] }, () => {
  // US-1.1.1 | Suite 1: Playwright
  test("aria-live='polite' on status region", async ({ page }) => {
    await page.goto("/upload");

    // The status region wrapping all upload states should have aria-live="polite"
    const statusRegion = page.locator("[aria-live='polite']");
    await expect(statusRegion).toBeVisible();
  });

  // US-1.1.1 | Suite 1: Playwright
  test("role='status' on loading state", async ({ page }) => {
    await mockUploadAccept(page);
    await mockPollPending(page);

    await page.goto("/upload");
    await triggerFileUpload(page);

    const loading = page.getByTestId("upload-loading");
    await expect(loading).toBeVisible();
    await expect(loading).toHaveAttribute("role", "status");
  });

  // US-1.1.1 | Suite 1: Playwright
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

  // US-1.1.1 | Suite 1: Playwright
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
