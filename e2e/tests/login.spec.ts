import { test, expect } from "@playwright/test";

const DEV_EMAIL = "owner@thestacks.app";
const DEV_PASSWORD = "dev-password-123";

test.describe("Login Page Aesthetic", () => {
  test("login page renders the door metaphor with entrance and door elements", async ({
    page,
  }) => {
    await page.goto("/login");

    await expect(page.locator(".login-entrance")).toBeVisible();
    await expect(page.locator(".login-door")).toBeVisible();
    await expect(page.locator(".login-door__frame")).toBeVisible();
    await expect(page.locator(".login-door__arch")).toBeVisible();
    await expect(page.locator(".login-door__panel--left")).toBeVisible();
    await expect(page.locator(".login-door__panel--right")).toBeVisible();
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
    await page.click("button.login-form__submit");

    const error = page.locator(".login-form__error");
    await expect(error).toBeVisible();
    await expect(error).toContainText("Invalid");

    // Error should be rendered within the login form area
    await expect(page.locator(".login-form .login-form__error")).toBeVisible();
  });

  test("successful login triggers door animation classes", async ({
    page,
  }) => {
    await page.goto("/login");

    await page.fill('input[id="email"]', DEV_EMAIL);
    await page.fill('input[id="password"]', DEV_PASSWORD);
    await page.click("button.login-form__submit");

    // After successful auth, the door opening animation class should appear
    await expect(page.locator(".login-door--opening")).toBeVisible({
      timeout: 5000,
    });

    // Eventually the door fully opens
    await expect(page.locator(".login-door--open")).toBeVisible({
      timeout: 5000,
    });

    // Should redirect to home after door animation completes
    await page.waitForURL("/", { timeout: 10000 });
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

    // Costs link should be visible
    await expect(page.locator('a[href="/costs"]')).toBeVisible();

    // Authenticated-only nav items should not be visible
    await expect(page.locator('a[href="/upload"]')).not.toBeVisible();
    await expect(page.locator('a[href="/library"]')).not.toBeVisible();
    await expect(page.locator('a[href="/search"]')).not.toBeVisible();
  });
});
