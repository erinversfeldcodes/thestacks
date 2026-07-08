import { test, expect } from "@playwright/test";
import { signInViaForm, suiteAuthFile } from "./helpers";

const DEV_EMAIL = "owner@thestacks.app";
const DEV_PASSWORD = "dev-password-123";

test.describe("Authentication", () => {
  test("sign in with valid credentials navigates to home and shows user name", async ({
    page,
  }) => {
    await page.goto("/login");

    await page.fill('input[id="email"]', DEV_EMAIL);
    await page.fill('input[id="password"]', DEV_PASSWORD);
    await page.getByTestId('login-submit').click();

    // Should redirect to antilibrary after login transition completes (~4s animation)
    await page.waitForURL("**/antilibrary", { timeout: 15000 });

    // Nav should show the user's display name instead of "Sign In"
    await expect(page.getByTestId('user-menu')).toHaveText("Platform Owner");
    await expect(page.locator('a[href="/login"]')).not.toBeVisible();
  });

  test("sign in with wrong password shows error message", async ({ page }) => {
    await page.goto("/login");

    await page.fill('input[id="email"]', DEV_EMAIL);
    await page.fill('input[id="password"]', "wrong-password");
    await page.getByTestId('login-submit').click();

    await expect(page.getByTestId('login-error')).toBeVisible();
    await expect(page.getByTestId('login-error')).toContainText(
      "The door remains shut."
    );

    // Should stay on login page
    await expect(page).toHaveURL("/login");
  });

  test("sign in with unknown email shows error message", async ({ page }) => {
    await page.goto("/login");

    await page.fill('input[id="email"]', "nobody@example.com");
    await page.fill('input[id="password"]', DEV_PASSWORD);
    await page.getByTestId('login-submit').click();

    await expect(page.getByTestId('login-error')).toBeVisible();
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
    await page.getByTestId('login-submit').click();
    // waitForURL is more reliable than toHaveURL here — Nav.pushUrl is async
    await page.waitForURL("**/antilibrary", { timeout: 15000 });

    // The upload link is inside the Catalogue dropdown — hover to reveal it.
    // Use the nav link to preserve Elm's in-memory auth state.
    // A full page.goto("/upload") would reload and reset the model to auth=Nothing.
    await page.hover('.app-nav__dropdown .app-nav__link:has-text("Catalogue")');
    await page.click('a[href="/upload"]');
    await page.waitForURL("/upload");

    // Should show the upload area, not the auth-required prompt
    await expect(page.getByTestId('upload-auth-required')).not.toBeVisible();
    await expect(page.getByTestId('upload-drop-zone')).toBeVisible();
  });
});

test.describe("Owner-only admin navigation", () => {
  test("the platform owner sees the Admin dropdown (Metrics/Sources/Scrapers)", async ({
    page,
  }) => {
    await signInViaForm(page, DEV_EMAIL, DEV_PASSWORD);

    // navDropdown renders the "Admin" primary as a dropdown toggle link that
    // points at the metrics page; the Sources/Scrapers sub-links live in a
    // sibling <ul class="app-nav__dropdown-menu"> that CSS keeps display:none
    // until the dropdown is hovered (or focus-within). Target the toggle by
    // its accessible role/name, then hover to reveal the sub-links.
    const adminToggle = page.getByRole("link", { name: "Admin", exact: true });
    await expect(adminToggle).toBeVisible();
    await expect(adminToggle).toHaveAttribute("href", "/admin/metrics");

    // Hovering the toggle reveals the dropdown menu (:hover -> display:block).
    await adminToggle.hover();

    const sources = page.locator('a[href="/admin/sources"]');
    const scrapers = page.locator('a[href="/admin/scrapers"]');
    await expect(sources).toBeVisible();
    await expect(sources).toHaveText("Sources");
    await expect(scrapers).toBeVisible();
    await expect(scrapers).toHaveText("Scrapers");
  });
});

test.describe("Non-owner admin navigation", () => {
  // The "auth" suite user is a plain role=user account.
  test.use({ storageState: suiteAuthFile("auth") });

  test("a non-owner user does not see the Admin dropdown", async ({ page }) => {
    await page.goto("/library");

    // Authenticated nav is present …
    await expect(page.getByTestId("user-menu")).toBeVisible();
    // … but there is no Admin entry point of any kind.
    await expect(page.locator('a[href="/admin/metrics"]')).toHaveCount(0);
    await expect(page.locator('a[href="/admin/sources"]')).toHaveCount(0);
    await expect(page.locator('a[href="/admin/scrapers"]')).toHaveCount(0);
  });
});

test.describe("Logout", () => {
  test("signing out ends the session, reverts the nav, and kills the token server-side", async ({
    page,
  }) => {
    await signInViaForm(page, DEV_EMAIL, DEV_PASSWORD);

    // Capture the live token so we can prove it is revoked after logout.
    const token = await page.evaluate(
      () => JSON.parse(localStorage.getItem("stacks-auth") || "{}").token
    );
    expect(token).toBeTruthy();

    // Open the display-name menu and sign out.
    await page.getByTestId("user-menu").click();
    await page.getByRole("button", { name: "Sign Out" }).click();

    await page.waitForURL("**/login");

    // Nav reverts to the unauthenticated state.
    await expect(page.locator('a[href="/login"]')).toBeVisible();
    await expect(page.getByTestId("user-menu")).toHaveCount(0);

    // Local session cleared.
    const stored = await page.evaluate(() =>
      localStorage.getItem("stacks-auth")
    );
    expect(stored).toBeFalsy();

    // A protected page bounces back to the login form.
    await page.goto("/upload");
    await expect(page.locator('input[id="email"]')).toBeVisible();

    // A2 revocation: the pre-logout token is dead server-side (guardian_db).
    const resp = await page.request.get("/api/placements/mine", {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(resp.status()).toBe(401);
  });
});
