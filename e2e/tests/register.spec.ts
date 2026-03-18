import { test, expect } from "@playwright/test";

test.describe("Registration flow", () => {
  test("register tab shows display name, email, and password fields", async ({
    page,
  }) => {
    await page.goto("/login");
    await page.waitForTimeout(2000);

    // Switch to register mode
    const registerTab = page.locator('button:has-text("Register")').first();
    await registerTab.click();
    await page.waitForTimeout(500);

    await expect(page.locator('input[placeholder="Your name"]')).toBeVisible();
    await expect(
      page.locator('input[placeholder="you@example.com"]')
    ).toBeVisible();
    await expect(
      page.locator('input[placeholder="Enter your password"]')
    ).toBeVisible();
  });

  test("register form has a submit button", async ({ page }) => {
    await page.goto("/login");
    await page.waitForTimeout(2000);

    await page.locator('button:has-text("Register")').first().click();
    await page.waitForTimeout(500);

    await expect(
      page.locator('button:has-text("Request Entry")')
    ).toBeVisible();
  });

  test("switching between sign in and register tabs", async ({ page }) => {
    await page.goto("/login");
    await page.waitForTimeout(2000);

    // Start on sign in — no display name field
    await expect(
      page.locator('input[placeholder="Your name"]')
    ).not.toBeVisible();

    // Switch to register
    await page.locator('button:has-text("Register")').first().click();
    await page.waitForTimeout(300);
    await expect(
      page.locator('input[placeholder="Your name"]')
    ).toBeVisible();

    // Switch back to sign in
    await page.locator('button:has-text("Sign In")').first().click();
    await page.waitForTimeout(300);
    await expect(
      page.locator('input[placeholder="Your name"]')
    ).not.toBeVisible();
  });
});
