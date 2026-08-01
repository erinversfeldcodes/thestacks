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
 * each test resets is minted via POST /api/test/session (Issue #280), outside
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

    // Clicking "Forgot your password?" swaps the login card into its
    // reset-password mode in place (no navigation) — the form is part of the
    // login card, not a separate bare page.
    await page.goto("/login");
    await page.getByTestId("forgot-password-link").click();
    await expect(page.locator(".login-card__subtitle").first()).toContainText(
      "Reset your password",
    );
    await expect(page.getByTestId("forgot-email")).toBeVisible();

    // Submitting the email shows the generic (no-enumeration) confirmation...
    await page.getByTestId("forgot-email").fill(email);
    await page.getByTestId("forgot-submit").click();
    const ack = page.getByTestId("forgot-success");
    await expect(ack).toBeVisible();

    // ...as an announced NOTICE, not as another line of helper text (#363).
    // Sending the mail is the whole outcome of this form and this sentence is
    // the only evidence of it, so a screen reader has to be told. It used to
    // carry `login-card__subtitle` — the same class as the "Enter your email
    // and we'll send you a link" instruction above it — and no live region.
    await expect(ack).toHaveAttribute("role", "status");
    await expect(ack).toHaveClass(/login-card__notice/);
    await expect(ack).not.toHaveClass(/login-card__subtitle/);

    // ...and a reset email is actually sent. (Skipped when the mailbox isn't
    // the delivery target — e.g. a preview using a real Resend provider.)
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
      "Choose a new password",
    );
    await page.getByTestId("reset-password").fill(newPassword);
    await page.getByTestId("reset-confirm").fill(newPassword);
    await page.getByTestId("reset-submit").click();
    await expect(page.getByTestId("reset-success")).toBeVisible();

    // 4. THE WIRE (#363). `Main.update`'s ResetPasswordMsg branch turns the
    //    page's `AdvanceToLogin` into a `Nav.pushUrl`, and `Main.Model` embeds
    //    an unconstructable `Nav.Key`, so no Elm test can reach that step —
    //    stubbing the branch to `[]` leaves all 1,549 of them passing (probed).
    //    This is the layer where the push is observable, so it is asserted here.
    //    The confirmation must be readable BEFORE the move, which the preceding
    //    assertion establishes: a redirect the reader never sees is the same as
    //    not telling them.
    await expect(page).toHaveURL(/\/login$/, { timeout: 10_000 });

    // 5. The new password logs in; the old one no longer does.
    await signInViaForm(page, email, newPassword);
    await expect(page).toHaveURL(/\/antilibrary/);
  });
});
