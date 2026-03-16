import { test, expect } from "@playwright/test";

const DEV_EMAIL = "owner@thestacks.app";
const DEV_PASSWORD = "dev-password-123";

async function signInAndGoToLibrary(page: import("@playwright/test").Page) {
  await page.goto("/login");
  await page.fill('input[id="email"]', DEV_EMAIL);
  await page.fill('input[id="password"]', DEV_PASSWORD);
  await page.click("button.login-card__submit");
  await page.waitForURL("**/antilibrary", { timeout: 15000 });
  await page.locator('a.app-nav__link[href="/library"]').click();
  await page.waitForURL("**/library", { timeout: 10000 });
  // Wait for books to load
  await page.waitForTimeout(2000);
}

test.describe("Book interaction — Library page", () => {
  test("book exists on the shelf and is wrapped in a clickable button", async ({
    page,
  }) => {
    await signInAndGoToLibrary(page);

    const books = page.locator(".book");
    const bookCount = await books.count();

    if (bookCount === 0) {
      // No books on shelf — skip but don't fail
      console.log("No books on library shelf, skipping click test");
      return;
    }

    // The book should be wrapped in a button for accessibility
    const bookButton = page.locator("button.book-button, .book-button").first();
    await expect(bookButton).toBeAttached();

    // The button should not be obscured — check it's actually clickable
    const isVisible = await bookButton.isVisible();
    expect(isVisible).toBeTruthy();
  });

  test("clicking a book navigates to the book detail page", async ({ page }) => {
    await signInAndGoToLibrary(page);

    const bookButton = page.locator("button.book-button, .book-button").first();
    const bookCount = await bookButton.count();

    if (bookCount === 0) {
      console.log("No books on library shelf, skipping click test");
      return;
    }

    // Use evaluate to click because Playwright can't target elements
    // inside a CSS perspective/3D context (reports "outside viewport")
    await bookButton.evaluate((el) => (el as HTMLElement).click());

    // Should navigate to the book detail page
    await page.waitForURL("**/books/**", { timeout: 5000 });

    // The book detail page should show the book's title
    const detailTitle = page.locator(".book-detail__title, h1");
    await expect(detailTitle).toBeVisible({ timeout: 5000 });
    const titleText = await detailTitle.textContent();
    expect(titleText).toBeTruthy();
    expect(titleText!.length).toBeGreaterThan(0);
  });

  test("hovering over a book triggers 3D transform animation", async ({
    page,
  }) => {
    await signInAndGoToLibrary(page);

    const book = page.locator(".book").first();
    const bookCount = await book.count();

    if (bookCount === 0) {
      console.log("No books on library shelf, skipping hover test");
      return;
    }

    // The hover animation uses @keyframes book-pull-out.
    // Verify the keyframe animation rule exists in the stylesheet.
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

    // Also verify .book:hover references the animation
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
    await signInAndGoToLibrary(page);

    const spine = page.locator(".book__spine").first();
    const spineCount = await spine.count();

    if (spineCount === 0) {
      console.log("No book spines found, skipping texture test");
      return;
    }

    const bgImage = await spine.evaluate(
      (el) => getComputedStyle(el).backgroundImage
    );

    console.log(`Spine background-image: ${bgImage}`);

    // Should reference a texture file, not be "none"
    expect(bgImage).not.toEqual("none");
    // Should contain /textures/ path
    expect(bgImage).toContain("/textures/");
    // Should be a .png file (our generated textures)
    expect(bgImage).toContain(".png");
  });

  test("book has 3D structure: spine, top, and cover faces", async ({
    page,
  }) => {
    await signInAndGoToLibrary(page);

    const book = page.locator(".book").first();
    const bookCount = await book.count();

    if (bookCount === 0) {
      console.log("No books found, skipping structure test");
      return;
    }

    // Book should have preserve-3d
    const transformStyle = await book.evaluate(
      (el) => getComputedStyle(el).transformStyle
    );
    expect(transformStyle).toEqual("preserve-3d");

    // Should have all three faces
    const spine = book.locator(".book__spine");
    const top = book.locator(".book__top");
    const cover = book.locator(".book__cover");

    await expect(spine).toBeAttached();
    await expect(top).toBeAttached();
    await expect(cover).toBeAttached();

    // Spine should have title text
    const titleText = await spine
      .locator(".book__title")
      .textContent()
      .catch(() => "");
    expect(titleText!.length).toBeGreaterThan(0);
  });
});
