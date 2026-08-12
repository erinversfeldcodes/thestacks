import { test, expect } from "@playwright/test";
import { suiteAuthFile } from "./helpers";

test.use({ storageState: suiteAuthFile("reading-pile") });

test.describe("Reading Pile page", () => {
  test("page loads with dragon wallpaper theme", async ({ page }) => {
    await page.goto("/reading-pile");
    await expect(page.getByTestId('reading-pile-page')).toBeVisible({
      timeout: 10000,
    });
  });

  test("decorative armchair is present with aria-hidden", async ({ page }) => {
    await page.goto("/reading-pile");
    await page.getByTestId('reading-pile-page').waitFor({ timeout: 10000 });

    const armchair = page.locator(".armchair");
    await expect(armchair).toHaveAttribute("aria-hidden", "true");
  });

  test("book pile renders with role=list", async ({ page }) => {
    await page.goto("/reading-pile");
    await page.getByTestId('reading-pile-page').waitFor({ timeout: 10000 });

    const pile = page.locator('.book-pile[role="list"]');
    await expect(pile).toBeVisible({ timeout: 10000 });
    expect(await pile.locator('[role="listitem"]').count()).toBeGreaterThan(0);
  });

  test("clicking a book in the pile opens detail", async ({ page }) => {
    await page.goto("/reading-pile");
    await page.getByTestId('reading-pile-page').waitFor({ timeout: 10000 });

    const bookBtn = page.locator(".book-pile__book").first();
    await expect(bookBtn).toBeVisible({ timeout: 10000 });
    await bookBtn.click();
    await expect(page.getByTestId('book-overlay')).toBeVisible({
      timeout: 10000,
    });
  });

  test("populated reading pile shows the scene, not the hint text", async ({
    page,
  }) => {
    await page.goto("/reading-pile");
    await page.getByTestId('reading-pile-page').waitFor({ timeout: 10000 });

    await expect(page.locator(".reading-pile__scene")).toBeVisible({
      timeout: 10000,
    });
    await expect(page.locator(".book-pile")).toBeVisible({ timeout: 10000 });
    await expect(page.locator(".reading-pile__empty-msg")).toHaveCount(0);
  });
});
