import { test, expect } from "@playwright/test";
import { suiteAuthFile, ensureBookOnShelf } from "./helpers";

test.use({ storageState: suiteAuthFile("reading-pile-hover") });

test.describe("Reading Pile hover diagnostics", () => {
  test.beforeEach(async ({ page }) => {
    await ensureBookOnShelf(page, "reading_pile");
  });

  test("screenshot hover sequence using mouse move", async ({ page }) => {
    await page.goto("/reading-pile");
    await page.waitForSelector(".shelf-reading-pile", { timeout: 10000 });

    const books = page.locator(".book-pile__book");
    await expect(books.first()).toBeAttached({ timeout: 10000 });

    const count = await books.count();
    console.log(`Found ${count} books`);

    const targetBook = books.nth(Math.min(4, count - 1));
    const box = await targetBook.boundingBox();
    console.log("Target book box:", JSON.stringify(box));

    // Screenshot before
    await page.screenshot({ path: "test-results/pile-00-before.png", fullPage: true });

    expect(box).toBeTruthy();

    const centerX = box!.x + box!.width / 2;
    const centerY = box!.y + box!.height / 2;
    console.log(`Moving mouse to (${centerX}, ${centerY})`);

    await page.mouse.move(centerX, centerY);
    await page.waitForTimeout(200);
    await page.screenshot({ path: "test-results/pile-01-mouse-move.png", fullPage: true });

    // Check what element is under the cursor
    const elementAtPoint = await page.evaluate(({x, y}) => {
      const el = document.elementFromPoint(x, y);
      return el ? { tag: el.tagName, classes: el.className, text: el.textContent?.substring(0, 50) } : null;
    }, { x: centerX, y: centerY });
    console.log("Element under cursor:", JSON.stringify(elementAtPoint));

    // Force hover by adding a class manually to test the styles work
    await targetBook.evaluate((el) => el.classList.add("force-hover"));
    await page.addStyleTag({ content: `
      .book-pile__book.force-hover {
        z-index: 200 !important;
        position: fixed !important;
        top: 50vh !important;
        right: 10vw !important;
        left: auto !important;
        bottom: auto !important;
        transform: translateY(-50%) rotate(90deg) !important;
      }
      .book-pile__book.force-hover .book-pile__rotated-book .book {
        animation: pile-book-tilt 0.6s cubic-bezier(0.25, 0.1, 0.25, 1) forwards;
      }
    `});
    await page.waitForTimeout(800);
    await page.screenshot({ path: "test-results/pile-02-force-hover.png", fullPage: true });

    const forcedStyles = await targetBook.evaluate((el) => {
      const cs = getComputedStyle(el);
      return { position: cs.position, top: cs.top, right: cs.right, zIndex: cs.zIndex, transform: cs.transform };
    });
    console.log("Forced hover styles:", JSON.stringify(forcedStyles, null, 2));

    // Check computed styles on the hovered book
    const hoveredStyles = await targetBook.evaluate((el) => {
      const cs = getComputedStyle(el);
      return {
        position: cs.position,
        top: cs.top,
        right: cs.right,
        left: cs.left,
        transform: cs.transform,
        zIndex: cs.zIndex,
        animation: cs.animationName,
        display: cs.display,
        width: cs.width,
        height: cs.height,
      };
    });
    console.log("Hovered book styles:", JSON.stringify(hoveredStyles, null, 2));

    // Check if the inner .book got the tilt animation
    const innerBook = targetBook.locator(".book").first();
    const innerStyles = await innerBook.evaluate((el) => {
      const cs = getComputedStyle(el);
      return {
        transform: cs.transform,
        animation: cs.animationName,
        transformStyle: cs.transformStyle,
      };
    });
    console.log("Inner .book styles:", JSON.stringify(innerStyles, null, 2));

    // Move mouse away
    await page.mouse.move(0, 0);
    await page.waitForTimeout(500);
    await page.screenshot({ path: "test-results/pile-05-unhovered.png", fullPage: true });

    console.log("Screenshots saved to test-results/pile-*.png");
  });
});
