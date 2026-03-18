import { test, expect } from "@playwright/test";

const DEV_EMAIL = "owner@thestacks.app";
const DEV_PASSWORD = "dev-password-123";

test.describe("Authentication", () => {
  test("sign in with valid credentials navigates to home and shows user name", async ({
    page,
  }) => {
    await page.goto("/login");

    await page.fill('input[id="email"]', DEV_EMAIL);
    await page.fill('input[id="password"]', DEV_PASSWORD);
    await page.click('button.login-card__submit');

    // Should redirect to antilibrary after login transition completes (~4s animation)
    await page.waitForURL("**/antilibrary", { timeout: 15000 });

    // Nav should show the user's display name instead of "Sign In"
    await expect(page.locator(".app-nav__user")).toHaveText("Platform Owner");
    await expect(page.locator('a[href="/login"]')).not.toBeVisible();
  });

  test("sign in with wrong password shows error message", async ({ page }) => {
    await page.goto("/login");

    await page.fill('input[id="email"]', DEV_EMAIL);
    await page.fill('input[id="password"]', "wrong-password");
    await page.click('button.login-card__submit');

    await expect(page.locator(".login-card__error")).toBeVisible();
    await expect(page.locator(".login-card__error")).toContainText(
      "The door remains shut."
    );

    // Should stay on login page
    await expect(page).toHaveURL("/login");
  });

  test("sign in with unknown email shows error message", async ({ page }) => {
    await page.goto("/login");

    await page.fill('input[id="email"]', "nobody@example.com");
    await page.fill('input[id="password"]', DEV_PASSWORD);
    await page.click('button.login-card__submit');

    await expect(page.locator(".login-card__error")).toBeVisible();
    await expect(page).toHaveURL("/login");
  });

  test("upload page redirects to login when not authenticated", async ({
    page,
  }) => {
    await page.goto("/upload");

    // Protected pages redirect to the login form when unauthenticated
    await expect(page.locator('input[id="email"]')).toBeVisible();
  });

  test("upload page is accessible after signing in", async ({ page }) => {
    await page.goto("/login");
    await page.fill('input[id="email"]', DEV_EMAIL);
    await page.fill('input[id="password"]', DEV_PASSWORD);
    await page.click('button.login-card__submit');
    // waitForURL is more reliable than toHaveURL here — Nav.pushUrl is async
    await page.waitForURL("**/antilibrary", { timeout: 15000 });

    // The upload link is inside the Catalogue dropdown — hover to reveal it.
    // Use the nav link to preserve Elm's in-memory auth state.
    // A full page.goto("/upload") would reload and reset the model to auth=Nothing.
    await page.hover('.app-nav__dropdown .app-nav__link:has-text("Catalogue")');
    await page.click('a[href="/upload"]');
    await page.waitForURL("/upload");

    // Should show the upload area, not the auth-required prompt
    await expect(page.locator(".upload-auth-required")).not.toBeVisible();
    await expect(page.locator(".upload-area")).toBeVisible();
  });
});
