import { test, expect } from "@playwright/test";
import type { APIRequestContext, Locator, Page } from "@playwright/test";
import { mintSession, injectSession } from "./helpers";

/**
 * Issue #116 Phase 5 — the reading-journey lifecycle, driven in a real browser
 * against a live stack (US-1.6.1–US-1.6.6).
 *
 * Every test in this file mints its OWN isolated, confirmed user via
 * POST /api/test/session (STACKS_E2E_TEST_HELPERS=1 only) and injects the
 * session into localStorage. The journeys are destructive (they empty and
 * re-fill shelves), so a shared suite user is the wrong home — this file lives
 * apart from shelf-actions.spec.ts (which uses a shared serial suite user)
 * precisely so these specs can run fully-parallel without cross-contamination.
 * Where the mint helper is unavailable (prod-shaped targets) each spec skips
 * cleanly rather than failing.
 *
 * Presence/absence is asserted on the SPECIFIC book's DOM element, never on a
 * count: on a spine bookcase via `#spine-<bookId>` (the stable id
 * `Page.Bookshelf.Helpers` stamps on each book button), and on the Reading Pile
 * — which does NOT stamp that id — via the spine's `Book: <title> by …`
 * accessible name scoped to `.book-pile`. Absence is only ever asserted after a
 * positive "the shelf has finished loading" signal (the target book present on
 * its destination, then the emptied source's empty-state), so a wait-for-absence
 * can never pass vacuously against a still-loading shelf.
 */

// ── Shelf descriptors: UI route path vs. API/mover bookshelf name ────────────
// The mover <select> and placement API use the underscore name (reading_pile);
// the SPA route uses the hyphen path (/reading-pile).
type ShelfKey =
  | "library"
  | "antilibrary"
  | "wishlist"
  | "reading_pile"
  | "looking_for_home";

const SHELF_PATH: Record<ShelfKey, string> = {
  library: "/library",
  antilibrary: "/antilibrary",
  wishlist: "/wishlist",
  reading_pile: "/reading-pile",
  looking_for_home: "/looking-for-home",
};

interface CatalogueBook {
  id: string;
  title: string;
  pageCount: number | null;
}

async function catalogueBooks(
  request: APIRequestContext
): Promise<CatalogueBook[]> {
  const resp = await request.get("/api/catalogue?per_page=200");
  if (!resp.ok()) return [];
  const data = await resp.json();
  return (data.books ?? []).map(
    (b: { id: string; title: string; primary_edition?: { page_count?: number } }) => ({
      id: b.id,
      title: b.title,
      pageCount: b.primary_edition?.page_count ?? null,
    })
  );
}

async function apiPlace(
  request: APIRequestContext,
  token: string,
  shelf: ShelfKey,
  bookId: string
): Promise<number> {
  const resp = await request.post(`/api/bookshelves/${shelf}/placements`, {
    headers: { Authorization: `Bearer ${token}` },
    data: { book_id: bookId },
  });
  return resp.status();
}

/**
 * Navigate to a shelf page and wait for its browse API GET to resolve, so the
 * SPA has the real placement list before any presence/absence assertion. The
 * returned promise is registered BEFORE goto so the response cannot be missed.
 */
async function gotoShelf(page: Page, shelf: ShelfKey): Promise<void> {
  const settled = page.waitForResponse(
    (r) =>
      r.url().includes(`/api/bookshelves/${shelf}`) &&
      r.request().method() === "GET" &&
      r.status() === 200,
    { timeout: 20000 }
  );
  await page.goto(SHELF_PATH[shelf]);
  await settled;
}

/** The book button on a spine bookcase (Library/Antilibrary/Wish List). */
function shelfSpine(page: Page, bookId: string): Locator {
  return page.locator(`#spine-${bookId}`);
}

/**
 * The book spine on the Reading Pile, matched by its accessible name. A
 * substring match on the literal `Book: <title> by` anchors the title between
 * the label's two fixed fragments — no RegExp construction (semgrep
 * detect-non-literal-regexp), same selectivity.
 */
function pileSpine(page: Page, title: string): Locator {
  return page
    .locator(".book-pile")
    .getByLabel(`Book: ${title} by`, { exact: false });
}

/**
 * Open the book-detail overlay for a specific book by clicking its spine on a
 * spine bookcase. Clicking a spine on Page.Bookshelf opens the overlay in place
 * (the same affordance shelf-actions.spec.ts drives). The spine is a 3-D
 * transformed element, so we dispatch the click via evaluate to bypass
 * actionability occlusion checks, exactly as the sibling specs do.
 */
async function openOverlayFromShelf(page: Page, bookId: string): Promise<Locator> {
  const spine = shelfSpine(page, bookId);
  await expect(spine).toBeAttached({ timeout: 10000 });
  await spine.evaluate((el) => (el as HTMLElement).click());
  const overlay = page.getByTestId("book-overlay");
  await expect(overlay).toBeVisible({ timeout: 10000 });
  return overlay;
}

/**
 * Open the book-detail overlay from the Reading Pile. A piled book selects on
 * first interaction and navigates on the second; hovering pre-selects it, so a
 * hover followed by a click opens the overlay. Falls back to a second click if
 * the first only selected.
 */
async function openOverlayFromPile(page: Page): Promise<Locator> {
  const book = page.locator(".book-pile .book-pile__book").first();
  await expect(book).toBeVisible({ timeout: 10000 });
  await book.hover();
  await book.click({ force: true });
  const overlay = page.getByTestId("book-overlay");
  if (!(await overlay.isVisible())) {
    await book.click({ force: true });
  }
  await expect(overlay).toBeVisible({ timeout: 10000 });
  return overlay;
}

/**
 * Drive the overlay's shelf mover to move the open book to `target` and wait
 * for the success confirmation. Asserts the specific success text so a silent
 * no-op or a different error banner cannot masquerade as success.
 */
async function moveViaOverlay(overlay: Locator, target: ShelfKey): Promise<void> {
  await overlay.locator('button:has-text("Choose Bookshelf")').click();
  await expect(overlay.locator(".shelf-mover")).toBeVisible();
  await overlay.getByTestId("shelf-mover-select").selectOption(target);
  await overlay.getByTestId("shelf-mover-btn").click();
  const success = overlay.locator(".book-detail__status--success");
  await expect(success).toBeVisible({ timeout: 10000 });
  await expect(success).toHaveText("Moved successfully.");
}

/**
 * Assert the moved book IS present on its destination spine bookcase. Waiting
 * for the specific spine to be visible inherently waits for the shelf's browse
 * data to load, so this doubles as the "destination has finished loading"
 * signal that must precede the source-absence check.
 */
async function expectPresentOnShelf(
  page: Page,
  shelf: ShelfKey,
  bookId: string
): Promise<void> {
  await gotoShelf(page, shelf);
  await expect(shelfSpine(page, bookId)).toBeVisible({ timeout: 10000 });
}

/**
 * Assert the book is ABSENT from a now-empty spine bookcase. Waits for the
 * definitive "loaded and empty" state (`bookshelf-empty`) before asserting the
 * spine is gone, so the absence cannot pass while the shelf is still loading.
 */
async function expectAbsentFromEmptyShelf(
  page: Page,
  shelf: ShelfKey,
  bookId: string
): Promise<void> {
  await gotoShelf(page, shelf);
  await expect(page.getByTestId("bookshelf-empty")).toBeVisible({
    timeout: 10000,
  });
  await expect(shelfSpine(page, bookId)).toHaveCount(0);
}

/** Reading Pile variants of the two assertions above. */
async function expectPresentOnPile(page: Page, title: string): Promise<void> {
  await gotoShelf(page, "reading_pile");
  await expect(pileSpine(page, title)).toBeVisible({ timeout: 10000 });
}

async function expectPileEmpty(page: Page, title: string): Promise<void> {
  await gotoShelf(page, "reading_pile");
  await expect(
    page.getByText("Nothing on the pile right now.", { exact: false })
  ).toBeVisible({ timeout: 10000 });
  await expect(pileSpine(page, title)).toHaveCount(0);
}

const SKIP_MSG =
  "POST /api/test/session unavailable (STACKS_E2E_TEST_HELPERS off)";

test.describe("Reading journey (#116)", () => {
  test("move-browse regression: a browser move re-homes the book across browse listings", async ({
    page,
    request,
  }) => {
    // The Phase-1 bug: move_book updated bookshelf_id but not shelf_id, so a
    // moved book stayed on the SOURCE browse and never appeared on the TARGET.
    // This drives the fix end-to-end through the two browse listings.
    const session = await mintSession(request, { displayName: "Move Browse" });
    test.skip(session === null, SKIP_MSG);
    if (!session) return;

    const books = await catalogueBooks(request);
    test.skip(books.length < 1, "needs at least 1 catalogue book");
    const book = books[0];

    expect(await apiPlace(request, session.token, "wishlist", book.id)).toBe(201);

    await injectSession(page, session);

    // Move wishlist → antilibrary in the browser, via the overlay's mover.
    await gotoShelf(page, "wishlist");
    const overlay = await openOverlayFromShelf(page, book.id);
    await moveViaOverlay(overlay, "antilibrary");

    // Browse assertions on the SPECIFIC book (not counts): present on the
    // destination, absent from the (now empty) source.
    await expectPresentOnShelf(page, "antilibrary", book.id);
    await expectAbsentFromEmptyShelf(page, "wishlist", book.id);
  });

  test("abandon journey: reading pile → antilibrary", async ({
    page,
    request,
  }) => {
    const session = await mintSession(request, { displayName: "Abandoner" });
    test.skip(session === null, SKIP_MSG);
    if (!session) return;

    const books = await catalogueBooks(request);
    test.skip(books.length < 1, "needs at least 1 catalogue book");
    const book = books[0];

    expect(await apiPlace(request, session.token, "reading_pile", book.id)).toBe(
      201
    );

    await injectSession(page, session);

    // Move off the pile via the overlay (opened from the pile itself).
    await gotoShelf(page, "reading_pile");
    const overlay = await openOverlayFromPile(page);
    await moveViaOverlay(overlay, "antilibrary");

    await expectPresentOnShelf(page, "antilibrary", book.id);
    await expectPileEmpty(page, book.title);
  });

  test("full reading journey: wishlist → antilibrary → reading pile → library", async ({
    page,
    request,
  }) => {
    const session = await mintSession(request, { displayName: "Journeyer" });
    test.skip(session === null, SKIP_MSG);
    if (!session) return;

    const books = await catalogueBooks(request);
    test.skip(books.length < 1, "needs at least 1 catalogue book");
    const book = books[0];

    expect(await apiPlace(request, session.token, "wishlist", book.id)).toBe(201);
    await injectSession(page, session);

    // Hop 1: wishlist → antilibrary.
    await gotoShelf(page, "wishlist");
    await moveViaOverlay(await openOverlayFromShelf(page, book.id), "antilibrary");
    await expectPresentOnShelf(page, "antilibrary", book.id);
    await expectAbsentFromEmptyShelf(page, "wishlist", book.id);

    // Hop 2: antilibrary → reading pile.
    await gotoShelf(page, "antilibrary");
    await moveViaOverlay(
      await openOverlayFromShelf(page, book.id),
      "reading_pile"
    );
    await expectPresentOnPile(page, book.title);
    await expectAbsentFromEmptyShelf(page, "antilibrary", book.id);

    // Hop 3: reading pile → library.
    await gotoShelf(page, "reading_pile");
    await moveViaOverlay(await openOverlayFromPile(page), "library");
    await expectPresentOnShelf(page, "library", book.id);
    await expectPileEmpty(page, book.title);
  });

  test("re-read round-trip: library → reading pile → library", async ({
    page,
    request,
  }) => {
    const session = await mintSession(request, { displayName: "Re-reader" });
    test.skip(session === null, SKIP_MSG);
    if (!session) return;

    const books = await catalogueBooks(request);
    test.skip(books.length < 1, "needs at least 1 catalogue book");
    const book = books[0];

    expect(await apiPlace(request, session.token, "library", book.id)).toBe(201);
    await injectSession(page, session);

    // library → reading pile.
    await gotoShelf(page, "library");
    await moveViaOverlay(
      await openOverlayFromShelf(page, book.id),
      "reading_pile"
    );
    await expectPresentOnPile(page, book.title);
    await expectAbsentFromEmptyShelf(page, "library", book.id);

    // reading pile → library (the re-read hop).
    await gotoShelf(page, "reading_pile");
    await moveViaOverlay(await openOverlayFromPile(page), "library");
    await expectPresentOnShelf(page, "library", book.id);
    await expectPileEmpty(page, book.title);
  });

  test("progress journey: set page, hit the ceiling, correct, persist, finish, record", async ({
    page,
    request,
  }) => {
    const session = await mintSession(request, { displayName: "Reader" });
    test.skip(session === null, SKIP_MSG);
    if (!session) return;

    const books = await catalogueBooks(request);
    // Need a book with a KNOWN page count so the ceiling is enforceable and the
    // "p. X / Y" line can render.
    const paged = books.find((b) => b.pageCount !== null && b.pageCount >= 10);
    test.skip(
      paged === undefined,
      "needs a catalogue book with a primary-edition page count >= 10"
    );
    if (!paged) return;
    const pageCount = paged.pageCount as number;
    const validPage = Math.max(1, Math.floor(pageCount / 2));

    expect(
      await apiPlace(request, session.token, "reading_pile", paged.id)
    ).toBe(201);
    await injectSession(page, session);

    await gotoShelf(page, "reading_pile");
    await expect(pileSpine(page, paged.title)).toBeVisible({ timeout: 10000 });

    // Open the status form via the badge (aria-expanded reflects the toggle).
    const badge = page.getByTestId("reading-status-badge");
    await expect(badge).toBeVisible({ timeout: 10000 });
    await expect(badge).toHaveAttribute("aria-expanded", "false");
    await badge.click();
    await expect(badge).toHaveAttribute("aria-expanded", "true");

    const form = page.getByTestId("reading-status-form");
    await expect(form).toBeVisible();

    // Set status Reading so the page input appears, then enter a page past the
    // end of the book — the ceiling must reject it.
    await form.getByTestId("status-select").selectOption("reading");
    const pageInput = form.getByTestId("current-page-input");
    await expect(pageInput).toBeVisible();
    await pageInput.fill("999999");
    await form.getByTestId("save-progress-btn").click();

    // Validation error surfaced as an alert; form stays open with the draft.
    const alert = page.getByTestId("progress-error");
    await expect(alert).toBeVisible({ timeout: 10000 });
    await expect(alert).toHaveAttribute("role", "alert");
    await expect(form).toBeVisible();
    await expect(pageInput).toHaveValue("999999");

    // Correct to a valid page and save — the form closes and progress renders.
    await pageInput.fill(String(validPage));
    await form.getByTestId("save-progress-btn").click();
    await expect(form).toBeHidden({ timeout: 10000 });

    const progress = page.getByTestId("reading-progress");
    await expect(progress).toBeVisible({ timeout: 10000 });
    await expect(progress).toHaveText(`p. ${validPage} / ${pageCount}`);

    // Persistence across a reload.
    await gotoShelf(page, "reading_pile");
    await expect(page.getByTestId("reading-status-badge")).toHaveText("Reading", {
      timeout: 10000,
    });
    await expect(page.getByTestId("reading-progress")).toHaveText(
      `p. ${validPage} / ${pageCount}`
    );

    // Mark Finished → the "record this read?" bridge prompt appears.
    await page.getByTestId("reading-status-badge").click();
    const form2 = page.getByTestId("reading-status-form");
    await expect(form2).toBeVisible();
    await form2.getByTestId("status-select").selectOption("completed");
    await form2.getByTestId("save-progress-btn").click();

    const finishedPrompt = page.getByTestId("finished-read-prompt");
    await expect(finishedPrompt).toBeVisible({ timeout: 10000 });

    // Record the read → the book leaves the pile and lands on the Library.
    await finishedPrompt.getByTestId("record-read-btn").click();
    await expect(pileSpine(page, paged.title)).toHaveCount(0, { timeout: 10000 });
    await expectPresentOnShelf(page, "library", paged.id);
  });
});
