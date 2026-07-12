import { test, expect } from "@playwright/test";
import {
  fetchConfirmationToken,
  registerViaApi,
  uniqueEmail,
} from "./helpers";

test.describe("Email confirmation pages", () => {
  test("success page renders heading and sign-in link", async ({ page }) => {
    await page.goto("/confirm-email/success");

    await expect(page.locator(".page--confirm-email h1")).toHaveText(
      "Email confirmed"
    );
    await expect(page.locator(".page--confirm-email p")).toContainText(
      "verified"
    );

    const signInLink = page.locator('.page--confirm-email a[href="/login"]');
    await expect(signInLink).toBeVisible();
    await expect(signInLink).toHaveText("Sign in");
  });

  test("error page renders heading and go-home link", async ({ page }) => {
    await page.goto("/confirm-email/error");

    await expect(page.locator(".page--confirm-email h1")).toHaveText(
      "Confirmation failed"
    );
    await expect(page.locator(".page--confirm-email p")).toContainText(
      "expired"
    );

    const homeLink = page.locator('.page--confirm-email a[href="/"]');
    await expect(homeLink).toBeVisible();
    await expect(homeLink).toHaveText("Go home");
  });

  test("invalid confirmation token redirects to error page", async ({
    page,
  }) => {
    // Playwright follows the 302 redirect from the backend, so this exercises
    // the full pipeline: API endpoint → redirect → Elm error page.
    await page.goto("/api/auth/confirm/not-a-real-token");

    await expect(page).toHaveURL(/\/confirm-email\/error/);
    await expect(page.locator(".page--confirm-email h1")).toHaveText(
      "Confirmation failed"
    );
  });

  test("sign-in link on success page navigates to login", async ({ page }) => {
    await page.goto("/confirm-email/success");

    await page.click('.page--confirm-email a[href="/login"]');

    await expect(page).toHaveURL(/\/login/);
  });
});

test.describe("Email confirmation — full flow", () => {
  test("register → confirm real token → redirect to success page", async ({
    page,
    request,
  }) => {
    // 1. Register a brand-new (unconfirmed) user via the API.
    const email = uniqueEmail("e2e-confirm");
    const reg = await registerViaApi(request, {
      email,
      password: "a-strong-password",
      displayName: "Confirm Flow",
    });
    expect(reg.ok()).toBeTruthy();

    // 2. Retrieve that user's confirmation token via the test-helper endpoint.
    //    We never rely on real email delivery in CI.
    const token = await fetchConfirmationToken(request, email);
    test.skip(
      token === null,
      "requires the /api/test/confirmation-token helper (STACKS_E2E_TEST_HELPERS=1)"
    );

    // 3. Hitting the confirm endpoint 302s through to the Elm success page.
    await page.goto(`/api/auth/confirm/${token}`);

    await expect(page).toHaveURL(/\/confirm-email\/success/);
    await expect(page.locator(".page--confirm-email h1")).toHaveText(
      "Email confirmed"
    );
  });
});
