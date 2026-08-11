import { test, expect } from "@playwright/test";
import { registerViaApi, uniqueEmail } from "./helpers";

const DEV_EMAIL = "owner@thestacks.app";
const DEV_PASSWORD = "dev-password-123";

test.describe("Login Page Aesthetic", () => {
  test("login page renders the bookshelf wall with scene layers", async ({
    page,
  }) => {
    await page.goto("/login");

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
    await page.getByTestId('login-submit').click();

    const error = page.getByTestId('login-error');
    await expect(error).toBeVisible();
    await expect(error).toContainText("Invalid");
  });

  test("successful login triggers transition and redirects", async ({
    page,
  }) => {
    await page.goto("/login");

    await page.fill('input[id="email"]', DEV_EMAIL);
    await page.fill('input[id="password"]', DEV_PASSWORD);
    await page.getByTestId('login-submit').click();

    await page.waitForURL("**/antilibrary", { timeout: 15000 });
  });

  test("the register tab holds the closed-beta panel until a code is redeemed", async ({
    page,
  }) => {
    await page.goto("/login");

    await expect(page.locator('input[id="display-name"]')).not.toBeVisible();

    await page.click('button:has-text("Register")');
    await expect(page.getByTestId("invite-only-panel")).toBeVisible();
    await expect(page.locator('input[id="display-name"]')).not.toBeVisible();
  });

  test("navbar shows the unauthenticated top-level links (Catalogue/Search/Marketplace/About/Sign In)", async ({
    page,
  }) => {
    await page.goto("/login");

    await expect(page.locator('a.app-nav__link[href="/login"]')).toBeVisible();
    await expect(
      page.locator('a.app-nav__link[href="/catalogue"]')
    ).toBeVisible();
    await expect(page.locator('a.app-nav__link[href="/search"]')).toBeVisible();
    await expect(
      page.locator('a.app-nav__link[href="/marketplace"]')
    ).toBeVisible();
    await expect(page.locator('a.app-nav__link[href="/about"]')).toBeVisible();

    await expect(page.locator('a[href="/upload"]')).not.toBeVisible();
    await expect(page.locator('a[href="/library"]')).not.toBeVisible();
    await expect(page.locator("button.app-nav__disclosure")).toHaveCount(0);
  });

  test("login card has parchment styling and ARIA attributes", async ({
    page,
  }) => {
    await page.goto("/login");

    await expect(page.locator(".login-card")).toBeVisible();
    await expect(page.locator(".login-card__title")).toHaveText("The Stacks");
    await expect(page.locator(".login-card__subtitle")).toBeVisible();

    await expect(page.locator('input[id="email"]')).toHaveAttribute("aria-required", "true");
    await expect(page.locator('input[id="password"]')).toHaveAttribute("aria-required", "true");

    const tablist = page.locator('[role="tablist"]');
    await expect(tablist).toBeVisible();
    await expect(page.locator('[role="tab"]')).toHaveCount(2);
  });
});

test.describe("Unconfirmed-email login", () => {
  test("a freshly-registered (unconfirmed) user is told to confirm their email (403)", async ({
    page,
    request,
  }) => {
    const email = uniqueEmail("e2e-unconfirmed");
    const password = "a-strong-password";
    const reg = await registerViaApi(request, {
      email,
      password,
      displayName: "Unconfirmed Reader",
    });
    expect(reg.ok()).toBeTruthy();

    await page.goto("/login");
    await page.fill('input[id="email"]', email);
    await page.fill('input[id="password"]', password);
    await page.getByTestId("login-submit").click();

    const error = page.getByTestId("login-error");
    await expect(error).toBeVisible();
    await expect(error).toContainText(
      "confirm your email address before signing in"
    );
    await expect(error).not.toContainText("The door remains shut");

    await expect(page).toHaveURL(/\/login/);
    const stored = await page.evaluate(() =>
      localStorage.getItem("stacks-auth")
    );
    expect(stored).toBeFalsy();
  });
});

test.describe("Sign-in failures name only what the server said", () => {
  const CREDENTIAL_LIE = "Invalid email or password";

  async function attemptSignIn(page, status: number, headers = {}) {
    await page.route("**/api/auth/login", (route) =>
      route.fulfill({
        status,
        headers,
        contentType: "application/json",
        body: JSON.stringify({ error: "mocked" }),
      })
    );

    await page.goto("/login");
    await page.fill('input[id="email"]', DEV_EMAIL);
    await page.fill('input[id="password"]', DEV_PASSWORD);
    await page.getByTestId("login-submit").click();

    const error = page.getByTestId("login-error");
    await expect(error).toBeVisible({ timeout: 5_000 });
    return error;
  }

  test("a 502 does not claim the credentials were wrong", async ({ page }) => {
    const error = await attemptSignIn(page, 502);
    await expect(error).not.toContainText(CREDENTIAL_LIE);
    await expect(error).toContainText("Nothing is wrong with what you entered");
  });

  test("a status nobody anticipated admits it is not understood", async ({
    page,
  }) => {
    const error = await attemptSignIn(page, 418);
    await expect(error).not.toContainText(CREDENTIAL_LIE);
    await expect(error).toContainText("we cannot say why");
  });

  test("a 429 names the wait the server sent", async ({ page }) => {
    const error = await attemptSignIn(page, 429, { "retry-after": "60" });
    await expect(error).not.toContainText(CREDENTIAL_LIE);
    await expect(error).toContainText(
      "Too many attempts from here just now. Please wait a minute before trying again."
    );
  });

  test("a 429 without a retry-after names no interval at all", async ({
    page,
  }) => {
    const error = await attemptSignIn(page, 429);
    await expect(error).toContainText(
      "Please wait a little while before trying again."
    );
    await expect(error).not.toContainText("60 seconds");
  });

  test("positive control — a 401 still says the credentials are wrong", async ({
    page,
  }) => {
    const error = await attemptSignIn(page, 401);
    await expect(error).toContainText("Invalid credentials");
  });
});
