import { test, expect, Page } from "@playwright/test";
import { suiteAuthFile } from "./helpers";

test.use({ storageState: suiteAuthFile("editions") });

/**
 * Helper: navigate to the app root first (needed for localStorage access),
 * then find a multi-edition book from the catalogue API.
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

async function findPlacedBookId(page: Page): Promise<string | null> {
  await page.goto("/library");
  return page.evaluate(async () => {
    const auth = JSON.parse(localStorage.getItem("stacks-auth") || "{}");
    const resp = await fetch("/api/bookshelves/library", {
      headers: { Authorization: `Bearer ${auth.token}` },
    });
    if (!resp.ok) return null;
    const data = await resp.json();
    return data.placements?.[0]?.book?.id ?? null;
  });
}

test.describe("Book Detail — Editions", () => {
  test("edition selector appears for books with multiple editions", async ({
    page,
  }) => {
    const bookId = await findMultiEditionBookId(page);
    test.skip(!bookId, "No multi-edition books in seed data");
    await page.goto(`/books/${bookId}`);
    await page.waitForSelector(".book-detail__parchment", { timeout: 10000 });
    await expect(
      page.locator(".book-detail__edition-selector")
    ).toBeVisible();
  });

  test("edition selector has all editions listed", async ({ page }) => {
    const bookId = await findMultiEditionBookId(page);
    test.skip(!bookId, "No multi-edition books in seed data");
    await page.goto(`/books/${bookId}`);
    await page.waitForSelector(".book-detail__parchment", { timeout: 10000 });
    // Wait for edition selector to render
    await expect(
      page.locator(".book-detail__edition-select")
    ).toBeVisible({ timeout: 5000 });

    const options = await page
      .locator(".book-detail__edition-select option")
      .count();
    expect(options).toBeGreaterThanOrEqual(2);
  });

  test("selecting a different edition updates the displayed ISBN", async ({
    page,
  }) => {
    const bookId = await findMultiEditionBookId(page);
    test.skip(!bookId, "No multi-edition books in seed data");
    await page.goto(`/books/${bookId}`);
    await page.waitForSelector(".book-detail__parchment", { timeout: 10000 });

    const isbnBefore = await page.locator(".book-detail__isbn").textContent();

    const select = page.locator(".book-detail__edition-select");
    const secondOption = await select
      .locator("option")
      .nth(1)
      .getAttribute("value");
    if (secondOption) {
      await select.selectOption(secondOption);
      await page.waitForTimeout(300);

      const isbnAfter = await page.locator(".book-detail__isbn").textContent();
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
    test.skip(!singleBookId, "No single-edition books in seed data");

    await page.goto(`/books/${singleBookId}`);
    await page.waitForSelector(".book-detail__parchment", { timeout: 10000 });

    await expect(
      page.locator(".book-detail__edition-selector")
    ).not.toBeVisible();
  });

  test("edition details section shows metadata", async ({ page }) => {
    const bookId = await findMultiEditionBookId(page);
    test.skip(!bookId, "No multi-edition books in seed data");
    await page.goto(`/books/${bookId}`);
    await page.waitForSelector(".book-detail__parchment", { timeout: 10000 });

    await expect(page.locator(".book-detail__meta-details")).toBeVisible();
    await expect(page.locator(".book-detail__isbn")).toBeVisible();
  });
});

test.describe("Book Detail — Formats on My Shelf", () => {
  test("formats section visible when book is on a shelf", async ({ page }) => {
    const placedBookId = await findPlacedBookId(page);
    test.skip(!placedBookId, "No placed books on library shelf");

    await page.goto(`/books/${placedBookId}`);
    await page.waitForSelector(".book-detail", { timeout: 10000 });

    await expect(
      page.locator(".book-detail__section-title", {
        hasText: "Formats on My Shelf",
      })
    ).toBeVisible({ timeout: 5000 });
  });

  test("format picker buttons are visible under formats section", async ({
    page,
  }) => {
    const placedBookId = await findPlacedBookId(page);
    test.skip(!placedBookId, "No placed books on library shelf");

    await page.goto(`/books/${placedBookId}`);
    await page.waitForSelector(".book-detail", { timeout: 10000 });

    await expect(
      page.locator(".book-detail__section-title", {
        hasText: "Formats on My Shelf",
      })
    ).toBeVisible({ timeout: 5000 });

    const formatBtns = page.locator(".format-picker__btn");
    expect(await formatBtns.count()).toBe(3);
  });

  test("toggling a format changes its selected state", async ({ page }) => {
    const placedBookId = await findPlacedBookId(page);
    test.skip(!placedBookId, "No placed books on library shelf");

    await page.goto(`/books/${placedBookId}`);
    await page.waitForSelector(".book-detail", { timeout: 10000 });

    const physicalBtn = page.locator(".format-picker__btn").first();
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
    test.skip(!unplacedBookId, "All books are placed");

    await page.goto(`/books/${unplacedBookId}`);
    await page.waitForSelector(".book-detail__parchment", { timeout: 10000 });

    await expect(
      page.locator(".book-detail__section-title", {
        hasText: "Formats on My Shelf",
      })
    ).not.toBeVisible();
  });
});
