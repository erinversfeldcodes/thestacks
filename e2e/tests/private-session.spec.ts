import { test, expect } from "@playwright/test";

const DEV_EMAIL = "owner@thestacks.app";
const DEV_PASSWORD = "dev-password-123";

test.describe("Private/incognito session isolation", () => {
  test("fresh browser context has no stored auth and shows login state", async ({
    browser,
  }) => {
    // Create a brand new browser context (equivalent to private/incognito window)
    const context = await browser.newContext();
    const page = await context.newPage();

    await page.goto("/");

    // Should NOT be logged in — nav should show "Sign In", not a user name
    await expect(page.locator('a[href="/login"]')).toBeVisible();
    await expect(page.getByTestId('user-menu')).not.toBeVisible();

    // localStorage should not contain auth
    const storedAuth = await page.evaluate(() =>
      localStorage.getItem("stacks-auth")
    );
    expect(storedAuth).toBeNull();

    await context.close();
  });

  test("auth does not leak between browser contexts", async ({ browser }) => {
    // Context 1: log in and verify auth is stored
    const ctx1 = await browser.newContext();
    const page1 = await ctx1.newPage();

    await page1.goto("/login");
    await page1.fill('input[id="email"]', DEV_EMAIL);
    await page1.fill('input[id="password"]', DEV_PASSWORD);
    await page1.getByTestId('login-submit').click();
    await page1.waitForURL("**/antilibrary", { timeout: 15000 });

    const authInCtx1 = await page1.evaluate(() =>
      localStorage.getItem("stacks-auth")
    );
    expect(authInCtx1).toBeTruthy();

    // Context 2: separate context should have NO auth
    const ctx2 = await browser.newContext();
    const page2 = await ctx2.newPage();

    await page2.goto("/");

    const authInCtx2 = await page2.evaluate(() =>
      localStorage.getItem("stacks-auth")
    );
    expect(authInCtx2).toBeNull();

    // Should show unauthenticated nav
    await expect(page2.locator('a[href="/login"]')).toBeVisible();
    await expect(page2.getByTestId('user-menu')).not.toBeVisible();

    await ctx1.close();
    await ctx2.close();
  });

  test("navigating to a protected page without auth shows login", async ({
    browser,
  }) => {
    const context = await browser.newContext();
    const page = await context.newPage();

    // Try to access library directly without auth
    await page.goto("/library");

    // Should render the login form since auth is required
    await expect(page.locator('input[id="email"]')).toBeVisible();

    await context.close();
  });
});
