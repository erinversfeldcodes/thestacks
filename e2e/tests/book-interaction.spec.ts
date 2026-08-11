import { test, expect } from "@playwright/test";
import { suiteAuthFile, ensureBookOnLibrary } from "./helpers";

test.use({ storageState: suiteAuthFile("book-interaction") });

test.beforeEach(async ({ page }) => {
  await ensureBookOnLibrary(page);
});

test.describe("Book interaction — Library page", () => {
  test("book exists on the shelf and is wrapped in a clickable button", async ({
    page,
  }) => {
    await page.goto("/library");
    await page.waitForSelector(".bookcase, .shelf-room, .empty-shelf", { timeout: 10000 });

    const books = page.locator(".book");
    await expect(books.first()).toBeAttached({ timeout: 10000 });

    const bookButton = page.getByTestId('book-spine').first();
    await expect(bookButton).toBeAttached();

    const isVisible = await bookButton.isVisible();
    expect(isVisible).toBeTruthy();
  });

  test("clicking a book opens the book detail overlay", async ({ page }) => {
    await page.goto("/library");
    await page.waitForSelector(".bookcase, .shelf-room, .empty-shelf", { timeout: 10000 });

    const bookButton = page.getByTestId('book-spine').first();
    await expect(bookButton).toBeAttached({ timeout: 10000 });

    await bookButton.evaluate((el) => (el as HTMLElement).click());

    const overlay = page.locator('[role="dialog"]');
    await expect(overlay).toBeVisible({ timeout: 5000 });

    const detailTitle = overlay.getByTestId('book-title');
    await expect(detailTitle).toBeVisible({ timeout: 5000 });
    const titleText = await detailTitle.textContent();
    expect(titleText).toBeTruthy();
    expect(titleText!.length).toBeGreaterThan(0);
  });

  test("hovering over a book triggers 3D transform animation", async ({
    page,
  }) => {
    await page.goto("/library");
    await page.waitForSelector(".bookcase, .shelf-room, .empty-shelf", { timeout: 10000 });

    const book = page.locator(".book").first();
    await expect(book).toBeAttached({ timeout: 10000 });

    const hasBookPullOut = await page.evaluate(() => {
      for (const sheet of document.styleSheets) {
        try {
          for (const rule of sheet.cssRules) {
            if (rule instanceof CSSKeyframesRule && rule.name === 'book-pull-out') {
              return true;
            }
          }
        } catch (e) { /* cross-origin stylesheet */ }
      }
      return false;
    });

    console.log(`@keyframes book-pull-out found: ${hasBookPullOut}`);
    expect(hasBookPullOut).toBeTruthy();

    const hoverAnimation = await page.evaluate(() => {
      for (const sheet of document.styleSheets) {
        try {
          for (const rule of sheet.cssRules) {
            if (rule instanceof CSSStyleRule && rule.selectorText === '.book:hover') {
              return rule.style.animationName || rule.style.animation;
            }
          }
        } catch (e) { /* cross-origin stylesheet */ }
      }
      return null;
    });

    console.log(`Hover animation: ${hoverAnimation}`);
    expect(hoverAnimation).toContain("book-pull-out");
  });

  test("book spine shows texture background image", async ({ page }) => {
    await page.goto("/library");
    await page.waitForSelector(".bookcase, .shelf-room, .empty-shelf", { timeout: 10000 });

    const spine = page.locator(".book__spine").first();
    await expect(spine).toBeAttached({ timeout: 10000 });

    const bgImage = await spine.evaluate(
      (el) => getComputedStyle(el).backgroundImage
    );

    console.log(`Spine background-image: ${bgImage}`);

    expect(bgImage).not.toEqual("none");
    expect(bgImage).toContain("/textures/");
    expect(bgImage).toContain(".png");
  });

  test("book has 3D structure: spine, top, and cover faces", async ({
    page,
  }) => {
    await page.goto("/library");
    await page.waitForSelector(".bookcase, .shelf-room, .empty-shelf", { timeout: 10000 });

    const book = page.locator(".book").first();
    await expect(book).toBeAttached({ timeout: 10000 });

    const transformStyle = await book.evaluate(
      (el) => getComputedStyle(el).transformStyle
    );
    expect(transformStyle).toEqual("preserve-3d");

    const spine = book.locator(".book__spine");
    const top = book.locator(".book__top");
    const cover = book.locator(".book__cover");

    await expect(spine).toBeAttached();
    await expect(top).toBeAttached();
    await expect(cover).toBeAttached();

    const titleText = await spine
      .locator(".book__title")
      .textContent()
      .catch(() => "");
    expect(titleText!.length).toBeGreaterThan(0);
  });
});
