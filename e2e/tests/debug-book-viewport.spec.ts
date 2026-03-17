import { test, expect } from "@playwright/test";
import { OWNER_AUTH_FILE } from "./helpers";

test.use({ storageState: OWNER_AUTH_FILE });

test.skip("debug book viewport position", async ({ page }) => {
  await page.goto("/library");
  await page.waitForSelector(".bookcase, .shelf-room, .empty-shelf", { timeout: 10000 });

  const book = page.locator(".book").first();
  const button = page.locator("button.book-button").first();

  // Get bounding boxes
  const bookBox = await book.boundingBox();
  const buttonBox = await button.boundingBox();
  const viewport = page.viewportSize();

  console.log("Viewport:", viewport);
  console.log("Book bounding box:", bookBox);
  console.log("Button bounding box:", buttonBox);

  // Check overflow on ancestor chain
  const overflowChain = await book.evaluate((el) => {
    const chain: Array<{ tag: string; class: string; overflow: string; overflowX: string; overflowY: string; position: string; zIndex: string; rect: DOMRect }> = [];
    let current: Element | null = el;
    while (current && current !== document.documentElement) {
      const s = getComputedStyle(current);
      chain.push({
        tag: current.tagName,
        class: current.className,
        overflow: s.overflow,
        overflowX: s.overflowX,
        overflowY: s.overflowY,
        position: s.position,
        zIndex: s.zIndex,
        rect: current.getBoundingClientRect(),
      });
      current = current.parentElement;
    }
    return chain;
  });

  console.log("\n=== ANCESTOR OVERFLOW CHAIN ===");
  for (const item of overflowChain) {
    const r = item.rect;
    console.log(
      `${item.tag}.${item.class.split(" ")[0] || "(none)"} — overflow: ${item.overflow}, position: ${item.position}, z: ${item.zIndex}, rect: ${Math.round(r.left)},${Math.round(r.top)} ${Math.round(r.width)}x${Math.round(r.height)}`
    );
  }

  // Try force clicking
  console.log("\n=== ATTEMPTING CLICK VIA EVALUATE ===");
  await button.evaluate((el) => (el as HTMLElement).click());

  const overlayVisible = await page.locator(".book-overlay").isVisible();
  console.log("Overlay visible after click:", overlayVisible);

  const overlayHTML = await page.locator(".book-overlay").innerHTML().catch(() => "NOT IN DOM");
  console.log("Overlay innerHTML:", overlayHTML);

  const overlayCount = await page.locator(".book-overlay").count();
  console.log("Overlay count:", overlayCount);

  if (overlayCount > 0) {
    const overlayStyles = await page.locator(".book-overlay").evaluate((el) => {
      const s = getComputedStyle(el);
      return { display: s.display, visibility: s.visibility, opacity: s.opacity, position: s.position, width: s.width, height: s.height, zIndex: s.zIndex };
    });
    console.log("Overlay computed styles:", overlayStyles);

    const backdropCount = await page.locator(".book-overlay__backdrop").count();
    const contentCount = await page.locator(".book-overlay__content").count();
    console.log(`Backdrop count: ${backdropCount}, Content count: ${contentCount}`);
  }

  expect(true).toBeTruthy();
});
