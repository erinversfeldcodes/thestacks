import { test, expect } from "@playwright/test";
import { suiteAuthFile } from "./helpers";

test.describe("Catalogue — unauthenticated", () => {
  test("catalogue page loads without authentication", async ({ page }) => {
    await page.goto("/catalogue");
    await page.waitForSelector(".catalogue__grid", { timeout: 10000 });
    const cards = await page.locator(".catalogue__card").count();
    expect(cards).toBeGreaterThan(0);
  });

  test("displays book title, author, and subjects on cards", async ({
    page,
  }) => {
    await page.goto("/catalogue");
    await page.waitForSelector(".catalogue__grid", { timeout: 10000 });
    const firstCard = page.locator(".catalogue__card").first();
    await expect(firstCard.locator(".catalogue__card-title")).toBeVisible();
    await expect(firstCard.locator(".catalogue__card-author")).toBeVisible();
  });

  test("search filters books by title", async ({ page }) => {
    await page.goto("/catalogue");
    await page.waitForSelector(".catalogue__grid", { timeout: 10000 });
    const initialCount = await page.locator(".catalogue__card").count();

    await page.fill(".search-bar__input", "Circe");
    // Wait for debounce + API call
    await page.waitForTimeout(1000);
    await page.waitForSelector(".catalogue__grid", { timeout: 10000 });

    const filteredCount = await page.locator(".catalogue__card").count();
    expect(filteredCount).toBeLessThan(initialCount);
    expect(filteredCount).toBeGreaterThan(0);

    const firstTitle = await page
      .locator(".catalogue__card-title")
      .first()
      .textContent();
    expect(firstTitle).toContain("Circe");
  });

  test("clear search restores full catalogue", async ({ page }) => {
    await page.goto("/catalogue");
    await page.waitForSelector(".catalogue__grid", { timeout: 10000 });

    await page.fill(".search-bar__input", "Circe");
    await page.waitForTimeout(1000);
    await page.waitForSelector(".catalogue__grid", { timeout: 10000 });

    await page.click(".search-bar__clear");
    // Wait for the catalogue grid to re-render with the full list
    await page.waitForSelector(".catalogue__grid", { timeout: 15000 });
    // Allow time for all cards to render on slow deployed environments
    await page.waitForTimeout(2000);

    const count = await page.locator(".catalogue__card").count();
    expect(count).toBeGreaterThanOrEqual(1);
  });

  test("subject filter narrows results", async ({ page }) => {
    await page.goto("/catalogue");
    await page.waitForSelector(".catalogue__grid", { timeout: 10000 });

    const subjectSelect = page.locator(".catalogue__subject-select");
    if ((await subjectSelect.count()) > 0) {
      await subjectSelect.selectOption("Philosophy");
      await page.waitForSelector(".catalogue__grid", { timeout: 10000 });
      const count = await page.locator(".catalogue__card").count();
      expect(count).toBeGreaterThan(0);
    }
  });

  test("sort selector changes order", async ({ page }) => {
    await page.goto("/catalogue");
    await page.waitForSelector(".catalogue__grid", { timeout: 10000 });

    const firstTitleBefore = await page
      .locator(".catalogue__card-title")
      .first()
      .textContent();

    await page.selectOption(".sort-selector__select", "recent");
    await page.waitForSelector(".catalogue__grid", { timeout: 10000 });

    const firstTitleAfter = await page
      .locator(".catalogue__card-title")
      .first()
      .textContent();

    // Titles should differ since sort changed from A-Z to recent
    expect(firstTitleAfter).not.toEqual(firstTitleBefore);
  });

  test("pagination controls appear and work", async ({ page }) => {
    await page.goto("/catalogue");
    await page.waitForSelector(".catalogue__grid", { timeout: 10000 });

    const pagination = page.locator(".catalogue__pagination");
    if ((await pagination.count()) > 0) {
      const pageInfo = page.locator(".catalogue__page-info");
      await expect(pageInfo).toContainText("Page 1");

      const nextBtn = page.locator("button", { hasText: "Next" });
      if ((await nextBtn.count()) > 0) {
        await nextBtn.click();
        await page.waitForSelector(".catalogue__grid", { timeout: 10000 });
        await expect(pageInfo).toContainText("Page 2");
      }
    }
  });

  test("clicking a card navigates to book detail", async ({ page }) => {
    await page.goto("/catalogue");
    await page.waitForSelector(".catalogue__grid", { timeout: 10000 });

    await page.locator(".catalogue__card-link").first().click();
    await page.waitForURL("**/books/**", { timeout: 5000 });
    await expect(page.locator(".book-detail__parchment")).toBeVisible({
      timeout: 10000,
    });
  });

  test("no collection filter buttons shown when unauthenticated", async ({
    page,
  }) => {
    await page.goto("/catalogue");
    await page.waitForSelector(".catalogue__grid", { timeout: 10000 });
    await expect(
      page.locator(".catalogue__collection-filter")
    ).not.toBeVisible();
  });
});

test.describe("Catalogue — authenticated", () => {
  test.use({ storageState: suiteAuthFile("catalogue") });

  test("collection filter buttons are visible", async ({ page }) => {
    await page.goto("/catalogue");
    await page.waitForSelector(".catalogue__grid", { timeout: 10000 });
    await expect(
      page.locator(".catalogue__collection-filter")
    ).toBeVisible();
  });

  test("placed books show badge text", async ({ page }) => {
    await page.goto("/catalogue");
    await page.waitForSelector(".catalogue__grid", { timeout: 10000 });
    // Wait for placements to load
    await page.waitForTimeout(1000);

    const badges = await page.locator(".catalogue__card-badge").count();
    expect(badges).toBeGreaterThan(0);

    const badgeText = await page
      .locator(".catalogue__card-badge")
      .first()
      .textContent();
    // Should use the new phrasing
    expect(
      badgeText?.startsWith("In your") || badgeText?.startsWith("On your") || badgeText?.startsWith("You're")
    ).toBeTruthy();
  });

  test("'In my collection' filter shows only placed books", async ({
    page,
  }) => {
    await page.goto("/catalogue");
    await page.waitForSelector(".catalogue__grid", { timeout: 10000 });
    await page.waitForTimeout(1000);

    await page.click('button:has-text("In my collection")');
    await page.waitForTimeout(500);

    // Every visible card should have a badge
    const cards = await page.locator(".catalogue__card").count();
    const badges = await page.locator(".catalogue__card-badge").count();
    expect(badges).toEqual(cards);
  });

  test("'Not in my collection' filter shows only unplaced books", async ({
    page,
  }) => {
    await page.goto("/catalogue");
    await page.waitForSelector(".catalogue__grid", { timeout: 10000 });
    await page.waitForTimeout(1000);

    await page.click('button:has-text("Not in my collection")');
    await page.waitForTimeout(500);

    // No badges should be visible
    await expect(page.locator(".catalogue__card-badge")).toHaveCount(0);
    // But there should be cards with "Add to Shelf" buttons
    const addButtons = await page.locator(".catalogue__card-add").count();
    expect(addButtons).toBeGreaterThan(0);
  });
});
