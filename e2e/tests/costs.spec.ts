import { test, expect } from "@playwright/test";

test.describe("Cost Transparency", () => {
  test("page loads without authentication and shows cost breakdown", async ({
    page,
  }) => {
    // /costs is a public page — no login required
    await page.goto("/costs");

    // Page title and subtitle should be visible
    await expect(page.locator(".costs__title")).toHaveText(
      "Cost Transparency"
    );
    await expect(page.locator(".costs__subtitle")).toContainText(
      "honest look"
    );

    // Wait for cost data to load (replaces loading indicator)
    await expect(page.locator(".costs__content")).toBeVisible({
      timeout: 10_000,
    });

    // Cost data depends on RefreshCostsJob having run.
    // On fresh preview deploys the job may not have fired yet.
    const hasCostData =
      (await page.locator(".costs__category-card").count()) > 0;

    if (hasCostData) {
      // Total banner should show a dollar amount
      await expect(page.locator(".costs__banner-amount")).toBeVisible();
      await expect(page.locator(".costs__banner-amount")).toContainText("$");

      // At least one category card should render
      await expect(
        page.locator(".costs__category-card").first()
      ).toBeVisible();

      // Story cards should be present
      await expect(page.locator(".costs__story-card")).toHaveCount(3);
      await expect(
        page.locator(".costs__story-card").first()
      ).toContainText("$");
    }

    // Philosophy note at the bottom
    await expect(page.locator(".costs__philosophy-text")).toContainText(
      "Every number"
    );
  });

  test("API endpoint returns cost data without auth", async ({ request }) => {
    const resp = await request.get("/api/costs");
    expect(resp.status()).toBe(200);
    const body = await resp.json();
    expect(body).toHaveProperty("data");
    expect(body.data).toHaveProperty("categories");
    expect(Array.isArray(body.data.categories)).toBe(true);
  });
});
