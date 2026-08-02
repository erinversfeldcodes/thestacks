import { test, expect } from "@playwright/test";
import { registerViaApi, uniqueEmail } from "./helpers";

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

test.describe("Unconfirmed-email login", () => {
  test("a freshly-registered (unconfirmed) user is told to confirm their email (403)", async ({
    page,
    request,
  }) => {
    // A brand-new registration is unconfirmed by definition — no seed needed.
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

    // The 403 confirm-your-email path must surface its specific copy — NOT the
    // generic invalid-credentials message.
    const error = page.getByTestId("login-error");
    await expect(error).toBeVisible();
    await expect(error).toContainText(
      "confirm your email address before signing in"
    );
    await expect(error).not.toContainText("The door remains shut");

    // Login is refused — the user stays on the login page with no session.
    await expect(page).toHaveURL(/\/login/);
    const stored = await page.evaluate(() =>
      localStorage.getItem("stacks-auth")
    );
    expect(stored).toBeFalsy();
  });
});

// ───────────────────────────────────────────────────────────────────────────
// Issue #374 — a failure the app cannot explain must not explain it anyway.
//
// ⛔ `Page/Login.elm` mapped EVERY unlisted status onto "The door remains shut.
// Invalid email or password." A 502 from a node restarting mid-deploy therefore
// told a reader their credentials were wrong; they retyped details that were
// already correct, failed again, and had every reason to conclude the account
// was gone. The message did not merely fail to help — it aimed them at the one
// thing that was working.
//
// Route-mocked rather than driven against a real outage, because the whole
// point is a status the server is not supposed to produce. The `:auth` bucket's
// real 429 saturation test lives in `rate-limit.spec.ts`, which runs alone.
// ───────────────────────────────────────────────────────────────────────────
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
    // ⛔ The interval must come from the response or not be said. A hard-coded
    // 60 would keep claiming 60 long after `RateLimiter` was retuned.
    const error = await attemptSignIn(page, 429);
    await expect(error).toContainText(
      "Please wait a little while before trying again."
    );
    await expect(error).not.toContainText("60 seconds");
  });

  test("positive control — a 401 still says the credentials are wrong", async ({
    page,
  }) => {
    // Without this, every assertion above would pass against a page that
    // answered "we cannot say why" to a genuinely wrong password too.
    const error = await attemptSignIn(page, 401);
    await expect(error).toContainText("Invalid credentials");
  });
});
