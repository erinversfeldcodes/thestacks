import { test, expect } from "@playwright/test";
import { suiteAuthFile } from "./helpers";

test.use({ storageState: suiteAuthFile("looking-for-home") });

test.describe("Looking for a Home page", () => {
  test("page loads with correct theme class", async ({ page }) => {
    await page.goto("/looking-for-home");
    await expect(
      page.getByTestId('looking-for-home-page')
    ).toBeVisible({ timeout: 10000 });
  });

  test("the room's brass label carries the shelf name", async ({ page }) => {
    await page.goto("/looking-for-home");
    await page.getByTestId('looking-for-home-page').waitFor({ timeout: 10000 });

    await expect(page.locator(".shelf-room")).toBeVisible();
    const label = page.locator(".shelf-room .shelf-label");
    await expect(label).toContainText("Looking for a Home");
    await expect(page.locator("h1.page__title")).toHaveCount(0);
  });

  test("empty state matches US-1.6.5 wording", async ({ page }) => {
    await page.goto("/looking-for-home");
    await page.getByTestId('looking-for-home-page').waitFor({ timeout: 10000 });

    await expect(page.locator(".empty-shelf__message")).toContainText(
      "Nothing here yet — these are books looking for a new home.",
      { timeout: 10000 }
    );
    await expect(page.locator(".pile-view")).toHaveCount(0);
  });
});
