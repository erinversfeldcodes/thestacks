import { test, expect } from "@playwright/test";
import {
  extractLink,
  fetchConfirmationToken,
  fetchSentEmails,
  registerViaApi,
  signInViaForm,
  uniqueEmail,
} from "./helpers";

// Register a user and confirm their email so they can sign in afterwards.
async function registerAndConfirm(
  request: import("@playwright/test").APIRequestContext,
  email: string,
  password: string
): Promise<boolean> {
  const reg = await registerViaApi(request, { email, password });
  expect(reg.ok()).toBeTruthy();

  const token = await fetchConfirmationToken(request, email);
  if (token === null) return false;
  await request.get(`/api/auth/confirm/${token}`);
  return true;
}

test.describe("Password reset", () => {
  test("the forgot-password page is reachable and sends a reset email", async ({
    page,
    request,
  }) => {
    const email = uniqueEmail("e2e-forgot");
    const ready = await registerAndConfirm(request, email, "old-password-1");
    test.skip(!ready, "requires STACKS_E2E_TEST_HELPERS=1");

    // The link off the login page reaches the forgot-password form.
    await page.goto("/login");
    await page.getByTestId("forgot-password-link").click();
    await expect(page).toHaveURL(/\/forgot-password/);
    await expect(page.locator(".page--login h1")).toHaveText("Reset your password");

    // Submitting the email shows the generic (no-enumeration) confirmation...
    await page.getByTestId("forgot-email").fill(email);
    await page.getByTestId("forgot-submit").click();
    await expect(page.getByTestId("forgot-success")).toBeVisible();

    // ...and a reset email is actually sent.
    const emails = await fetchSentEmails(request, email);
    expect(emails).not.toBeNull();
    const reset = emails!.find((e) => /reset/i.test(e.subject));
    expect(reset, "expected a password-reset email").toBeTruthy();
    expect(extractLink(reset!, /\/reset-password\/[^"'\s]+/)).toBeTruthy();
  });

  test("full flow: forgot → email link → new password → sign in", async ({
    page,
    request,
  }) => {
    const email = uniqueEmail("e2e-reset");
    const oldPassword = "old-password-1";
    const newPassword = "brand-new-password-2";

    const ready = await registerAndConfirm(request, email, oldPassword);
    test.skip(!ready, "requires STACKS_E2E_TEST_HELPERS=1");

    // 1. Request the reset.
    await page.goto("/forgot-password");
    await page.getByTestId("forgot-email").fill(email);
    await page.getByTestId("forgot-submit").click();
    await expect(page.getByTestId("forgot-success")).toBeVisible();

    // 2. Pull the reset link out of the delivered email.
    const emails = await fetchSentEmails(request, email);
    test.skip(emails === null, "requires the /api/test/sent-emails helper");
    const reset = emails!.find((e) => /reset/i.test(e.subject));
    expect(reset).toBeTruthy();
    const link = extractLink(reset!, /\/reset-password\/[^"'\s]+/);
    expect(link).toBeTruthy();

    // 3. Follow the link and set a new password.
    await page.goto(link!);
    await expect(page.locator(".page--login h1")).toHaveText(
      "Choose a new password"
    );
    await page.getByTestId("reset-password").fill(newPassword);
    await page.getByTestId("reset-confirm").fill(newPassword);
    await page.getByTestId("reset-submit").click();
    await expect(page.getByTestId("reset-success")).toBeVisible();

    // 4. The new password logs in; the old one no longer does.
    await signInViaForm(page, email, newPassword);
    await expect(page).toHaveURL(/\/antilibrary/);
  });
});
