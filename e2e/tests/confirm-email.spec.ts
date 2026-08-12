import { test, expect } from "@playwright/test";
import {
  extractLink,
  fetchConfirmationToken,
  fetchSentEmails,
  registerViaApi,
  uniqueEmail,
} from "./helpers";

test.describe("Email confirmation pages", () => {
  test("success page renders heading and sign-in link", async ({ page }) => {
    await page.goto("/confirm-email/success");

    await expect(page.locator(".login-card__title")).toHaveText(
      "Email confirmed"
    );
    await expect(page.locator(".login-card__subtitle")).toContainText(
      "verified"
    );

    const signInLink = page.locator('.login-card a[href="/login"]');
    await expect(signInLink).toBeVisible();
    await expect(signInLink).toHaveText("Sign in");
  });

  test("error page renders heading and back-to-sign-in link", async ({ page }) => {
    await page.goto("/confirm-email/error");

    await expect(page.locator(".login-card__title")).toHaveText(
      "Confirmation failed"
    );
    await expect(page.locator(".login-card__subtitle")).toContainText(
      "expired"
    );

    const backLink = page.locator('.login-card a[href="/login"]');
    await expect(backLink).toBeVisible();
    await expect(backLink).toHaveText("Back to sign in");
  });

  test("invalid confirmation token redirects to error page", async ({
    page,
  }) => {
    await page.goto("/api/auth/confirm/not-a-real-token");

    await expect(page).toHaveURL(/\/confirm-email\/error/);
    await expect(page.locator(".login-card__title")).toHaveText(
      "Confirmation failed"
    );
  });

  test("sign-in link on success page navigates to login", async ({ page }) => {
    await page.goto("/confirm-email/success");

    await page.click('.login-card a[href="/login"]');

    await expect(page).toHaveURL(/\/login/);
  });
});

test.describe("Email confirmation — full flow", () => {
  test("register → confirm real token → redirect to success page", async ({
    page,
    request,
  }) => {
    const email = uniqueEmail("e2e-confirm");
    const reg = await registerViaApi(request, {
      email,
      password: "a-strong-password",
      displayName: "Confirm Flow",
    });
    expect(reg.ok()).toBeTruthy();

    const token = await fetchConfirmationToken(request, email);
    test.skip(
      token === null,
      "requires the /api/test/confirmation-token helper (STACKS_E2E_TEST_HELPERS=1)"
    );

    await page.goto(`/api/auth/confirm/${token}`);

    await expect(page).toHaveURL(/\/confirm-email\/success/);
    await expect(page.locator(".login-card__title")).toHaveText(
      "Email confirmed"
    );
  });

  test("register → confirmation email is sent → its link confirms the account", async ({
    page,
    request,
  }) => {
    const email = uniqueEmail("e2e-mailflow");
    const reg = await registerViaApi(request, {
      email,
      password: "a-strong-password",
      displayName: "Mail Flow",
    });
    expect(reg.ok()).toBeTruthy();

    // Delivery is asynchronous by design (registration emits an event; an Oban
    // worker sends the email), so the mailbox is polled: one immediate read
    // raced the worker and failed on any stack slower than the local one.
    let emails = await fetchSentEmails(request, email);
    test.skip(
      emails === null,
      "requires the /api/test/sent-emails helper (STACKS_E2E_TEST_HELPERS=1)"
    );
    await expect(async () => {
      emails = await fetchSentEmails(request, email);
      expect(emails!.length).toBeGreaterThan(0);
    }).toPass({ timeout: 30_000, intervals: [1_000, 2_000, 5_000] });
    const confirmation = emails!.find((e) => /confirm/i.test(e.subject));
    expect(
      confirmation,
      "expected a confirmation email with 'Confirm' in the subject"
    ).toBeTruthy();

    const link = extractLink(confirmation!, /\/api\/auth\/confirm\/[^"'\s]+/);
    expect(link, "confirmation email must carry a /api/auth/confirm/ link").toBeTruthy();

    await page.goto(link!);
    await expect(page).toHaveURL(/\/confirm-email\/success/);
    await expect(page.locator(".login-card__title")).toHaveText(
      "Email confirmed"
    );

    const tokenAfter = await fetchConfirmationToken(request, email);
    expect(tokenAfter).toBeNull();
  });
});
