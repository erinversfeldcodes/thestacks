import { test, expect } from "@playwright/test";

const DEV_EMAIL = "owner@thestacks.app";
const DEV_PASSWORD = "dev-password-123";

async function signIn(page: import("@playwright/test").Page) {
  await page.goto("/login");
  await page.fill('input[id="email"]', DEV_EMAIL);
  await page.fill('input[id="password"]', DEV_PASSWORD);
  await page.click("button.login-card__submit");
  await page.waitForURL("**/antilibrary", { timeout: 15000 });
}

test.describe("Debug — bookshelf DOM inspection", () => {
  test("dump library page book DOM structure", async ({ page }) => {
    await signIn(page);
    await page.locator('a.app-nav__link[href="/library"]').click();
    await page.waitForURL("**/library", { timeout: 10000 });
    await page.waitForTimeout(2000);

    // Dump the bookshelf HTML
    const bookcase = await page.locator(".bookshelf, .bookcase").first().innerHTML().catch(() => "NOT FOUND");
    console.log("=== BOOKCASE HTML ===");
    console.log(bookcase.substring(0, 3000));

    // Check for books
    const bookCount = await page.locator(".book").count();
    console.log(`\n=== BOOK COUNT: ${bookCount} ===`);

    if (bookCount > 0) {
      // Dump first book's HTML
      const firstBook = await page.locator(".book").first().innerHTML();
      console.log("\n=== FIRST BOOK HTML ===");
      console.log(firstBook);

      // Check for 3D structure
      const hasSpine = await page.locator(".book__spine").count();
      const hasTop = await page.locator(".book__top").count();
      const hasCover = await page.locator(".book__cover").count();
      console.log(`\nSpine elements: ${hasSpine}, Top elements: ${hasTop}, Cover elements: ${hasCover}`);

      // Check transform-style
      const transformStyle = await page.locator(".book").first().evaluate(el => getComputedStyle(el).transformStyle);
      console.log(`transform-style: ${transformStyle}`);

      // Check background-image on spine
      const bgImage = await page.locator(".book__spine").first().evaluate(el => getComputedStyle(el).backgroundImage);
      console.log(`spine background-image: ${bgImage}`);

      // Check if book is clickable (has onclick or is a button)
      const tagName = await page.locator(".book").first().evaluate(el => el.tagName);
      const hasOnClick = await page.locator(".book").first().evaluate(el => el.getAttribute('onclick') || 'none');
      const parentTag = await page.locator(".book").first().evaluate(el => el.parentElement?.tagName || 'unknown');
      const isButton = await page.locator("button.book-button, .book button").count();
      console.log(`\nBook tag: ${tagName}, onclick: ${hasOnClick}, parent: ${parentTag}, button wrappers: ${isButton}`);
    }

    // Check shelf structure
    const shelfRow = await page.locator(".shelf-row").count();
    const shelfBack = await page.locator(".shelf-row__back").count();
    const shelfPlank = await page.locator(".shelf-row__plank").count();
    const shelfLip = await page.locator(".shelf-row__lip").count();
    const bookcaseSide = await page.locator(".bookcase__side--left, .bookcase__side").count();
    console.log(`\n=== SHELF STRUCTURE ===`);
    console.log(`shelf-row: ${shelfRow}, back: ${shelfBack}, plank: ${shelfPlank}, lip: ${shelfLip}, side panels: ${bookcaseSide}`);

    // Check bookcase computed styles for the gap
    const bookcaseEl = await page.locator(".bookcase, .bookshelf").first();
    if (await bookcaseEl.count() > 0) {
      const bookcaseCSS = await bookcaseEl.evaluate(el => {
        const s = getComputedStyle(el);
        return { display: s.display, position: s.position, padding: s.padding, margin: s.margin, gap: s.gap };
      });
      console.log(`\nBookcase CSS:`, bookcaseCSS);
    }

    // Always pass — this is a diagnostic test
    expect(true).toBeTruthy();
  });

  test("dump catalogue book click behavior", async ({ page }) => {
    await signIn(page);
    await page.locator('a.app-nav__link[href="/catalogue"]').click();
    await page.waitForURL("**/catalogue", { timeout: 10000 });
    await page.waitForTimeout(2000);

    const catalogueBooks = await page.locator(".catalogue-card, .book-card, .catalogue__book").count();
    console.log(`\n=== CATALOGUE BOOK COUNT: ${catalogueBooks} ===`);

    // Check what selectors exist for catalogue items
    const allClasses = await page.evaluate(() => {
      const els = document.querySelectorAll('[class*="catalogue"], [class*="book-card"]');
      return Array.from(els).map(el => el.className).slice(0, 10);
    });
    console.log("Catalogue classes found:", allClasses);

    // Look for the shelf mover / move-to-shelf dropdown
    const shelfMover = await page.locator("select, .shelf-mover, [class*='shelf-mover']").count();
    console.log(`Shelf mover elements: ${shelfMover}`);

    expect(true).toBeTruthy();
  });

  test("dump reading pile structure", async ({ page }) => {
    await signIn(page);
    await page.locator('a.app-nav__link[href="/reading-pile"]').click();
    await page.waitForURL("**/reading-pile", { timeout: 10000 });
    await page.waitForTimeout(2000);

    const pageHTML = await page.locator(".page--shelf, .shelf-reading-pile").first().innerHTML().catch(() => "NOT FOUND");
    console.log("=== READING PILE HTML (first 2000 chars) ===");
    console.log(pageHTML.substring(0, 2000));

    expect(true).toBeTruthy();
  });
});
