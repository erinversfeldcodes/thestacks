import { test, expect } from "@playwright/test";
import { suiteEmail, uniqueEmail } from "./helpers";

/**
 * Fill the register form (all four fields). Assumes the login page is loaded.
 * Switches into Register mode and populates display name / email / password /
 * confirm password using the stable ids from Page.Login.
 */
async function fillRegisterForm(
  page: import("@playwright/test").Page,
  opts: { displayName: string; email: string; password: string; confirm?: string }
) {
  await page.locator('button:has-text("Register")').first().click();
  await page.fill('input[id="display-name"]', opts.displayName);
  await page.fill('input[id="email"]', opts.email);
  await page.fill('input[id="password"]', opts.password);
  await page.fill(
    'input[id="password-confirm"]',
    opts.confirm ?? opts.password
  );
}

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

test.describe("Registration → pending (Bug-2/3 invariant)", () => {
  test("successful registration shows the 'check your inbox' card and stores NO auth token", async ({
    page,
  }) => {
    const email = uniqueEmail();
    await page.goto("/login");

    await fillRegisterForm(page, {
      displayName: "New Reader",
      email,
      password: "a-strong-password",
    });

    // Submit should be enabled once all four fields validate.
    const submit = page.getByTestId("login-submit");
    await expect(submit).toBeEnabled();
    await submit.click();

    // The pending card appears, naming the email the confirmation was sent to.
    const pending = page.getByTestId("registration-pending");
    await expect(pending).toBeVisible();
    await expect(pending).toContainText("Check your inbox!");
    await expect(pending).toContainText(email);

    // Bug-2 invariant: registration does NOT navigate into the app.
    await expect(page).toHaveURL(/\/login/);

    // Bug-3 invariant: registration stores NO JWT — the account is inert until
    // the email is confirmed.
    const stored = await page.evaluate(() =>
      localStorage.getItem("stacks-auth")
    );
    expect(stored).toBeFalsy();

    // "Back to Sign In" returns the user to the login form.
    await page.getByTestId("back-to-sign-in").click();
    await expect(page.getByTestId("login-form")).toBeVisible();
    await expect(page.getByTestId("registration-pending")).toHaveCount(0);
  });
});

test.describe("Registration — sad paths", () => {
  test("mismatched confirm password disables submit and shows 'Passwords do not match'", async ({
    page,
  }) => {
    await page.goto("/login");

    await fillRegisterForm(page, {
      displayName: "Mismatch Reader",
      email: uniqueEmail(),
      password: "a-strong-password",
      confirm: "a-different-password",
    });

    await expect(
      page.locator(".login-card__hint--error", {
        hasText: "Passwords do not match",
      })
    ).toBeVisible();
    await expect(page.getByTestId("login-submit")).toBeDisabled();
  });

  test("duplicate email surfaces the email-in-use message (real 422)", async ({
    page,
  }) => {
    await page.goto("/login");

    // The "auth" suite user is seeded and confirmed — registering with its
    // email must hit the unique-constraint 422 on the real backend.
    await fillRegisterForm(page, {
      displayName: "Impostor",
      email: suiteEmail("auth"),
      password: "a-strong-password",
    });

    await page.getByTestId("login-submit").click();

    const error = page.getByTestId("login-error");
    await expect(error).toBeVisible();
    await expect(error).toContainText("already frequents these halls");
  });

  test("a too-short password is blocked with a password message, not the email-in-use copy", async ({
    page,
  }) => {
    // Front and back both require >= 8 chars, so a weak password is rejected at
    // the field level and submit never fires. The message shown must be about
    // the password — never the email-in-use copy meant for duplicate accounts.
    await page.goto("/login");

    await fillRegisterForm(page, {
      displayName: "Weak Reader",
      email: uniqueEmail(),
      password: "short",
    });

    const passwordField = page
      .locator(".login-card__field", { has: page.locator('input[id="password"]') })
      .locator(".login-card__hint--error");
    await expect(passwordField).toContainText("at least 8 characters");
    await expect(passwordField).not.toContainText("frequents these halls");

    await expect(page.getByTestId("login-submit")).toBeDisabled();
  });
});
