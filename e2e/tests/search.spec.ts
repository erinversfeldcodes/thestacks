import { test, expect } from "@playwright/test";
import { suiteAuthFile } from "./helpers";

test.use({ storageState: suiteAuthFile("search") });

test.describe("Search page", () => {
  test("search page renders with input field and title", async ({ page }) => {
    await page.goto("/search");
    await expect(page.getByTestId('search-page')).toBeVisible({ timeout: 5000 });
    await expect(page.locator(".page__title")).toContainText("Search");
    await expect(page.getByTestId('search-input')).toBeVisible();
  });

  test("shows hint text before searching", async ({ page }) => {
    await page.goto("/search");
    await expect(page.locator(".search-hint")).toBeVisible({ timeout: 5000 });
  });

  test("sort selector is present with options", async ({ page }) => {
    await page.goto("/search");
    await page.getByTestId('search-page').waitFor({ timeout: 5000 });

    const sortSelect = page.getByTestId('sort-selector');
    await expect(sortSelect).toBeVisible();

    const options = await sortSelect.locator("option").count();
    expect(options).toBeGreaterThanOrEqual(2);
  });

  test("filter panel toggle is present", async ({ page }) => {
    await page.goto("/search");
    await page.getByTestId('search-page').waitFor({ timeout: 5000 });

    const filterToggle = page.getByTestId('filter-toggle');
    await expect(filterToggle).toBeVisible();
  });

  test("typing a query shows loading or results", async ({ page }) => {
    await page.goto("/search");
    await page.getByTestId('search-page').waitFor({ timeout: 5000 });

    await page.getByTestId('search-input').fill("Circe");
    // Wait for debounce and API call attempt
    await page.waitForTimeout(2000);

    // After typing, the hint should disappear (replaced by loading, results, empty, or error)
    const hintVisible = await page.locator(".search-hint").isVisible();
    // If the API call succeeds, hint is gone; if it fails, error shows
    // Either way the page responded to the input
    const hasAnyResponse =
      !hintVisible ||
      (await page.getByTestId('search-results').count()) > 0 ||
      (await page.locator(".search-empty").count()) > 0 ||
      (await page.locator(".loading").count()) > 0 ||
      (await page.locator(".error").count()) > 0;

    expect(hasAnyResponse).toBeTruthy();
  });

  test("clear button appears after typing", async ({ page }) => {
    await page.goto("/search");
    await page.getByTestId('search-page').waitFor({ timeout: 5000 });

    // No clear button initially
    await expect(page.getByTestId('search-clear')).not.toBeVisible();

    await page.getByTestId('search-input').fill("test");
    await page.waitForTimeout(500);

    await expect(page.getByTestId('search-clear')).toBeVisible();
  });
});
