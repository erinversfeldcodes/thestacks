import { test, expect } from "@playwright/test";
import type { APIRequestContext, Page } from "@playwright/test";
import {
  E2E_PASSWORD,
  uniqueEmail,
  registerViaApi,
  fetchConfirmationToken,
  signInViaForm,
  ensureBookOnLibrary,
} from "./helpers";

/**
 * Browser E2E for the GDPR self-service journeys on Settings → Privacy:
 *   - Export My Data  (US-8.1, issue #187)
 *   - Delete My Data  (US-8.2, issue #188)
 *
 * Previously only covered by elm-program-test, which stubs the HTTP boundary —
 * the real UI → deployed backend → session-teardown path was never observed
 * live. That gap matters most for account deletion (irreversible right to
 * erasure), so both journeys are driven against the real preview stack.
 *
 * Each test owns a throwaway user (single-owner fixtures, no cross-file sharing).
 * Export is a side-effecting write (queues a DataExportJob + emits an audit
 * event), so it must NOT run against another spec's seeded user. Delete is
 * destructive, so it inherently needs its own user. A brand-new user is
 * placement-free and so gets the global onboarding overlay (which intercepts
 * clicks everywhere, incl. settings); placing a book satisfies the onboarding
 * check before we drive the UI.
 *
 * Both require the /api/test/confirmation-token helper (STACKS_E2E_TEST_HELPERS=1)
 * and test.skip cleanly without it, matching onboarding.spec / confirm-email.spec.
 */

test.describe("GDPR — Export & Delete (live browser journeys)", () => {
  test("export: requesting a data export queues it against the real backend", async ({
    page,
    request,
  }) => {
    const { email, token } = await registerAndConfirm(request, "e2e-gdpr-export");
    test.skip(
      token === null,
      "requires the /api/test/confirmation-token helper (STACKS_E2E_TEST_HELPERS=1)"
    );

    await signInAndSuppressOnboarding(page, email);
    await page.goto("/settings/privacy");
    await expect(page.getByTestId("onboarding-overlay")).not.toBeVisible();

    const exportBtn = page.getByRole("button", { name: "Export My Data" });
    await expect(exportBtn).toBeVisible({ timeout: 10000 });

    await exportBtn.click();

    // POST /api/gdpr/export returns 202; Privacy.elm swaps to the queued state.
    await expect(page.getByText("Export queued")).toBeVisible({ timeout: 10000 });
    // The error paragraph must not appear on success.
    await expect(page.locator(".error")).toHaveCount(0);
  });

  test("delete: type-to-confirm deletes the account, logs out, and invalidates the session", async ({
    page,
    request,
  }) => {
    const { email, token } = await registerAndConfirm(request, "e2e-gdpr-delete");
    test.skip(
      token === null,
      "requires the /api/test/confirmation-token helper (STACKS_E2E_TEST_HELPERS=1)"
    );

    await signInAndSuppressOnboarding(page, email);

    // Capture the live session token BEFORE deletion so we can prove the session
    // is actually invalidated afterwards (localStorage is cleared on logout).
    const authToken = await page.evaluate(
      () => JSON.parse(localStorage.getItem("stacks-auth") || "{}").token
    );
    expect(authToken).toBeTruthy();

    await page.goto("/settings/privacy");
    // Guard: the onboarding overlay must be gone, or it will silently eat clicks.
    await expect(page.getByTestId("onboarding-overlay")).not.toBeVisible();

    // Reveal the type-to-confirm dialog.
    await page.getByRole("button", { name: "Delete My Data" }).click();
    const confirmInput = page.locator("#delete-confirmation");
    await expect(confirmInput).toBeVisible();

    // The destructive submit lives inside the confirm block; scope to it so the
    // reveal button (same label) can't be matched.
    const submit = page
      .locator(".privacy__delete-confirm")
      .getByRole("button", { name: "Delete My Data" });

    // Guard: disabled until the confirmation text is EXACTLY "DELETE".
    await expect(submit).toBeDisabled();
    await confirmInput.fill("delete"); // wrong case
    await expect(submit).toBeDisabled();
    await confirmInput.fill("DELETE");
    await expect(submit).toBeEnabled();

    await submit.click();

    // DELETE /api/gdpr/account returns 202 and enqueues the erasure job.
    await expect(
      page.getByText("Account deletion has been queued")
    ).toBeVisible({ timeout: 10000 });

    // On success the client logs the user out and redirects to /login.
    await page.waitForURL("**/login", { timeout: 15000 });

    // End-to-end erasure proof: the deletion job runs async, so the session
    // invalidation is eventual — poll the captured token against an
    // authenticated endpoint until it is rejected with 401.
    await expect
      .poll(
        async () => {
          const resp = await request.get("/api/settings/audit-log?page=1", {
            headers: { Authorization: `Bearer ${authToken}` },
          });
          return resp.status();
        },
        {
          message: "session should be invalidated once the erasure job runs",
          timeout: 30000,
          intervals: [1000, 2000, 3000, 5000],
        }
      )
      .toBe(401);
  });
});

/**
 * Register a throwaway user via the API and confirm its email through the
 * test-helper token. Returns the email and the confirmation token (null when the
 * helper endpoint is unavailable, so the caller can test.skip).
 *
 * `/api/auth/register` is under the `:auth` rate bucket (60/60s per IP), shared
 * across the whole parallel suite, so a transient 429 burst is absorbed with a
 * bounded backoff-retry rather than failing the test outright.
 */
async function registerAndConfirm(
  request: APIRequestContext,
  prefix: string
): Promise<{ email: string; token: string | null }> {
  const email = uniqueEmail(prefix);

  let reg = await registerViaApi(request, { email, password: E2E_PASSWORD });
  for (let attempt = 1; attempt <= 4 && !reg.ok() && reg.status() === 429; attempt++) {
    await new Promise((resolve) => setTimeout(resolve, 2000 * attempt));
    reg = await registerViaApi(request, { email, password: E2E_PASSWORD });
  }
  expect(reg.ok(), `register failed with HTTP ${reg.status()}`).toBeTruthy();

  const token = await fetchConfirmationToken(request, email);
  if (token === null) return { email, token: null };

  const confirm = await request.get(`/api/auth/confirm/${token}`);
  expect(confirm.ok()).toBeTruthy();
  return { email, token };
}

/**
 * Sign the fresh user in and suppress the onboarding overlay. A placement-free
 * user gets the global onboarding modal, whose backdrop intercepts pointer
 * events on every page (including settings); placing a book satisfies the
 * onboarding check so the overlay stays hidden across reloads.
 */
async function signInAndSuppressOnboarding(page: Page, email: string): Promise<void> {
  await signInViaForm(page, email, E2E_PASSWORD);
  await ensureBookOnLibrary(page);
}
