import { test, expect } from "@playwright/test";

test.describe("Cost Transparency", () => {
  test("page loads without authentication and shows cost breakdown", async ({
    page,
  }) => {
    await page.goto("/costs");

    await expect(page.locator(".costs__title")).toHaveText(
      "Cost Transparency"
    );
    await expect(page.locator(".costs__subtitle")).toContainText(
      "honest look"
    );

    await expect(page.getByTestId('costs-content')).toBeVisible({
      timeout: 10_000,
    });

    await expect(page.locator(".costs__banner-amount")).toBeVisible();
    await expect(page.locator(".costs__banner-amount")).toContainText("$");

    await expect(
      page.getByTestId('costs-category-card').first()
    ).toBeVisible();

    await expect(page.locator(".costs__story-card")).toHaveCount(3);
    await expect(
      page.locator(".costs__story-card").first()
    ).toContainText("$");

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
