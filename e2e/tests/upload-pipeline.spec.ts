import { test, expect, Page, Route } from "@playwright/test";
import { suiteAuthFile } from "./helpers";

test.use({ storageState: suiteAuthFile("upload") });

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

const MOCK_R2_PUT_PATH = `/__mock_r2_put__/${FAKE_IMAGE_ID}`;

/**
 * Mock the 3-step presigned-URL upload flow:
 *   POST /api/upload/init        → returns image_id + same-origin mock PUT URL
 *   PUT  <mock-PUT-url>          → 200 OK
 *   POST /api/upload/:id/commit  → 200 OK
 *
 * After commit, Page.Upload opens an SSE EventSource against
 * /api/upload/:id/stream — that's mocked separately by `injectEventSourceMock`
 * so each test can choose resolved / rejected / not-a-book / error / pending.
 */
async function mockUploadAccept(page: Page) {
  await page.route("**/api/upload/init", (route) => {
    if (route.request().method() === "POST") {
      route.fulfill({
        status: 200,
        contentType: "application/json",
        body: JSON.stringify({
          image_id: FAKE_IMAGE_ID,
          upload_url: MOCK_R2_PUT_PATH,
          expires_in: 3600,
        }),
      });
    } else {
      route.continue();
    }
  });
  await page.route(`**${MOCK_R2_PUT_PATH}`, (route) => {
    if (route.request().method() === "PUT") {
      route.fulfill({ status: 200, body: "" });
    } else {
      route.continue();
    }
  });
  await page.route("**/api/upload/*/commit", (route) => {
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

/**
 * Fail the upload at the init step, with a 500. Since #374 the page names the
 * failure it was given rather than rendering one "Upload failed. Please try
 * again." for everything — a 500 is unrecognised, so the card says so.
 * Keeping the failure on the very first step is the simplest path for the
 * sad-path retry test.
 */
async function mockUploadFailure(page: Page) {
  await page.route("**/api/upload/init", (route) => {
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

/**
 * Inject a mock EventSource into the page before it loads.
 * Must be called before page.goto(). The mock fires onmessage/onerror
 * after 80ms (enough time for the Elm app to attach its handler).
 */
async function injectEventSourceMock(
  page: Page,
  config: { payload?: object; type?: "error" | "pending" }
) {
  await page.addInitScript((cfg) => {
    (window as any).__mockSSEConfig = cfg;
    (window as any).EventSource = class MockEventSource {
      url: string;
      onmessage: ((e: MessageEvent) => void) | null = null;
      onerror: ((e: Event) => void) | null = null;
      readyState = 0;

      constructor(url: string) {
        this.url = url;
        const config = (window as any).__mockSSEConfig;
        if (!config) return;

        if (config.type === "error") {
          setTimeout(() => {
            this.readyState = 2;
            this.onerror && this.onerror(new Event("error"));
          }, 80);
        } else if (config.type === "pending") {
        } else if (config.payload) {
          const data = JSON.stringify(config.payload);
          setTimeout(() => {
            this.readyState = 1;
            this.onmessage &&
              this.onmessage(new MessageEvent("message", { data }));
          }, 80);
        }
      }

      close() { this.readyState = 2; }
      addEventListener() {}
      removeEventListener() {}
    };
  }, config);
}

/** Mock GET /api/upload/:id/stream with a resolved single book (SSE). */
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

  await injectEventSourceMock(page, {
    payload: {
      image_id: FAKE_IMAGE_ID,
      status: "resolved",
      book_id: bookId,
      book_ids: bookIds,
      rejection_reason: null,
      is_duplicate: isDuplicate,
    },
  });
}

/** Mock GET /api/upload/:id/stream to stay pending forever (heartbeat SSE, until unrouted). */
async function mockPollPending(page: Page) {
  await injectEventSourceMock(page, { type: "pending" });
}

/**
 * Mock GET /api/upload/:id/stream with rejected (ISBN not found) SSE.
 *
 * ⛔ `is_duplicate` must be a BOOLEAN, not `null`. `Api.streamEventDecoder`
 * requires it (`Decode.field "is_duplicate" Decode.bool`) because
 * `ProtoJSON.poll_response/1` always emits one — and a frame that fails to
 * decode is DISCARDED by `Page.Upload.StreamEvent`, which treats a decode error
 * as "ignore, stay put" so heartbeats do not disturb the page.
 *
 * This mock sent `null`, so the frame never arrived: the page sat on its
 * spinner and the test waited out its timeout. Found while driving #374 against
 * a local stack; it is the same wire-contract drift #328 removed from the Elm
 * fixtures, surviving here in the Playwright ones.
 */
async function mockPollRejected(page: Page) {
  await injectEventSourceMock(page, {
    payload: {
      image_id: FAKE_IMAGE_ID,
      status: "rejected",
      book_id: null,
      book_ids: [],
      rejection_reason: "isbn_not_found",
      is_duplicate: false,
    },
  });
}

/** Mock GET /api/upload/:id/stream to return HTTP 500 (triggers EventSource.onerror → StreamError → IdentificationFailed). */
async function mockPollServerError(page: Page) {
  await injectEventSourceMock(page, { type: "error" });
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

/**
 * Mock GET /api/upload/:id/stream with resolved but no book IDs (not a book).
 * `is_duplicate` is a boolean for the reason spelled out on `mockPollRejected`.
 */
async function mockPollNotABook(page: Page) {
  await injectEventSourceMock(page, {
    payload: {
      image_id: FAKE_IMAGE_ID,
      status: "resolved",
      book_id: null,
      book_ids: [],
      rejection_reason: null,
      is_duplicate: false,
    },
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

/**
 * Trigger a file upload via the file picker button.
 * Creates a synthetic 1x1 PNG buffer so Elm's File decoder is satisfied.
 */
async function triggerFileUpload(page: Page) {
  const fileChooserPromise = page.waitForEvent("filechooser");
  await page.getByRole("button", { name: "Choose Photo" }).click();
  const fileChooser = await fileChooserPromise;
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

test.describe("Happy paths", { tag: ["@US-1.1.1"] }, () => {
  test("single photo drag-and-drop: drop -> processing -> verify -> shelf pick -> success", async ({
    page,
  }) => {
    await mockUploadAccept(page);
    await mockPollResolved(page);
    await mockGetBook(page);
    await mockPlacementSuccess(page);

    await page.goto("/upload");

    await triggerDragAndDrop(page);

    await expect(page.getByTestId("upload-loading")).toBeVisible();
    await expect(page.getByTestId("upload-loading")).toHaveAttribute(
      "role",
      "status"
    );

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

    await page.getByTestId("upload-confirm-btn").click();

    await expect(page.getByTestId("upload-shelf-picker")).toBeVisible();

    await page
      .getByRole("button", { name: /Add to Wish List/ })
      .click();

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

    await expect(
      page.getByRole("button", { name: "View on shelf" })
    ).toBeVisible();

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

    await triggerFileUpload(page);

    await expect(page.getByTestId("upload-verify")).toBeVisible({
      timeout: 10_000,
    });
    await expect(page.getByTestId("upload-verify")).toContainText(
      "The Name of the Rose"
    );

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

    await expect(
      shelfPicker.getByRole("button", { name: /Add to Wish List/ })
    ).toBeVisible();

    await shelfPicker
      .getByRole("button", { name: "Library", exact: true })
      .click();

    await expect(
      shelfPicker.getByRole("button", { name: /Add to Library/ })
    ).toBeVisible();

    await shelfPicker
      .getByRole("button", { name: /Add to Library/ })
      .click();

    await expect(page.getByTestId("upload-complete")).toBeVisible();
    await expect(page.getByTestId("upload-complete")).toContainText("Library");
  });

  test("'View on shelf' navigates to the correct shelf route", async ({
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
    await page
      .getByRole("button", { name: /Add to Wish List/ })
      .click();
    await expect(page.getByTestId("upload-complete")).toBeVisible();

    await page.getByRole("button", { name: "View on shelf" }).click();
    await expect(page).toHaveURL(/\/wishlist/);
  });
});

test.describe("Sad paths", { tag: ["@US-1.1.1", "@US-1.1.2", "@US-1.1.3"] }, () => {
  test("upload HTTP failure (500) -> error -> retry", { tag: ["@US-1.1.1"] }, async ({ page }) => {
    await mockUploadFailure(page);

    await page.goto("/upload");
    await triggerFileUpload(page);

    await expect(page.getByTestId("upload-error")).toBeVisible({
      timeout: 10_000,
    });
    await expect(page.getByTestId("upload-error")).toHaveAttribute(
      "data-failure-cause",
      "not-sent"
    );
    await expect(page.getByTestId("upload-error")).toContainText(
      "we cannot say why"
    );

    await expect(
      page.getByRole("button", { name: "Try Again" })
    ).toBeVisible();

    await page.unroute("**/api/upload/init");
    await mockUploadAccept(page);
    await mockPollResolved(page);
    await mockGetBook(page);

    await page.getByRole("button", { name: "Try Again" }).click();

    await expect(page.getByTestId("upload-drop-zone")).toBeVisible();
  });

  test("stream error -> the lost connection is named -> manual ISBN / retry", { tag: ["@US-1.1.1"] }, async ({
    page,
  }) => {
    await mockUploadAccept(page);

    await injectEventSourceMock(page, { type: "error" });

    await page.goto("/upload");
    await triggerFileUpload(page);

    await expect(page.getByTestId("upload-error")).toBeVisible({
      timeout: 15_000,
    });
    await expect(page.getByTestId("upload-error")).toHaveAttribute(
      "data-failure-cause",
      "connection-lost"
    );
    await expect(page.getByTestId("upload-error")).toContainText(
      "The Library Is Unreachable"
    );

    await expect(
      page.getByRole("button", { name: /Enter ISBN Manually/ })
    ).toBeVisible();

    await expect(
      page.getByRole("button", { name: /Try Another Photo/ })
    ).toBeVisible();
  });

  test("ISBN not found (hard gate) -> rejection -> manual ISBN / retry", { tag: ["@US-1.1.2"] }, async ({
    page,
  }) => {
    await mockUploadAccept(page);
    await mockPollRejected(page);

    await page.goto("/upload");
    await triggerFileUpload(page);

    await expect(page.getByTestId("upload-error")).toBeVisible({
      timeout: 10_000,
    });
    await expect(page.getByTestId("upload-error")).toHaveAttribute(
      "data-failure-cause",
      "isbn-unreadable"
    );
    await expect(page.getByTestId("upload-error")).toContainText(
      "Could Not Read the ISBN"
    );

    await expect(
      page.getByRole("button", { name: /Enter ISBN Manually/ })
    ).toBeVisible();
    await expect(
      page.getByRole("button", { name: /Try Another Photo/ })
    ).toBeVisible();
  });

  test("non-book rejection -> Doesn't Look Like a Book -> retry", { tag: ["@US-1.1.3"] }, async ({
    page,
  }) => {
    await mockUploadAccept(page);
    await mockPollNotABook(page);

    await page.goto("/upload");
    await triggerFileUpload(page);

    await expect(page.getByTestId("upload-error")).toBeVisible({
      timeout: 10_000,
    });
    await expect(page.getByTestId("upload-error")).toContainText(
      "Doesn't Look Like a Book"
    );

    await expect(
      page.getByRole("button", { name: "Try Again" })
    ).toBeVisible();
  });

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

    await page
      .getByRole("button", { name: /Add to Wish List/ })
      .click();

    await expect(shelfPicker).toContainText("Failed to add book", {
      timeout: 10_000,
    });

    await expect(
      shelfPicker.getByRole("button", { name: /Add to/ })
    ).toBeVisible();

    await page.unroute("**/api/bookshelves/*/placements");
    await mockPlacementSuccess(page);

    await shelfPicker.getByRole("button", { name: /Add to/ }).click();
    await expect(page.getByTestId("upload-complete")).toBeVisible({
      timeout: 10_000,
    });
  });

  test("poll returns HTTP 500 -> IdentificationFailed error view shown -> retry available", { tag: ["@US-1.1.1"] }, async ({
    page,
  }) => {
    await mockUploadAccept(page);
    await mockPollServerError(page);

    await page.goto("/upload");
    await triggerFileUpload(page);

    await expect(page.getByTestId("upload-error")).toBeVisible({
      timeout: 15_000,
    });
    await expect(page.getByTestId("upload-error")).toHaveAttribute(
      "data-failure-cause",
      "connection-lost"
    );

    await expect(
      page
        .getByRole("button", { name: /Try Another Photo/ })
        .or(page.getByRole("button", { name: /Try Again/ }))
    ).toBeVisible();
  });

  test("unauthenticated -> shows auth gate or redirects", { tag: ["@US-1.1.1"] }, async ({
    browser,
    baseURL,
  }) => {
    const context = await browser.newContext({ baseURL });
    const page = await context.newPage();

    await page.goto("/upload", { waitUntil: "networkidle" });

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

test.describe("Duplicate detection", { tag: ["@US-1.1.6"] }, () => {
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

    await expect(page.getByText("Already in Your Library")).toBeVisible({
      timeout: 10_000,
    });

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

    await expect(page.getByTestId("upload-drop-zone")).toBeVisible();
  });

  test("duplicate detection — GET /api/books/:id returns 500 -> error view shown", async ({
    page,
  }) => {
    await mockUploadAccept(page);
    await mockPollResolved(page, { isDuplicate: true, bookId: FAKE_BOOK_ID });
    await mockGetBookServerError(page, FAKE_BOOK_ID);

    await page.goto("/upload");
    await triggerFileUpload(page);

    await expect(page.getByTestId("upload-error")).toBeVisible({
      timeout: 10_000,
    });
    await expect(
      page.getByText("Already in Your Library")
    ).not.toBeVisible();
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

test.describe("Multi-format merge", { tag: ["@US-1.1.8"] }, () => {
  test("merge success names the added edition", async ({ page }) => {
    await mockUploadAccept(page);
    await mockPollResolved(page, { isDuplicate: true });
    await mockGetBook(page, FAKE_BOOK_ID, fakeBook());
    await mockMergeFormatSuccess(page);

    await page.goto("/upload");
    await triggerFileUpload(page);

    await expect(page.getByText("Already in Your Library")).toBeVisible({
      timeout: 10_000,
    });

    await page.getByRole("button", { name: "Yes, merge" }).click();

    await expect(
      page.getByText(
        /The Paperback edition \(ISBN 9780151446476\) is now listed/
      )
    ).toBeVisible({
      timeout: 10_000,
    });

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

    await page.getByRole("button", { name: "Yes, merge" }).click();

    await expect(page.getByText("Merge failed")).toBeVisible({
      timeout: 10_000,
    });

    await page.unroute(`**/api/books/${FAKE_BOOK_ID}/merge-format`);
    await mockMergeFormatSuccess(page);

    await page.getByRole("button", { name: "Yes, merge" }).click();

    await expect(
      page.getByText(
        /The Paperback edition \(ISBN 9780151446476\) is now listed/
      )
    ).toBeVisible({
      timeout: 10_000,
    });
  });
});

test.describe("Multi-book extraction", { tag: ["@US-1.1.7"] }, () => {
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

    await expect(page.getByText("Books Identified!")).toBeVisible({
      timeout: 10_000,
    });

    await expect(page.getByText("The Name of the Rose")).toBeVisible();
    await expect(page.getByText("Foucault's Pendulum")).toBeVisible();

    await expect(page.getByTestId("upload-error")).not.toBeVisible();
  });

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

    await expect(page.getByText("Books Identified!")).toBeVisible({
      timeout: 10_000,
    });

    await expect(page.getByText("The Name of the Rose")).toBeVisible();
    await expect(page.getByText("Foucault's Pendulum")).toBeVisible();
    await expect(page.getByText("Baudolino")).toBeVisible();

    const viewBookLinks = page.getByRole("link", { name: "View Book" });
    await expect(viewBookLinks).toHaveCount(3);
  });
});

test.describe("Age-gated content", { tag: ["@US-1.1.4"] }, () => {
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

    await page.getByTestId("upload-confirm-btn").click();

    await expect(page.getByTestId("upload-shelf-picker")).toBeVisible();

    await page
      .getByRole("button", { name: /Add to Wish List/ })
      .click();

    await expect(page.getByTestId("upload-complete")).toBeVisible();
    await expect(page.getByTestId("upload-complete")).toContainText(
      "The Name of the Rose"
    );
    await expect(page.getByTestId("upload-complete")).toContainText(
      "Wish List"
    );

    await expect(
      page.getByRole("button", { name: "View on shelf" })
    ).toBeVisible();
    await expect(
      page.getByRole("button", { name: "Add another" })
    ).toBeVisible();

  });
});

test.describe("ARIA and accessibility", { tag: ["@US-1.1.1"] }, () => {
  test("aria-live='polite' on status region", async ({ page }) => {
    await page.goto("/upload");

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

    const chooseBtn = page.getByRole("button", { name: "Choose Photo" });
    await expect(chooseBtn).toBeVisible();

    await chooseBtn.focus();
    await expect(chooseBtn).toBeFocused();
  });
});

/** Mock the SSE stream with a rejection carrying a specific reason token. */
async function mockPollRejectedWith(page: Page, reason: string) {
  await injectEventSourceMock(page, {
    payload: {
      image_id: FAKE_IMAGE_ID,
      status: "rejected",
      book_id: null,
      book_ids: [],
      rejection_reason: reason,
      is_duplicate: false,
    },
  });
}

/** Mock the SSE stream with the loop's synthetic timeout frame. */
async function mockPollTimedOut(page: Page) {
  await injectEventSourceMock(page, {
    payload: {
      image_id: FAKE_IMAGE_ID,
      status: "timeout",
      book_id: null,
      book_ids: [],
      rejection_reason: null,
      is_duplicate: false,
    },
  });
}

const FAILURE_BUDGET_MS = 5_000;

test.describe(
  "Failure copy names its cause, quickly",
  { tag: ["@US-16.2.1", "@US-1.1.2"] },
  () => {
    const cases = [
      {
        name: "an image the service could not decode",
        reason: "undecodable_image",
        cause: "image-unreadable",
        says: "That Photo Could Not Be Opened",
        doesNotSay: "could not make out its ISBN",
      },
      {
        name: "a photo with no book in it",
        reason: "not_a_book",
        cause: "not-a-book",
        says: "That Doesn't Look Like a Book",
        doesNotSay: "could not make out its ISBN",
      },
      {
        name: "the vision service being down",
        reason: "vision_unavailable",
        cause: "service-unavailable",
        says: "There is nothing wrong with your photo.",
        doesNotSay: "Try a clearer image",
      },
      {
        name: "a token this client has never seen",
        reason: "shelf_gremlins",
        cause: "unknown",
        says: "we cannot say why",
        doesNotSay: "could not make out its ISBN",
      },
    ];

    for (const c of cases) {
      test(`${c.name} says so, within ${FAILURE_BUDGET_MS / 1000}s`, async ({
        page,
      }) => {
        await mockUploadAccept(page);
        await mockPollRejectedWith(page, c.reason);

        await page.goto("/upload");
        const startedAt = Date.now();
        await triggerFileUpload(page);

        const error = page.getByTestId("upload-error");
        await expect(error).toBeVisible({ timeout: FAILURE_BUDGET_MS });
        expect(Date.now() - startedAt).toBeLessThan(FAILURE_BUDGET_MS);

        await expect(error).toHaveAttribute("data-failure-cause", c.cause);
        await expect(error).toContainText(c.says);
        await expect(error).not.toContainText(c.doesNotSay);
      });
    }

    test(`a stream that times out reports no verdict, within ${
      FAILURE_BUDGET_MS / 1000
    }s`, async ({ page }) => {
      await mockUploadAccept(page);
      await mockPollTimedOut(page);

      await page.goto("/upload");
      const startedAt = Date.now();
      await triggerFileUpload(page);

      const error = page.getByTestId("upload-error");
      await expect(error).toBeVisible({ timeout: FAILURE_BUDGET_MS });
      expect(Date.now() - startedAt).toBeLessThan(FAILURE_BUDGET_MS);

      await expect(error).toHaveAttribute("data-failure-cause", "timed-out");
      await expect(error).toContainText("No Answer Came Back");
      await expect(error).toContainText(
        "Nothing has been added to your shelves."
      );
      await expect(error).not.toContainText("could not make out its ISBN");
    });

    test("a 429 on the upload names the wait rather than urging a retry", async ({
      page,
    }) => {
      await page.route("**/api/upload/init", (route) =>
        route.fulfill({
          status: 429,
          headers: { "retry-after": "60" },
          contentType: "application/json",
          body: JSON.stringify({ error: "rate_limit_exceeded" }),
        })
      );

      await page.goto("/upload");
      const startedAt = Date.now();
      await triggerFileUpload(page);

      const error = page.getByTestId("upload-error");
      await expect(error).toBeVisible({ timeout: FAILURE_BUDGET_MS });
      expect(Date.now() - startedAt).toBeLessThan(FAILURE_BUDGET_MS);

      await expect(error).toHaveAttribute("data-failure-cause", "not-sent");
      await expect(error).toContainText("Too many attempts from here just now.");
      await expect(error).not.toContainText("Upload failed. Please try again.");
    });
  }
);
