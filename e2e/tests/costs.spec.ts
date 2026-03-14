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

    // Total banner should show a dollar amount
    await expect(page.locator(".costs__banner-amount")).toBeVisible();
    await expect(page.locator(".costs__banner-amount")).toContainText("$");

    // At least one category card should render
    await expect(page.locator(".costs__category-card").first()).toBeVisible();

    // Story cards should be present
    await expect(page.locator(".costs__story-card")).toHaveCount(3);
    await expect(
      page.locator(".costs__story-card").first()
    ).toContainText("$");

    // Philosophy note at the bottom
    await expect(page.locator(".costs__philosophy-text")).toContainText(
      "Every number"
    );
  });

  test("API endpoint returns cost data without auth", async ({ request }) => {
    const response = await request.get("/api/costs");
    expect(response.status()).toBe(200);

    const body = await response.json();
    expect(body.data).toBeDefined();
    expect(body.data.total_cents).toBeGreaterThanOrEqual(0);
    expect(body.data.currency).toBe("USD");
    expect(body.data.categories).toBeDefined();
    expect(body.data.metrics).toBeDefined();
    expect(body.data.metrics.books).toBeGreaterThanOrEqual(0);

    // No user data exposed
    expect(body.data.metrics.users).toBeUndefined();
  });
});
