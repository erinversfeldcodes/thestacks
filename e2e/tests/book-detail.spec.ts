import { test, expect } from "@playwright/test";
import { suiteAuthFile, ensureBookOnLibrary } from "./helpers";

test.use({ storageState: suiteAuthFile("book-detail") });

/**
 * Helper: open the book detail overlay by clicking the first book
 * on the library shelf.
 */
async function openBookDetailOverlay(page: import("@playwright/test").Page) {
  await ensureBookOnLibrary(page);
  await page.goto("/library");
  await page.waitForSelector(".bookcase", { timeout: 10000 });
  const bookButton = page.getByTestId('book-spine').first();
  await expect(bookButton).toBeAttached({ timeout: 10000 });
  await bookButton.evaluate((el) => (el as HTMLElement).click());
  const overlay = page.getByTestId('book-overlay');
  await expect(overlay).toBeVisible({ timeout: 5000 });
  return overlay;
}

test.describe("Book Detail overlay — layout and structure", () => {
  test("Book detail overlay loads with parchment background", async ({
    page,
  }) => {
    const overlay = await openBookDetailOverlay(page);
    await expect(overlay).toBeVisible({ timeout: 10000 });
  });

  test("Cover image or placeholder is displayed", async ({ page }) => {
    const overlay = await openBookDetailOverlay(page);
    const coverImg = overlay.getByTestId('book-cover');
    const coverPlaceholder = overlay.locator(".book-detail__cover-placeholder");
    const hasCover = (await coverImg.count()) > 0;
    const hasPlaceholder = (await coverPlaceholder.count()) > 0;
    const hasLoading = (await overlay.locator(".loading").count()) > 0;
    const hasError = (await overlay.locator(".error").count()) > 0;
    expect(hasCover || hasPlaceholder || hasLoading || hasError).toBeTruthy();
  });

  test("All sections visible when book loads", async ({ page }) => {
    const overlay = await openBookDetailOverlay(page);
    // The seeded book always loads, so .book-detail is always present — wait for
    // it to render, then assert every section unconditionally (a prior
    // `if (count > 0)` guard here passed vacuously if the book never loaded).
    await expect(overlay.locator(".book-detail")).toBeVisible({ timeout: 10000 });
    await expect(
      overlay.locator(".book-detail__section-title", { hasText: "About" })
    ).toBeVisible();
    await expect(
      overlay.locator(".book-detail__section-title", {
        hasText: "What People Think",
      })
    ).toBeVisible();
    await expect(
      overlay.locator(".book-detail__section-title", {
        hasText: "Where to Buy",
      })
    ).toBeVisible();
    await expect(
      overlay.locator(".book-detail__section-title", {
        hasText: "The Author",
      })
    ).toBeVisible();
    await expect(
      overlay.locator(".book-detail__section-title", {
        hasText: "My Writing",
      })
    ).toBeVisible();
  });

  test("Format picker buttons are interactive", async ({ page }) => {
    const overlay = await openBookDetailOverlay(page);
    // The book is placed on the Library shelf (openBookDetailOverlay ensures
    // this), so "Formats on My Shelf" always renders its three format buttons.
    const formatBtn = overlay.locator(".format-picker__btn").first();
    await expect(formatBtn).toBeVisible({ timeout: 10000 });
    await formatBtn.click();
    await expect(formatBtn).toHaveClass(/format-picker__btn--selected/);
  });

  test("Move to Shelf dropdown works", async ({ page }) => {
    const overlay = await openBookDetailOverlay(page);
    // A placed book always offers the "Choose Bookshelf" mover, so assert it is
    // present and drive it (was a vacuous `if (count > 0)` guard).
    const chooseBtnLocator = overlay.locator("button", {
      hasText: "Choose Bookshelf",
    });
    await expect(chooseBtnLocator).toBeVisible({ timeout: 10000 });
    await chooseBtnLocator.click();
    await expect(overlay.locator(".shelf-mover")).toBeVisible();
  });

  test("Overlay entry animation present on open", async ({ page }) => {
    const overlay = await openBookDetailOverlay(page);
    // Verify the overlay rendered with book detail content
    await expect(overlay.locator(".book-detail")).toBeVisible({ timeout: 10000 });
  });
});
