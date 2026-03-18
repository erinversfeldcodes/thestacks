import { test, expect } from "@playwright/test";

const DEV_EMAIL = "owner@thestacks.app";
const DEV_PASSWORD = "dev-password-123";

test.describe("Login Page Aesthetic", () => {
  test("login page renders the bookshelf wall with scene layers", async ({
    page,
  }) => {
    await page.goto("/login");

    // Scene layers exist in DOM (some may have low opacity by design)
    await expect(page.locator(".layer-bookshelf")).toBeAttached();
    await expect(page.locator(".layer-arrival")).toBeAttached();
    await expect(page.locator(".login-overlay")).toBeVisible();
  });

  test("login form has email and password fields", async ({ page }) => {
    await page.goto("/login");

    await expect(page.locator('input[id="email"]')).toBeVisible();
    await expect(page.locator('input[id="password"]')).toBeVisible();
    await expect(
      page.locator('label[for="email"]')
    ).toHaveText("Email");
    await expect(
      page.locator('label[for="password"]')
    ).toHaveText("Password");
  });

  test("wrong credentials show error message with warm styling", async ({
    page,
  }) => {
    await page.goto("/login");

    await page.fill('input[id="email"]', DEV_EMAIL);
    await page.fill('input[id="password"]', "wrong-password");
    await page.click("button.login-card__submit");

    const error = page.locator(".login-card__error");
    await expect(error).toBeVisible();
    await expect(error).toContainText("Invalid");
  });

  test("successful login triggers transition and redirects", async ({
    page,
  }) => {
    await page.goto("/login");

    await page.fill('input[id="email"]', DEV_EMAIL);
    await page.fill('input[id="password"]', DEV_PASSWORD);
    await page.click("button.login-card__submit");

    // Should redirect to antilibrary after transition completes
    await page.waitForURL("**/antilibrary", { timeout: 15000 });
  });

  test("register tab shows display name field", async ({ page }) => {
    await page.goto("/login");

    // Display name field should not be visible in login mode
    await expect(page.locator('input[id="display-name"]')).not.toBeVisible();

    // Click the Register tab
    await page.click('button:has-text("Register")');

    // Display name field should now be visible
    await expect(page.locator('input[id="display-name"]')).toBeVisible();
    await expect(
      page.locator('label[for="display-name"]')
    ).toHaveText("Display Name");

    // Email and password should still be visible
    await expect(page.locator('input[id="email"]')).toBeVisible();
    await expect(page.locator('input[id="password"]')).toBeVisible();
  });

  test("navbar shows only Costs and Sign In when not authenticated", async ({
    page,
  }) => {
    await page.goto("/login");

    // Sign In link should be visible
    await expect(page.locator('a[href="/login"]')).toBeVisible();

    // Catalogue link should be visible in nav
    await expect(page.locator('a[href="/catalogue"]')).toBeVisible();

    // Authenticated-only nav items should not be visible
    await expect(page.locator('a[href="/upload"]')).not.toBeVisible();
    await expect(page.locator('a[href="/library"]')).not.toBeVisible();
    await expect(page.locator('a[href="/search"]')).not.toBeVisible();
  });

  test("login card has parchment styling and ARIA attributes", async ({
    page,
  }) => {
    await page.goto("/login");

    await expect(page.locator(".login-card")).toBeVisible();
    await expect(page.locator(".login-card__title")).toHaveText("The Stacks");
    await expect(page.locator(".login-card__subtitle")).toBeVisible();

    // ARIA attributes on inputs
    await expect(page.locator('input[id="email"]')).toHaveAttribute("aria-required", "true");
    await expect(page.locator('input[id="password"]')).toHaveAttribute("aria-required", "true");

    // Tab interface ARIA
    const tablist = page.locator('[role="tablist"]');
    await expect(tablist).toBeVisible();
    await expect(page.locator('[role="tab"]')).toHaveCount(2);
  });
});
