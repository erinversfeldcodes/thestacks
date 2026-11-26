import { test, expect } from "./fixtures";
import type { APIRequestContext, Page } from "@playwright/test";
import {
  mintOrSkip,
  injectSession,
  apiCallFromPage,
  type MintedSession,
} from "./helpers";

/**
 * Live drive of three reading-progress / blog-archive decoder guarantees
 * against the deployed preview stack.
 *
 *   1. The book-detail progress card shows the REAL reading status that the
 *      server sends, not a status the client defaulted in.
 *   2. Saving from the book detail sends that real status back, never a
 *      defaulted/blank one that would overwrite it.
 *   3. A failed "Load more" on the blog archive is made visible to the reader
 *      rather than silently stopping.
 *
 * Auth is a minted `.test` session installed as the `stacks_session` cookie
 * (injectSession). Writes from the spec go through an in-page `fetch`
 * (apiCallFromPage), which carries the session cookie and the CSRF proof the
 * fixtures init-script adds. The application's own saves carry their own CSRF
 * proof on their XHR.
 */

interface ReadingBook {
  session: MintedSession;
  bookId: string;
  placementId: string;
}

const REAL_STATUS = "reading";
const REAL_PAGE = 150;

/**
 * Mint a fresh reader, land them authenticated, put one catalogue book on their
 * reading pile, and record a definite, non-default reading status against it:
 * "reading" at page 150.
 *
 * The non-default status is the whole point. A placement's stored status
 * defaults to "to_read", so a book left at the default cannot distinguish a
 * decoder that reads the real status from one that defaults it in — both would
 * render "To Read". Recording "reading" + a page makes the two observably
 * different.
 */
async function setupReadingBook(
  page: Page,
  request: APIRequestContext,
): Promise<ReadingBook> {
  const session = await mintOrSkip(request);
  await injectSession(page, session);

  const cat = await apiCallFromPage(page, "GET", "/api/catalogue?per_page=1");
  expect(cat.status, "catalogue fetch").toBe(200);
  const book = (cat.data as { books?: Array<{ id: string }> }).books?.[0];
  expect(book, "catalogue returned at least one book to place").toBeTruthy();
  const bookId = (book as { id: string }).id;

  const place = await apiCallFromPage(
    page,
    "POST",
    "/api/bookshelves/reading_pile/placements",
    { book_id: bookId },
  );
  expect(
    place.status,
    `place on reading_pile: ${JSON.stringify(place.data)}`,
  ).toBe(201);
  const placementId = (place.data as { placement: { id: string } }).placement
    .id;

  const progress = await apiCallFromPage(
    page,
    "PUT",
    `/api/placements/${placementId}/progress`,
    { reading_status: REAL_STATUS, current_page: REAL_PAGE },
  );
  expect(
    progress.status,
    `record reading progress: ${JSON.stringify(progress.data)}`,
  ).toBe(200);

  return { session, bookId, placementId };
}

test("box 1 — the progress card shows the real reading status", async ({
  page,
  request,
}, testInfo) => {
  const { bookId } = await setupReadingBook(page, request);

  // Payload evidence: GET /api/books/:id must carry the real status back, so
  // the fix on the server side is observable independently of the UI.
  const bookResp = await apiCallFromPage(page, "GET", `/api/books/${bookId}`);
  expect(bookResp.status, "GET /api/books/:id").toBe(200);
  const data = bookResp.data as {
    placement?: {
      reading_status?: string;
      current_page?: number;
      started_at?: string | null;
      finished_at?: string | null;
    };
  };
  const placement = data.placement;
  // eslint-disable-next-line no-console
  console.log("[box1] /api/books/:id placement =", JSON.stringify(placement));
  await testInfo.attach("box1-books-response.json", {
    body: JSON.stringify(bookResp.data, null, 2),
    contentType: "application/json",
  });
  expect(placement, "the response carries the reader's placement").toBeTruthy();
  expect(placement?.reading_status, "payload reading_status").toBe(REAL_STATUS);
  expect(placement?.current_page, "payload current_page").toBe(REAL_PAGE);

  // Drive the UI: the rendered card must read the real status, not "To Read".
  await page.goto(`/books/${bookId}`);
  const badge = page.getByTestId("reading-status-badge");
  await expect(badge, "the progress card badge renders").toBeVisible({
    timeout: 20_000,
  });
  await expect(
    badge,
    'the badge shows the real "Reading" status, not the defaulted "To Read"',
  ).toHaveText("Reading");

  const progressLine = page.getByTestId("reading-progress");
  await expect(progressLine, "the current-page line renders").toBeVisible();
  await expect(progressLine).toContainText(`p. ${REAL_PAGE}`);

  await page.screenshot({
    path: testInfo.outputPath("box1-progress-card.png"),
    fullPage: true,
  });
});

test("box 2 — a save from the book detail does not overwrite the real status", async ({
  page,
  request,
}, testInfo) => {
  const { bookId } = await setupReadingBook(page, request);

  await page.goto(`/books/${bookId}`);
  const badge = page.getByTestId("reading-status-badge");
  await expect(badge, "the progress card badge renders").toBeVisible({
    timeout: 20_000,
  });
  // Precondition: the card was seeded from the real status, so Save is offered
  // against "reading" rather than a defaulted value.
  await expect(badge).toHaveText("Reading");

  await badge.click();
  const form = page.getByTestId("reading-status-form");
  await expect(form, "the edit form opens").toBeVisible();

  const saveBtn = page.getByTestId("save-progress-btn");
  await expect(
    saveBtn,
    "Save is enabled because a real status is recorded (it is disabled when the status is unknown)",
  ).toBeEnabled();

  // Capture the save request the application sends.
  const savePromise = page.waitForRequest(
    (r) =>
      r.method() === "PUT" &&
      /\/api\/placements\/[^/]+\/progress$/.test(r.url()),
  );
  await saveBtn.click();
  const saveReq = await savePromise;
  const body = saveReq.postDataJSON() as {
    reading_status?: string;
    current_page?: number;
  };
  // eslint-disable-next-line no-console
  console.log("[box2] progress save request body =", JSON.stringify(body));
  await testInfo.attach("box2-save-request-body.json", {
    body: JSON.stringify(body, null, 2),
    contentType: "application/json",
  });

  expect(
    body.reading_status,
    "the save sends the real status, not a defaulted/blank one",
  ).toBe(REAL_STATUS);
  expect(body.reading_status, "the save must not clobber with the default").not.toBe(
    "to_read",
  );
});

test("box 4 — a failed Load more on the blog archive is visible to the reader", async ({
  page,
  request,
}, testInfo) => {
  const session = await mintOrSkip(request);
  await injectSession(page, session);

  // The public archive needs a full 50-post window to emit a next cursor, and
  // the preview corpus has no published public posts to seed that way (the
  // book-writing helper only produces owner-visibility drafts, which the public
  // feed never returns). So the archive's own data responses are driven here:
  // the first page carries a cursor — the documented "empty page, more behind
  // it" state — which is what puts the Load more control on screen, and the
  // next-page request behind that cursor is failed. The code under test is the
  // live app's handling of that failure.
  let secondPageAttempted = false;
  await page.route(/\/api\/blog\/posts(\?.*)?$/, async (route) => {
    const url = route.request().url();
    if (url.includes("after=")) {
      secondPageAttempted = true;
      await route.abort("failed");
    } else {
      await route.fulfill({
        status: 200,
        contentType: "application/json",
        body: JSON.stringify({ posts: [], next_cursor: "SYNTH_NEXT_PAGE" }),
      });
    }
  });

  await page.goto("/blog");

  const loadMore = page.locator(".blog-archive__load-more button");
  await expect(loadMore, "a Load more control is present").toBeVisible({
    timeout: 20_000,
  });
  await expect(loadMore).toHaveText("Load more");

  const archive = page.locator(".blog-archive__content");
  const textBefore = (await archive.innerText()).trim();

  const secondPagePromise = page.waitForRequest(
    (r) =>
      r.url().includes("/api/blog/posts") && r.url().includes("after="),
  );
  await loadMore.click();
  await secondPagePromise;

  // The button reverts from "Loading…" back to "Load more": the request was
  // made and its failure was handled.
  await expect(loadMore, "the Load more button settles after the failure").toHaveText(
    "Load more",
    { timeout: 10_000 },
  );

  await page.screenshot({
    path: testInfo.outputPath("box4-after-failed-loadmore.png"),
    fullPage: true,
  });
  const textAfter = (await archive.innerText()).trim();
  // eslint-disable-next-line no-console
  console.log("[box4] second page attempted =", secondPageAttempted);
  // eslint-disable-next-line no-console
  console.log("[box4] archive text before =", JSON.stringify(textBefore));
  // eslint-disable-next-line no-console
  console.log("[box4] archive text after  =", JSON.stringify(textAfter));

  expect(secondPageAttempted, "the next-page request was attempted").toBe(true);

  // The requirement: after a failed Load more, the reader is TOLD. That is
  // either an error/alert element inside the archive, or failure copy that was
  // not on screen before the click. A silent revert satisfies neither.
  const errorEl = page.locator(
    '.page--blog-archive [role="alert"], .page--blog-archive .error, .page--blog-archive [class*="error"]',
  );
  const errorElVisible = await errorEl
    .first()
    .isVisible()
    .catch(() => false);
  const failureCopy = /could.?n.?t load|try again|went wrong|failed to load|unable to load/i;
  const newFailureText = failureCopy.test(textAfter) && textAfter !== textBefore;
  const failureVisible = errorElVisible || newFailureText;

  expect(
    failureVisible,
    "a failed Load more must be visible to the reader (error/alert element or new failure copy), not a silent stop",
  ).toBe(true);
});
