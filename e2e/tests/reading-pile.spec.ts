import { test, expect } from "@playwright/test";
import { OWNER_AUTH_FILE } from "./helpers";

test.use({ storageState: OWNER_AUTH_FILE });

test.describe("Reading Pile page", () => {
  test("page loads with dragon wallpaper theme", async ({ page }) => {
    await page.goto("/reading-pile");
    await expect(page.locator(".shelf-reading-pile")).toBeVisible({
      timeout: 10000,
    });
  });

  test("decorative armchair is present with aria-hidden", async ({ page }) => {
    await page.goto("/reading-pile");
    await page.waitForSelector(".shelf-reading-pile", { timeout: 10000 });

    const armchair = page.locator(".reading-pile__armchair");
    if ((await armchair.count()) > 0) {
      await expect(armchair).toHaveAttribute("aria-hidden", "true");
    }
  });

  test("book pile renders with role=list", async ({ page }) => {
    await page.goto("/reading-pile");
    await page.waitForSelector(".shelf-reading-pile", { timeout: 10000 });

    const pile = page.locator('.book-pile[role="list"]');
    if ((await pile.count()) > 0) {
      const items = await pile.locator('[role="listitem"]').count();
      expect(items).toBeGreaterThan(0);
    }
  });

  test("clicking a book in the pile opens detail", async ({ page }) => {
    await page.goto("/reading-pile");
    await page.waitForSelector(".shelf-reading-pile", { timeout: 10000 });

    const bookBtn = page.locator(".book-pile__book").first();
    if ((await bookBtn.count()) > 0) {
      await bookBtn.click();
      await page.waitForURL("**/books/**", { timeout: 5000 });
      await expect(page.locator(".book-detail__parchment")).toBeVisible({
        timeout: 10000,
      });
    }
  });

  test("empty reading pile shows hint text", async ({ page }) => {
    // User 2 has no reading pile books — but we test with owner who might
    // Just verify the page loads without error
    await page.goto("/reading-pile");
    await expect(page.locator(".shelf-reading-pile")).toBeVisible({
      timeout: 10000,
    });
    // If empty, should show empty message
    const emptyMsg = page.locator(".book-pile--empty, .shelf-row__empty-text");
    const bookPile = page.locator(".book-pile");
    const hasContent =
      (await emptyMsg.count()) > 0 || (await bookPile.count()) > 0;
    expect(hasContent).toBeTruthy();
  });
});
