import { test, expect } from "@playwright/test";
import {
  provisionBookOnShelf,
  assertSeedOrSkip,
  injectSession,
  mintOrSkip,
} from "./helpers";

/**
 * Shelf-actions flagship suite — move, add, and remove a book through the real
 * book-detail overlay and catalogue, driven in a real browser against a live
 * stack.
 *
 * Every test mints its OWN fresh, confirmed, empty-collection user via
 * POST /api/test/session (STACKS_E2E_TEST_HELPERS=1 only; skips cleanly where
 * the helper is off) and provisions exactly the placements it mutates via the
 * normal placement API (provisionBookOnShelf). Previously the suite shared one
 * seeded user and its real move/remove tests drained that user's library shelf
 * on every local run without restoring it, flaking repeated local iteration
 *. Per-test provisioning
 * makes the suite self-restoring: each test builds the exact shelf state it
 * asserts against, so runs are deterministic and independent — the
 * spine-rendering pattern applied here. Isolated users make the specs safe to
 * run fully parallel.
 *
 * The mutation-failure describe mints+provisions the same way but mocks
 * only the mutation request, exercising the genuine failure-copy branches a
 * healthy API never produces.
 */

test.describe("Shelf actions — move book between shelves", () => {
  test("move a book from library to wishlist via book detail overlay", async ({
    page,
    request,
  }) => {
    await provisionBookOnShelf(page, request, "library");

    await page.goto("/library");
    await page.waitForSelector(".bookcase", { timeout: 10000 });

    const bookButton = page.getByTestId('book-spine').first();
    await expect(bookButton).toBeAttached({ timeout: 10000 });
    await bookButton.evaluate((el) => (el as HTMLElement).click());

    const overlay = page.getByTestId('book-overlay');
    await expect(overlay).toBeVisible({ timeout: 10000 });

    const shelfTitle = overlay.locator(".book-detail__section-title", {
      hasText: "Move to Shelf from Library",
    });
    await expect(shelfTitle).toBeVisible({ timeout: 5000 });

    await overlay.locator('button:has-text("Choose Bookshelf")').click();
    await expect(overlay.locator(".shelf-mover")).toBeVisible();

    await overlay.getByTestId('shelf-mover-select').selectOption("wishlist");

    await overlay.locator('button:text-is("Move")').click();

    await expect(
      overlay.locator(".book-detail__status--success")
    ).toBeVisible({ timeout: 5000 });

    const updatedTitle = overlay.locator(".book-detail__section-title", {
      hasText: "Move to Shelf from Wish List",
    });
    await expect(updatedTitle).toBeVisible();
  });
});

test.describe("Shelf actions — add book from catalogue", () => {
  test("add an unplaced book to a shelf from the catalogue", async ({
    page,
    request,
  }) => {
    await provisionBookOnShelf(page, request, "library");

    await page.goto("/catalogue");
    await page.getByTestId('catalogue-grid').waitFor({ timeout: 10000 });

    await page.waitForTimeout(1000);

    const initialBadges = await page.locator(".catalogue__card-badge").count();

    const addButton = page.locator(".catalogue__card-add").first();
    assertSeedOrSkip(
      (await addButton.count()) > 0,
      "No unplaced books visible in catalogue"
    );

    await addButton.click();

    await expect(
      page.locator(".catalogue__card-picker").first()
    ).toBeVisible({ timeout: 3000 });

    await page
      .locator('.catalogue__card-picker-option:has-text("Library")')
      .first()
      .click();

    await page.waitForTimeout(2000);

    const finalBadges = await page.locator(".catalogue__card-badge").count();
    expect(finalBadges).toBeGreaterThanOrEqual(initialBadges + 1);
  });
});

test.describe("Shelf actions — add unplaced book from detail overlay", () => {
  test("open an unplaced book detail overlay and add to collection", async ({
    page,
    request,
  }) => {
    await provisionBookOnShelf(page, request, "library");

    // Register the placements response listener BEFORE navigating so we cannot miss it.
    // Elm fetches /api/placements/mine on catalogue init; we must wait for it to complete
    // before querying .catalogue__card-add, otherwise the race condition causes us to click
    // a placed book that temporarily shows an add button while placements are still loading.
    const placementsLoaded = page.waitForResponse(
      (resp) =>
        resp.url().includes("/api/placements/mine") && resp.status() === 200,
      { timeout: 15000 }
    );

    await page.goto("/catalogue");
    await page.getByTestId("catalogue-grid").waitFor({ timeout: 10000 });

    await placementsLoaded;

    const unplacedHref = await page.evaluate(async () => {
      const auth = JSON.parse(localStorage.getItem("stacks-auth") || "{}");
      if (!auth.token) return null;
      const resp = await fetch("/api/placements/mine", {
        headers: { Authorization: `Bearer ${auth.token}` },
      });
      const data = resp.ok ? await resp.json() : { placements: [] };
      const placedIds = new Set(
        (data.placements as Array<{ book_id: string }>).map((p) => p.book_id)
      );
      const cards = document.querySelectorAll(
        ".catalogue__card:has(.catalogue__card-add)"
      );
      for (const card of Array.from(cards)) {
        const link = card.querySelector(
          ".catalogue__card-link"
        ) as HTMLAnchorElement | null;
        if (!link) continue;
        const href = link.getAttribute("href") ?? "";
        const bookId = href.split("/books/")[1];
        if (bookId && !placedIds.has(bookId)) return href;
      }
      return null;
    });

    assertSeedOrSkip(
      unplacedHref !== null,
      "No unplaced books visible in catalogue"
    );

    await page
      .locator(`.catalogue__card-link[href="${unplacedHref}"]`)
      .click();

    const overlay = page.getByTestId('book-overlay');
    await expect(overlay).toBeVisible({ timeout: 10000 });

    await expect(
      overlay.locator('button:has-text("Remove from collection")')
    ).not.toBeVisible();

    const addSection = overlay.locator(".book-detail__section-title", {
      hasText: "Add to Collection",
    });
    await expect(addSection).toBeVisible({ timeout: 10000 });

    await overlay.locator('button:has-text("Choose Bookshelf")').click();
    await expect(overlay.locator(".shelf-mover")).toBeVisible();

    await overlay.getByTestId('shelf-mover-select').selectOption("antilibrary");
    await overlay.getByTestId('shelf-mover-btn').click();

    await expect(
      overlay.locator(".book-detail__status--success")
    ).toBeVisible({ timeout: 5000 });
    await expect(
      overlay.locator(".book-detail__section-title", {
        hasText: "Move to Shelf from Antilibrary",
      })
    ).toBeVisible();
  });
});

test.describe("Shelf actions — remove book from collection", () => {
  test("remove button only visible when book has a placement", async ({
    page,
    request,
  }) => {
    await provisionBookOnShelf(page, request, "library");
    await page.goto("/library");
    await page.waitForSelector(".bookcase", { timeout: 10000 });

    const bookButton = page.getByTestId('book-spine').first();
    await expect(bookButton).toBeVisible({ timeout: 10000 });
    await bookButton.evaluate((el) => (el as HTMLElement).click());

    const overlay = page.getByTestId('book-overlay');
    await expect(overlay).toBeVisible({ timeout: 10000 });

    await expect(
      overlay.locator('button:has-text("Remove from collection")')
    ).toBeVisible({ timeout: 5000 });
  });

  test("remove button triggers modal and confirm removes the book", async ({
    page,
    request,
  }) => {
    await provisionBookOnShelf(page, request, "library");
    await page.goto("/library");
    await page.waitForSelector(".bookcase", { timeout: 10000 });

    const bookButton = page.getByTestId('book-spine').first();
    await expect(bookButton).toBeVisible({ timeout: 10000 });
    await bookButton.evaluate((el) => (el as HTMLElement).click());

    const overlay = page.getByTestId('book-overlay');
    await expect(overlay).toBeVisible({ timeout: 10000 });

    await overlay.locator('button:has-text("Remove from collection")').click();

    await expect(page.getByTestId('remove-book-modal')).toBeVisible({ timeout: 3000 });

    const confirmBtn = page.getByTestId('remove-book-confirm');
    await expect(confirmBtn).toBeVisible();
    await confirmBtn.click();

    await expect(overlay).not.toBeVisible({ timeout: 10000 });
    await expect(page).toHaveURL(/\/library/, { timeout: 10000 });
  });
});

test.describe("Shelf actions — mutation failures", () => {

  async function openLibraryOverlay(
    page: import("@playwright/test").Page,
    request: import("@playwright/test").APIRequestContext
  ) {
    await provisionBookOnShelf(page, request, "library");
    await page.goto("/library");
    await page.waitForSelector(".bookcase", { timeout: 10000 });
    const bookButton = page.getByTestId("book-spine").first();
    await expect(bookButton).toBeAttached({ timeout: 10000 });
    await bookButton.evaluate((el) => (el as HTMLElement).click());
    const overlay = page.getByTestId("book-overlay");
    await expect(overlay).toBeVisible({ timeout: 10000 });
    return overlay;
  }

  test("move failure (403) shows the move-error message", async ({
    page,
    request,
  }) => {
    await page.route("**/api/placements/*/move", (route) =>
      route.fulfill({
        status: 403,
        contentType: "application/json",
        body: JSON.stringify({ error: "forbidden" }),
      })
    );

    const overlay = await openLibraryOverlay(page, request);
    await overlay.locator('button:has-text("Choose Bookshelf")').click();
    await expect(overlay.locator(".shelf-mover")).toBeVisible();
    await overlay.getByTestId("shelf-mover-select").selectOption("wishlist");
    await overlay.locator('button:text-is("Move")').click();

    await expect(overlay.locator(".book-detail__status--error")).toHaveText(
      "Failed to move book. Please try again.",
      { timeout: 5000 }
    );
    await expect(overlay).toBeVisible();
  });

  test("remove failure (500) shows the remove-error message", async ({
    page,
    request,
  }) => {
    await page.route("**/api/placements/*", async (route) => {
      if (route.request().method() === "DELETE") {
        await route.fulfill({
          status: 500,
          contentType: "application/json",
          body: JSON.stringify({ error: "server_error" }),
        });
      } else {
        await route.fallback();
      }
    });

    const overlay = await openLibraryOverlay(page, request);
    await overlay.locator('button:has-text("Remove from collection")').click();

    await expect(page.getByTestId("remove-book-modal")).toBeVisible({
      timeout: 3000,
    });
    await page.getByTestId("remove-book-confirm").click();

    await expect(overlay.locator(".book-detail__status--error")).toHaveText(
      "Failed to remove book. Please try again.",
      { timeout: 5000 }
    );
    await expect(overlay).toBeVisible();
  });
});

/**
 * The overlay opens ON TOP of the shelf page, which stays mounted underneath.
 * Drive evidence: after a move the server was right and the bookcase behind the
 * overlay was wrong — it still showed the book on the shelf it had just left,
 * and stayed wrong until the reader pressed reload.
 *
 * These tests therefore never reload. `window.__noReloadSentinel` is planted
 * before the move and read after it: a full page load would wipe it, so its
 * survival is what makes "without a reload" an assertion rather than a claim
 * about how the test happens to be written.
 *
 * The count assertions run while the overlay is still open, before it is
 * dismissed. Asserting only after dismissal would leave a second explanation
 * standing (that closing the overlay is what rebuilt the page), and the shelf
 * has to be correct the moment the write lands, not the moment the reader
 * looks away.
 */
test.describe("Shelf actions — the page behind the overlay after a move", () => {
  /** Place `count` distinct catalogue books on `shelf` for one fresh user. */
  async function provisionBooksOnShelf(
    page: import("@playwright/test").Page,
    request: import("@playwright/test").APIRequestContext,
    shelf: string,
    count: number,
  ): Promise<void> {
    const session = await mintOrSkip(request);
    const resp = await request.get(`/api/catalogue?per_page=${count}`);
    expect(resp.ok(), "catalogue fetch for shelf provisioning").toBeTruthy();
    const books = ((await resp.json()).books ?? []) as Array<{ id: string }>;
    assertSeedOrSkip(
      books.length >= count,
      `catalogue has fewer than ${count} books to provision this shelf`,
    );
    for (const book of books.slice(0, count)) {
      const place = await request.post(`/api/bookshelves/${shelf}/placements`, {
        headers: { Authorization: `Bearer ${session.token}` },
        data: { book_id: book.id },
      });
      expect(place.status(), `place book on ${shelf}`).toBe(201);
    }
    await injectSession(page, session);
  }

  async function plantReloadSentinel(
    page: import("@playwright/test").Page,
  ): Promise<void> {
    await page.evaluate(() => {
      (window as unknown as { __noReloadSentinel: boolean })
        .__noReloadSentinel = true;
    });
  }

  async function expectNoReloadHappened(
    page: import("@playwright/test").Page,
  ): Promise<void> {
    const survived = await page.evaluate(
      () =>
        (window as unknown as { __noReloadSentinel?: boolean })
          .__noReloadSentinel === true,
    );
    expect(
      survived,
      "the page reloaded, so this proves nothing about live truth",
    ).toBe(true);
  }

  test("moving a book out of the library empties its place on the bookcase behind", async ({
    page,
    request,
  }) => {
    await provisionBooksOnShelf(page, request, "library", 2);

    await page.goto("/library");
    await page.waitForSelector(".bookcase", { timeout: 10000 });

    const shelvedBooks = page.locator(".bookcase").getByTestId("book-spine");
    await expect(shelvedBooks).toHaveCount(2, { timeout: 10000 });

    await plantReloadSentinel(page);

    await shelvedBooks.first().evaluate((el) => (el as HTMLElement).click());

    const overlay = page.getByTestId("book-overlay");
    await expect(overlay).toBeVisible({ timeout: 10000 });

    await overlay.locator('button:has-text("Choose Bookshelf")').click();
    await overlay.getByTestId("shelf-mover-select").selectOption("wishlist");
    await overlay.locator('button:text-is("Move")').click();

    await expect(overlay.locator(".book-detail__status--success")).toBeVisible({
      timeout: 5000,
    });

    await expect(shelvedBooks).toHaveCount(1, { timeout: 10000 });

    await overlay.getByTestId("book-overlay-close").click();
    await expect(overlay).not.toBeVisible({ timeout: 5000 });
    await expect(shelvedBooks).toHaveCount(1);
    await expect(page).toHaveURL((url) => url.pathname === "/library");

    await expectNoReloadHappened(page);
  });

  test("moving a book out of the reading pile takes it off the pile behind", async ({
    page,
    request,
  }) => {
    await provisionBooksOnShelf(page, request, "reading_pile", 2);

    await page.goto("/reading-pile");
    await page.getByTestId("reading-pile-page").waitFor({ timeout: 10000 });

    const piledBooks = page.locator(".book-pile__book");
    await expect(piledBooks).toHaveCount(2, { timeout: 10000 });

    await plantReloadSentinel(page);

    await piledBooks.first().click();

    const overlay = page.getByTestId("book-overlay");
    await expect(overlay).toBeVisible({ timeout: 10000 });

    await overlay.locator('button:has-text("Choose Bookshelf")').click();
    await overlay.getByTestId("shelf-mover-select").selectOption("library");
    await overlay.locator('button:text-is("Move")').click();

    await expect(overlay.locator(".book-detail__status--success")).toBeVisible({
      timeout: 5000,
    });

    await expect(piledBooks).toHaveCount(1, { timeout: 10000 });

    await overlay.getByTestId("book-overlay-close").click();
    await expect(overlay).not.toBeVisible({ timeout: 5000 });
    await expect(piledBooks).toHaveCount(1);
    await expect(page).toHaveURL((url) => url.pathname === "/reading-pile");

    await expectNoReloadHappened(page);
  });
});
