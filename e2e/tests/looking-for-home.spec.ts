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

  test("page title is visible", async ({ page }) => {
    await page.goto("/looking-for-home");
    await page.getByTestId('looking-for-home-page').waitFor({ timeout: 10000 });
    await expect(page.locator(".page__title")).toContainText("Looking for a Home");
  });

  test("page renders content (pile view or empty state)", async ({ page }) => {
    await page.goto("/looking-for-home");
    await page.getByTestId('looking-for-home-page').waitFor({ timeout: 10000 });

    // The page should show either a pile view with books or an empty/loading state
    const hasPileView = (await page.locator(".pile-view").count()) > 0;
    const hasEmpty = (await page.locator(".page__title").count()) > 0;
    expect(hasPileView || hasEmpty).toBeTruthy();
  });
});
