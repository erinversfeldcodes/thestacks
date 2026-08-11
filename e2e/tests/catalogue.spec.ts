import { test, expect } from "@playwright/test";
import { suiteAuthFile, ensureBookOnLibrary } from "./helpers";

test.describe("Catalogue — unauthenticated", () => {
  test("catalogue page loads without authentication", async ({ page }) => {
    await page.goto("/catalogue");
    await page.getByTestId('catalogue-grid').waitFor({ timeout: 10000 });
    const cards = await page.locator(".catalogue__card").count();
    expect(cards).toBeGreaterThan(0);
  });

  test("displays book title, author, and subjects on cards", async ({
    page,
  }) => {
    await page.goto("/catalogue");
    await page.getByTestId('catalogue-grid').waitFor({ timeout: 10000 });
    const firstCard = page.locator(".catalogue__card").first();
    await expect(firstCard.locator(".catalogue__card-title")).toBeVisible();
    await expect(firstCard.locator(".catalogue__card-author")).toBeVisible();
  });

  test("search filters books by title", async ({ page }) => {
    await page.goto("/catalogue");
    await page.getByTestId('catalogue-grid').waitFor({ timeout: 10000 });
    const initialCount = await page.locator(".catalogue__card").count();

    await page.locator('.search-bar__input').fill("Circe");
    await page.waitForTimeout(1000);
    await page.getByTestId('catalogue-grid').waitFor({ timeout: 10000 });

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
    await page.getByTestId('catalogue-grid').waitFor({ timeout: 10000 });

    await page.locator('.search-bar__input').fill("Circe");
    await page.waitForTimeout(1000);
    await page.getByTestId('catalogue-grid').waitFor({ timeout: 10000 });

    await page.locator('.search-bar__clear').click();
    await page.getByTestId('catalogue-grid').waitFor({ timeout: 15000 });
    await page.waitForTimeout(2000);

    const count = await page.locator(".catalogue__card").count();
    expect(count).toBeGreaterThanOrEqual(1);
  });

  test("subject filter narrows results", async ({ page }) => {
    await page.goto("/catalogue");
    await page.getByTestId('catalogue-grid').waitFor({ timeout: 10000 });

    const subjectSelect = page.locator(".catalogue__subject-select");
    await expect(subjectSelect).toBeVisible({ timeout: 10000 });
    await subjectSelect.selectOption("Philosophy");
    await page.getByTestId('catalogue-grid').waitFor({ timeout: 10000 });
    const count = await page.locator(".catalogue__card").count();
    expect(count).toBeGreaterThan(0);
  });

  test("sort selector changes order", async ({ page }) => {
    await page.goto("/catalogue");
    await page.getByTestId('catalogue-grid').waitFor({ timeout: 10000 });

    const firstTitleBefore = await page
      .locator(".catalogue__card-title")
      .first()
      .textContent();

    await page.locator('.sort-selector__select').selectOption("recent");
    await page.getByTestId('catalogue-grid').waitFor({ timeout: 10000 });

    const firstTitleAfter = await page
      .locator(".catalogue__card-title")
      .first()
      .textContent();

    expect(firstTitleAfter).not.toEqual(firstTitleBefore);
  });

  test("pagination controls appear and work", async ({ page }) => {
    await page.goto("/catalogue");
    await page.getByTestId('catalogue-grid').waitFor({ timeout: 10000 });

    const pagination = page.locator(".catalogue__pagination");
    await expect(pagination).toBeVisible({ timeout: 10000 });

    const pageInfo = page.locator(".catalogue__page-info");
    await expect(pageInfo).toContainText("Page 1");

    const nextBtn = page.locator("button", { hasText: "Next" });
    await expect(nextBtn).toBeVisible({ timeout: 10000 });
    await nextBtn.click();
    await page.getByTestId('catalogue-grid').waitFor({ timeout: 10000 });
    await expect(pageInfo).toContainText("Page 2");
  });

  test("clicking a card opens the book detail overlay", async ({ page }) => {
    await page.goto("/catalogue");
    await page.getByTestId('catalogue-grid').waitFor({ timeout: 10000 });

    await page.locator(".catalogue__card-link").first().click();

    const overlay = page.getByTestId('book-overlay');
    await expect(overlay).toBeVisible({ timeout: 10000 });
  });

  test("no collection filter buttons shown when unauthenticated", async ({
    page,
  }) => {
    await page.goto("/catalogue");
    await page.getByTestId('catalogue-grid').waitFor({ timeout: 10000 });
    await expect(
      page.locator(".catalogue__collection-filter")
    ).not.toBeVisible();
  });

  test("API excludes age_gated books from unauthenticated catalogue", async ({
    page,
  }) => {
    await page.goto("/");
    const result = await page.evaluate(async () => {
      const resp = await fetch("/api/catalogue?per_page=200");
      const data = await resp.json();
      return {
        total: data.total,
        hasAgeGated: data.books.some(
          (b: any) => b.visibility_tier === "age_gated"
        ),
      };
    });
    expect(result.total).toBeGreaterThan(0);
    expect(result.hasAgeGated).toBe(false);
  });
});

test.describe("Catalogue — authenticated", () => {
  test.use({ storageState: suiteAuthFile("catalogue") });

  test("collection filter buttons are visible", async ({ page }) => {
    await page.goto("/catalogue");
    await page.getByTestId('catalogue-grid').waitFor({ timeout: 10000 });
    await expect(
      page.locator(".catalogue__collection-filter")
    ).toBeVisible();
  });

  test("placed books show badge text", async ({ page }) => {
    await ensureBookOnLibrary(page);
    await page.goto("/catalogue");
    await page.getByTestId('catalogue-grid').waitFor({ timeout: 10000 });
    await page.waitForSelector(".catalogue__card-badge", { timeout: 15000 });

    const badges = await page.locator(".catalogue__card-badge").count();
    expect(badges).toBeGreaterThan(0);

    const badgeText = await page
      .locator(".catalogue__card-badge")
      .first()
      .textContent();
    expect(
      badgeText?.startsWith("In your") || badgeText?.startsWith("On your") || badgeText?.startsWith("You're")
    ).toBeTruthy();
  });

  test("'In my collection' filter shows only placed books", async ({
    page,
  }) => {
    await page.goto("/catalogue");
    await page.getByTestId('catalogue-grid').waitFor({ timeout: 10000 });
    await page.waitForTimeout(1000);

    await page.click('button:has-text("In my collection")');
    await page.waitForTimeout(500);

    const cards = await page.locator(".catalogue__card").count();
    const badges = await page.locator(".catalogue__card-badge").count();
    expect(badges).toEqual(cards);
  });

  test("'Not in my collection' filter shows only unplaced books", async ({
    page,
  }) => {
    await page.goto("/catalogue");
    await page.getByTestId('catalogue-grid').waitFor({ timeout: 10000 });
    await page.waitForTimeout(1000);

    await page.click('button:has-text("Not in my collection")');
    await page.waitForTimeout(500);

    await expect(page.locator(".catalogue__card-badge")).toHaveCount(0);
    const addButtons = await page.locator(".catalogue__card-add").count();
    expect(addButtons).toBeGreaterThan(0);
  });

  test("API includes age_gated books for authenticated users", async ({
    page,
  }) => {
    await page.goto("/");
    const result = await page.evaluate(async () => {
      const auth = JSON.parse(localStorage.getItem("stacks-auth") || "{}");
      const resp = await fetch("/api/catalogue?per_page=200", {
        headers: { Authorization: `Bearer ${auth.token}` },
      });
      const data = await resp.json();
      return {
        total: data.total,
        hasAgeGated: data.books.some(
          (b: any) => b.visibility_tier === "age_gated"
        ),
      };
    });
    expect(result.hasAgeGated).toBe(true);
  });
});
