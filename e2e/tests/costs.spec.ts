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
    await expect(page.getByTestId('costs-content')).toBeVisible({
      timeout: 10_000,
    });

    // Cost data depends on RefreshCostsJob having run.
    // On fresh preview deploys the job may not have fired yet.
    const hasCostData =
      (await page.getByTestId('costs-category-card').count()) > 0;

    if (hasCostData) {
      // Total banner should show a dollar amount
      await expect(page.locator(".costs__banner-amount")).toBeVisible();
      await expect(page.locator(".costs__banner-amount")).toContainText("$");

      // At least one category card should render
      await expect(
        page.getByTestId('costs-category-card').first()
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

// /costs must be REACHABLE by clicking, not just by knowing the URL. These drive
// the real UI as a logged-out visitor: the tests above page.goto("/costs")
// directly, which proves the page renders but never that a user can find it.
test.describe("Cost Transparency — reachable via UI (logged out)", () => {
  test.use({ storageState: { cookies: [], origins: [] } });

  test("About → /costs via the costs link", async ({ page }) => {
    await page.goto("/about");

    const costsLink = page.getByTestId("about-costs-link");
    await expect(costsLink).toBeVisible({ timeout: 10_000 });
    await costsLink.click();

    await expect(page).toHaveURL((url) => url.pathname === "/costs");
    await expect(page.getByTestId("costs-content")).toBeVisible({
      timeout: 10_000,
    });
    await expect(page.locator(".costs__title")).toHaveText("Cost Transparency");
  });

  test("home → About → /costs (full click-path from the landing page)", async ({
    page,
  }) => {
    await page.goto("/");

    // The home page links straight to About (a visible call-to-action button),
    // so a visitor reaches it without the brand-logo hover dropdown.
    const aboutLink = page.locator('.page--home a[href="/about"]');
    await expect(aboutLink).toBeVisible({ timeout: 10_000 });
    await aboutLink.click();
    await expect(page).toHaveURL((url) => url.pathname === "/about");

    const costsLink = page.getByTestId("about-costs-link");
    await expect(costsLink).toBeVisible({ timeout: 10_000 });
    await costsLink.click();
    await expect(page).toHaveURL((url) => url.pathname === "/costs");
    await expect(page.getByTestId("costs-content")).toBeVisible({
      timeout: 10_000,
    });
  });
});
