import { test, expect } from "@playwright/test";
import {
  extractLink,
  fetchSentEmails,
  mintOrSkip,
  signInViaForm,
  uniqueEmail,
} from "./helpers";

/**
 * The subject here is password RESET, not registration — so the throwaway user
 * each test resets is minted via POST /api/test/session, outside
 * the `:auth` rate bucket, rather than through the register→confirm dance. The
 * reset flow proper (forgot form → emailed link → new password → sign in) stays
 * a real end-to-end journey. `mintOrSkip` skips cleanly where the helper is off.
 */

test.describe("Password reset", () => {
  test("the forgot-password form opens in the login card and sends a reset email", async ({
    page,
    request,
  }) => {
    const session = await mintOrSkip(request, {
      email: uniqueEmail("e2e-forgot"),
    });
    const email = session.email;

    await page.goto("/login");
    await page.getByTestId("forgot-password-link").click();
    await expect(page.locator(".login-card__subtitle").first()).toContainText(
      "Reset your password",
    );
    await expect(page.getByTestId("forgot-email")).toBeVisible();

    await page.getByTestId("forgot-email").fill(email);
    await page.getByTestId("forgot-submit").click();
    const ack = page.getByTestId("forgot-success");
    await expect(ack).toBeVisible();

    await expect(ack).toHaveAttribute("role", "status");
    await expect(ack).toHaveClass(/login-card__notice/);
    await expect(ack).not.toHaveClass(/login-card__subtitle/);

    const submit = page.getByTestId("forgot-submit");
    await expect(submit).toBeDisabled();
    await expect(submit).toHaveText("Reset link sent");

    const emails = await fetchSentEmails(request, email);
    test.skip(
      emails === null,
      "requires the readable Local mailbox (/api/test/sent-emails)",
    );
    const reset = emails!.find((e) => /reset/i.test(e.subject));
    expect(reset, "expected a password-reset email").toBeTruthy();
    expect(extractLink(reset!, /\/reset-password\/[^"'\s]+/)).toBeTruthy();
  });

  test("full flow: forgot → email link → new password → sign in", async ({
    page,
    request,
  }) => {
    const session = await mintOrSkip(request, {
      email: uniqueEmail("e2e-reset"),
    });
    const email = session.email;
    const newPassword = "brand-new-password-2";

    await page.goto("/forgot-password");
    await page.getByTestId("forgot-email").fill(email);
    await page.getByTestId("forgot-submit").click();
    await expect(page.getByTestId("forgot-success")).toBeVisible();

    const emails = await fetchSentEmails(request, email);
    test.skip(emails === null, "requires the /api/test/sent-emails helper");
    const reset = emails!.find((e) => /reset/i.test(e.subject));
    expect(reset).toBeTruthy();
    const link = extractLink(reset!, /\/reset-password\/[^"'\s]+/);
    expect(link).toBeTruthy();

    await page.goto(link!);
    await expect(page.locator(".page--login h1")).toHaveText(
      "Choose a new password",
    );
    await page.getByTestId("reset-password").fill(newPassword);
    await page.getByTestId("reset-confirm").fill(newPassword);
    await page.getByTestId("reset-submit").click();
    await expect(page.getByTestId("reset-success")).toBeVisible();

    await expect(page).toHaveURL(/\/login$/, { timeout: 10_000 });

    await signInViaForm(page, email, newPassword);
    await expect(page).toHaveURL(/\/antilibrary/);
  });
});
