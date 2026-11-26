import { test, expect, newProvenContext} from "./fixtures";
import { hasSessionCookie } from "./helpers";

const DEV_EMAIL = "owner@thestacks.app";
const DEV_PASSWORD = "dev-password-123";

test.describe("Private/incognito session isolation", () => {
  test("fresh browser context has no stored auth and shows login state", async ({
    browser,
  }) => {
    const context = await newProvenContext(browser);
    const page = await context.newPage();

    await page.goto("/");

    await expect(page.locator('a[href="/login"]')).toBeVisible();
    await expect(page.getByTestId('user-menu')).not.toBeVisible();

    expect(
      await hasSessionCookie(page),
      "a fresh private context must hold no session"
    ).toBe(false);

    await context.close();
  });

  test("auth does not leak between browser contexts", async ({ browser }) => {
    const ctx1 = await newProvenContext(browser);
    const page1 = await ctx1.newPage();

    await page1.goto("/login");
    await page1.fill('input[id="email"]', DEV_EMAIL);
    await page1.fill('input[id="password"]', DEV_PASSWORD);
    await page1.getByTestId('login-submit').click();
    await page1.waitForURL("**/antilibrary", { timeout: 15000 });

    expect(
      await hasSessionCookie(page1),
      "the signed-in context must hold a session"
    ).toBe(true);

    const ctx2 = await newProvenContext(browser);
    const page2 = await ctx2.newPage();

    await page2.goto("/");

    expect(
      await hasSessionCookie(page2),
      "a second context must not inherit the first's session"
    ).toBe(false);

    await expect(page2.locator('a[href="/login"]')).toBeVisible();
    await expect(page2.getByTestId('user-menu')).not.toBeVisible();

    await ctx1.close();
    await ctx2.close();
  });

  test("navigating to a protected page without auth shows login", async ({
    browser,
  }) => {
    const context = await newProvenContext(browser);
    const page = await context.newPage();

    await page.goto("/library");

    await expect(page.locator('input[id="email"]')).toBeVisible();

    await context.close();
  });
});
