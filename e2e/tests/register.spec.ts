import { test, expect } from "@playwright/test";
import type { APIRequestContext, Page } from "@playwright/test";
import { ownerAdminToken, suiteEmail, uniqueEmail } from "./helpers";

/**
 * Registration under the closed-beta gate (US-14.1.3).
 *
 * The preview stack runs with INVITE_ONLY_REGISTRATION=true — the launch
 * posture — so the Register tab opens on the invite-only panel and every
 * registration here first redeems a real, owner-issued code. The gate's own
 * refusal paths live in invite-gate.spec.ts; this file covers what
 * registration itself promises once the door is open.
 */

/** Mint a fresh single-use invitation via the owner's admin API. */
async function mintInvite(request: APIRequestContext): Promise<string> {
  const token = await ownerAdminToken(request);
  const created = await request.post("/api/admin/invites", {
    headers: { Authorization: `Bearer ${token}` },
    data: { note: "register.spec journey" },
  });
  expect(created.status(), "invite create").toBe(201);
  const code = (await created.json()).invite.code as string;
  expect(code, "the create response carries the full code — the only one that ever does").toBeTruthy();
  return code;
}

/**
 * Open the Register tab and redeem `code` through the invite-only panel,
 * revealing the registration form.
 */
async function redeemOnRegisterTab(page: Page, code: string) {
  await page.locator('button:has-text("Register")').first().click();
  await expect(page.getByTestId("invite-only-panel")).toBeVisible();
  await page.getByTestId("invite-code-input").fill(code);
  await page.getByTestId("invite-redeem-button").click();
  await expect(page.locator('input[id="display-name"]')).toBeVisible();
}

/**
 * Redeem an invitation, then fill the register form. Assumes the login page
 * is loaded.
 */
async function fillRegisterForm(
  page: Page,
  request: APIRequestContext,
  opts: { displayName: string; email: string; password: string; confirm?: string }
) {
  await redeemOnRegisterTab(page, await mintInvite(request));
  await page.fill('input[id="display-name"]', opts.displayName);
  await page.fill('input[id="email"]', opts.email);
  await page.fill('input[id="password"]', opts.password);
  await page.fill(
    'input[id="password-confirm"]',
    opts.confirm ?? opts.password
  );
}

test.describe("Registration flow", () => {
  test("the register tab opens on the invite panel; a redeemed code reveals the form", async ({
    page,
    request,
  }) => {
    await page.goto("/login");
    await page.waitForTimeout(2000);

    await redeemOnRegisterTab(page, await mintInvite(request));

    await expect(page.locator('input[placeholder="Your name"]')).toBeVisible();
    await expect(
      page.locator('input[placeholder="you@example.com"]')
    ).toBeVisible();
    await expect(
      page.locator('input[placeholder="Enter your password"]')
    ).toBeVisible();
    // The accepted code is held read-only, exactly as checked.
    await expect(page.getByTestId("invite-code-input")).toHaveAttribute(
      "readonly",
      "readonly"
    );
  });

  test("the revealed register form has a submit button", async ({ page, request }) => {
    await page.goto("/login");
    await page.waitForTimeout(2000);

    await redeemOnRegisterTab(page, await mintInvite(request));

    await expect(
      page.locator('button:has-text("Request Entry")')
    ).toBeVisible();
  });

  test("switching between sign in and register tabs", async ({ page }) => {
    await page.goto("/login");
    await page.waitForTimeout(2000);

    // Start on sign in — no display name field, no panel.
    await expect(
      page.locator('input[placeholder="Your name"]')
    ).not.toBeVisible();

    // Switch to register: the gate panel, not the form (US-14.1.3).
    await page.locator('button:has-text("Register")').first().click();
    await expect(page.getByTestId("invite-only-panel")).toBeVisible();
    await expect(
      page.locator('input[placeholder="Your name"]')
    ).not.toBeVisible();

    // Switch back to sign in — the panel goes with the tab.
    await page.locator('button:has-text("Sign In")').first().click();
    await expect(page.getByTestId("invite-only-panel")).not.toBeVisible();
  });
});

test.describe("Registration → pending (Bug-2/3 invariant)", () => {
  test("successful registration shows the 'check your inbox' card and stores NO auth token", async ({
    page,
    request,
  }) => {
    const email = uniqueEmail();
    await page.goto("/login");

    await fillRegisterForm(page, request, {
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
    request,
  }) => {
    await page.goto("/login");

    await fillRegisterForm(page, request, {
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
    request,
  }) => {
    await page.goto("/login");

    // The "auth" suite user is seeded and confirmed — registering with its
    // email must hit the unique-constraint 422 on the real backend.
    await fillRegisterForm(page, request, {
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
    request,
  }) => {
    // Front and back both require >= 8 chars, so a weak password is rejected at
    // the field level and submit never fires. The message shown must be about
    // the password — never the email-in-use copy meant for duplicate accounts.
    await page.goto("/login");

    await fillRegisterForm(page, request, {
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
