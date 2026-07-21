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

  test("empty state matches US-1.6.5 wording", async ({ page }) => {
    // No suite user is seeded with looking_for_home placements, so this shelf
    // is empty for every suite user — asserted unconditionally.
    await page.goto("/looking-for-home");
    await page.getByTestId('looking-for-home-page').waitFor({ timeout: 10000 });

    // Looking-for-Home is the only page using Components.EmptyBookshelf.
    // Note the en dash in the copy (LookingForHome.elm:102).
    await expect(page.locator(".empty-shelf__message")).toContainText(
      "Nothing here yet — these are books looking for a new home.",
      { timeout: 10000 }
    );
    await expect(page.locator(".pile-view")).toHaveCount(0);
  });
});
