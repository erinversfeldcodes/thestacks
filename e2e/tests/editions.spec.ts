import { test, expect, Page } from "@playwright/test";
import { suiteAuthFile, assertSeedOrSkip } from "./helpers";

test.use({ storageState: suiteAuthFile("editions") });

/**
 * Helper: find a multi-edition book from the catalogue API
 * and open it via the catalogue overlay.
 */
async function findMultiEditionBookId(page: Page): Promise<string | null> {
  await page.goto("/catalogue");
  return page.evaluate(async () => {
    const resp = await fetch("/api/catalogue?per_page=200");
    const data = await resp.json();
    const book = data.books.find((b: any) => b.edition_count > 1);
    return book?.id ?? null;
  });
}

/**
 * Open a book's detail overlay by clicking its card in the catalogue.
 * The overlay has role="dialog" and contains .book-detail__parchment.
 */
async function openBookOverlayFromCatalogue(page: Page, bookId: string): Promise<void> {
  await page.goto("/catalogue");
  await page.getByTestId('catalogue-grid').waitFor({ timeout: 10000 });

  // Find and click the card link for this specific book. `bookId` comes from
  // findMultiEditionBookId, which reads the same default-sorted catalogue the
  // page renders, so the target card is always on the first page. Assert its
  // presence rather than silently falling back to the first card — that
  // fallback would open the WRONG (possibly single-edition) book and make the
  // caller's edition assertions vacuous.
  const cardLink = page.locator(`.catalogue__card-link[href="/books/${bookId}"], .catalogue__card-link[data-book-id="${bookId}"]`).first();
  await expect(cardLink).toBeVisible({ timeout: 10000 });
  await cardLink.click();

  // Wait for the overlay to appear
  await expect(page.locator('[role="dialog"]')).toBeVisible({ timeout: 5000 });
  await page.waitForSelector('[role="dialog"] [data-testid="book-overlay"], [data-testid="book-overlay"]', { timeout: 10000 });
}

async function findPlacedBookId(page: Page): Promise<string | null> {
  await page.goto("/library");
  return page.evaluate(async () => {
    const auth = JSON.parse(localStorage.getItem("stacks-auth") || "{}");
    const resp = await fetch("/api/bookshelves/library", {
      headers: { Authorization: `Bearer ${auth.token}` },
    });
    if (!resp.ok) return null;
    const data = await resp.json();
    // API returns {shelves: [{placements: [...]}]} after #151 shelf entity change
    const allPlacements = (data.shelves ?? []).flatMap((s: any) => s.placements ?? []);
    return allPlacements[0]?.book?.id ?? null;
  });
}

/**
 * Open a placed book's detail overlay by clicking it on the library shelf.
 */
async function openPlacedBookOverlay(page: Page): Promise<void> {
  await page.goto("/library");
  await page.waitForSelector(".bookcase", { timeout: 10000 });

  const bookButton = page.getByTestId('book-spine').first();
  await expect(bookButton).toBeAttached({ timeout: 10000 });
  await bookButton.evaluate((el) => (el as HTMLElement).click());

  await expect(page.locator('[role="dialog"]')).toBeVisible({ timeout: 5000 });
}

test.describe("Book Detail — Editions", () => {
  test("edition selector appears for books with multiple editions", async ({
    page,
  }) => {
    const bookId = await findMultiEditionBookId(page);
    assertSeedOrSkip(!!bookId, "No multi-edition books in seed data");
    await openBookOverlayFromCatalogue(page, bookId!);

    const overlay = page.locator('[role="dialog"]');
    await expect(
      overlay.getByTestId('edition-selector')
    ).toBeVisible();
  });

  test("edition selector has all editions listed", async ({ page }) => {
    const bookId = await findMultiEditionBookId(page);
    assertSeedOrSkip(!!bookId, "No multi-edition books in seed data");
    await openBookOverlayFromCatalogue(page, bookId!);

    const overlay = page.locator('[role="dialog"]');
    await expect(
      overlay.getByTestId('edition-selector')
    ).toBeVisible({ timeout: 10000 });

    const options = await overlay
      .getByTestId('edition-selector').locator("option")
      .count();
    expect(options).toBeGreaterThanOrEqual(2);
  });

  test("selecting a different edition updates the displayed ISBN", async ({
    page,
  }) => {
    const bookId = await findMultiEditionBookId(page);
    assertSeedOrSkip(!!bookId, "No multi-edition books in seed data");
    await openBookOverlayFromCatalogue(page, bookId!);

    const overlay = page.locator('[role="dialog"]');
    const isbnBefore = await overlay.getByTestId('book-isbn').textContent();

    const select = overlay.getByTestId('edition-selector');
    const secondOption = await select
      .locator("option")
      .nth(1)
      .getAttribute("value");
    if (secondOption) {
      await select.selectOption(secondOption);
      await page.waitForTimeout(300);

      const isbnAfter = await overlay.getByTestId('book-isbn').textContent();
      expect(isbnAfter).not.toEqual(isbnBefore);
    }
  });

  test("edition selector does NOT appear for single-edition books", async ({
    page,
  }) => {
    await page.goto("/catalogue");
    const singleBookId = await page.evaluate(async () => {
      const resp = await fetch("/api/catalogue?per_page=200");
      const data = await resp.json();
      const book = data.books.find((b: any) => b.edition_count === 1);
      return book?.id ?? null;
    });
    assertSeedOrSkip(!!singleBookId, "No single-edition books in seed data");

    await openBookOverlayFromCatalogue(page, singleBookId!);

    const overlay = page.locator('[role="dialog"]');
    await expect(
      overlay.getByTestId('edition-selector')
    ).not.toBeVisible();
  });

  test("edition details section shows metadata", async ({ page }) => {
    const bookId = await findMultiEditionBookId(page);
    assertSeedOrSkip(!!bookId, "No multi-edition books in seed data");
    await openBookOverlayFromCatalogue(page, bookId!);

    const overlay = page.locator('[role="dialog"]');
    await expect(overlay.locator(".book-detail__meta-details")).toBeVisible();
    await expect(overlay.getByTestId('book-isbn')).toBeVisible();
  });
});

test.describe("Book Detail — Formats on My Shelf", () => {
  test("formats section visible when book is on a shelf", async ({ page }) => {
    const placedBookId = await findPlacedBookId(page);
    assertSeedOrSkip(!!placedBookId, "No placed books on library shelf");

    await openPlacedBookOverlay(page);

    const overlay = page.locator('[role="dialog"]');
    await expect(
      overlay.locator(".book-detail__section-title", {
        hasText: "Formats on My Shelf",
      })
    ).toBeVisible({ timeout: 10000 });
  });

  test("format picker buttons are visible under formats section", async ({
    page,
  }) => {
    const placedBookId = await findPlacedBookId(page);
    assertSeedOrSkip(!!placedBookId, "No placed books on library shelf");

    await openPlacedBookOverlay(page);

    const overlay = page.locator('[role="dialog"]');
    await expect(
      overlay.locator(".book-detail__section-title", {
        hasText: "Formats on My Shelf",
      })
    ).toBeVisible({ timeout: 10000 });

    const formatBtns = overlay.locator(".format-picker__btn");
    expect(await formatBtns.count()).toBe(3);
  });

  test("toggling a format changes its selected state", async ({ page }) => {
    const placedBookId = await findPlacedBookId(page);
    assertSeedOrSkip(!!placedBookId, "No placed books on library shelf");

    await openPlacedBookOverlay(page);

    const overlay = page.locator('[role="dialog"]');
    const physicalBtn = overlay.locator(".format-picker__btn").first();
    await expect(physicalBtn).toBeVisible({ timeout: 5000 });
    await physicalBtn.click();

    await expect(physicalBtn).toHaveAttribute("aria-pressed", "true");
  });

  test("formats section NOT visible for unplaced books", async ({ page }) => {
    await page.goto("/catalogue");
    const unplacedBookId = await page.evaluate(async () => {
      const auth = JSON.parse(localStorage.getItem("stacks-auth") || "{}");
      const placementsResp = await fetch("/api/placements/mine", {
        headers: { Authorization: `Bearer ${auth.token}` },
      });
      const placementsData = placementsResp.ok
        ? await placementsResp.json()
        : { placements: [] };
      const placedIds = new Set(
        placementsData.placements.map((p: any) => p.book_id)
      );
      const catResp = await fetch("/api/catalogue?per_page=200");
      const catData = await catResp.json();
      const book = catData.books.find((b: any) => !placedIds.has(b.id));
      return book?.id ?? null;
    });
    assertSeedOrSkip(!!unplacedBookId, "All books are placed");

    await openBookOverlayFromCatalogue(page, unplacedBookId!);

    const overlay = page.locator('[role="dialog"]');
    await expect(
      overlay.locator(".book-detail__section-title", {
        hasText: "Formats on My Shelf",
      })
    ).not.toBeVisible();
  });
});
