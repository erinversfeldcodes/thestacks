import { test, expect } from "@playwright/test";
import type { Page } from "@playwright/test";
import {
  uniqueEmail,
  mintSession,
  injectSession,
  ensureBookOnLibrary,
  type MintedSession,
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
 * Users are minted via POST /api/test/session (Issue #192) — one call that
 * creates a confirmed user AND returns its session token, outside the `:auth`
 * rate bucket. This replaces the register→confirmation-token→confirm→login
 * dance (and its 429-backoff retry): the whole parallel suite shares the
 * `:auth` budget (60/60s per IP), so fresh-user specs were flaky under load.
 * Requires STACKS_E2E_TEST_HELPERS=1; tests skip cleanly without it, matching
 * onboarding.spec / confirm-email.spec.
 */

test.describe("GDPR — Export & Delete (live browser journeys)", () => {
  test("export: requesting a data export queues it against the real backend", async ({
    page,
    request,
  }) => {
    const session = await mintSession(request, {
      email: uniqueEmail("e2e-gdpr-export"),
    });
    test.skip(
      session === null,
      "requires the /api/test/session helper (STACKS_E2E_TEST_HELPERS=1)"
    );
    if (!session) return;

    await landAuthenticated(page, session);
    await page.goto("/settings/privacy");
    await expect(page.getByTestId("onboarding-overlay")).not.toBeVisible();

    const exportBtn = page.getByRole("button", { name: "Export My Data" });
    await expect(exportBtn).toBeVisible({ timeout: 10000 });

    await exportBtn.click();

    await expect(page.getByText("Export queued")).toBeVisible({ timeout: 10000 });
    await expect(page.locator(".error")).toHaveCount(0);
  });

  test("delete: type-to-confirm deletes the account, logs out, and invalidates the session", async ({
    page,
    request,
  }) => {
    const session = await mintSession(request, {
      email: uniqueEmail("e2e-gdpr-delete"),
    });
    test.skip(
      session === null,
      "requires the /api/test/session helper (STACKS_E2E_TEST_HELPERS=1)"
    );
    if (!session) return;

    await landAuthenticated(page, session);

    const authToken = await page.evaluate(
      () => JSON.parse(localStorage.getItem("stacks-auth") || "{}").token
    );
    expect(authToken).toBeTruthy();

    await page.goto("/settings/privacy");
    await expect(page.getByTestId("onboarding-overlay")).not.toBeVisible();

    await page.getByRole("button", { name: "Delete My Data" }).click();
    const confirmInput = page.locator("#delete-confirmation");
    await expect(confirmInput).toBeVisible();

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

    await expect(
      page.getByText("Account deletion has been queued")
    ).toBeVisible({ timeout: 10000 });

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
 * Land the browser authenticated as the minted user and suppress the
 * onboarding overlay. A placement-free user gets the global onboarding modal,
 * whose backdrop intercepts pointer events on every page (including settings);
 * placing a book satisfies the onboarding check so the overlay stays hidden
 * across reloads. (Minted users are placement-free, same as freshly-registered
 * ones, so this handling is unchanged from the register+login version.)
 */
async function landAuthenticated(
  page: Page,
  session: MintedSession
): Promise<void> {
  await injectSession(page, session);
  await ensureBookOnLibrary(page);
}
