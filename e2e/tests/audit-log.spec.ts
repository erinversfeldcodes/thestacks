import { test, expect } from "@playwright/test";
import type { APIRequestContext } from "@playwright/test";
import {
  E2E_PASSWORD,
  suiteAuthFile,
  uniqueEmail,
  registerViaApi,
  fetchConfirmationToken,
  signInViaForm,
  ensureBookOnLibrary,
} from "./helpers";

/**
 * Browser E2E for the read-only GDPR audit-log surface (US-8.5, page #189):
 *   /settings/audit-log  →  GET /api/settings/audit-log
 *
 * Previously covered only at the controller/program-test layer. This drives the
 * real Elm page against a running backend and, critically, proves the audit UI
 * NEVER surfaces the hashed IP address the table stores server-side
 * (audit_log_controller.render_entry deliberately omits ip_address).
 *
 * Flake-lessons carried over from gdpr.spec.ts:
 *   - the "renders entries" case owns a THROWAWAY user (single-owner fixture) and
 *     places a book, which both suppresses the onboarding overlay AND writes a
 *     deterministic `placement.created` audit entry to assert against;
 *   - registration is on the shared `:auth` rate bucket, so a transient 429 is
 *     absorbed with a bounded backoff-retry;
 *   - the helper endpoint is gated behind STACKS_E2E_TEST_HELPERS=1, so the
 *     throwaway case test.skips cleanly when it is unavailable.
 */

test.describe("Settings — Audit Log (live entries)", () => {
  test("renders the user's own entries (action/resource/when) and never an IP column", async ({
    page,
    request,
  }) => {
    const { email, token } = await registerAndConfirm(request, "e2e-auditlog");
    test.skip(
      token === null,
      "requires the /api/test/confirmation-token helper (STACKS_E2E_TEST_HELPERS=1)"
    );

    // Sign in and place a book: suppresses the onboarding overlay (a placement-
    // free user gets a global modal whose backdrop eats clicks everywhere) and
    // writes a `placement.created` audit entry (Shelving.place_book → Audit.log).
    await signInViaForm(page, email, E2E_PASSWORD);
    await ensureBookOnLibrary(page);

    await page.goto("/settings/audit-log");
    await page.getByTestId("settings-hub").waitFor({ timeout: 5000 });
    await expect(page.locator(".page__title").last()).toContainText("Audit Log");

    // The table renders with the placement.created entry we just generated.
    const rows = page.locator(".audit-log__row");
    await expect(rows.first()).toBeVisible({ timeout: 10000 });
    await expect(page.locator(".audit-log__table")).toContainText(
      "placement.created"
    );

    // Every row exposes action / resource / when — and a non-empty timestamp.
    await expect(rows.first().locator(".audit-log__action")).not.toBeEmpty();
    await expect(rows.first().locator(".audit-log__resource")).not.toBeEmpty();
    await expect(
      rows.first().locator(".audit-log__timestamp")
    ).not.toBeEmpty();

    // Load-bearing GDPR assertion: the audit table exposes EXACTLY three columns
    // (Action, Resource, When). The hashed IP the backend stores must never
    // reach the client, so there is no IP/address column header, ever.
    const headers = await page.getByRole("columnheader").allTextContents();
    expect(headers).toEqual(["Action", "Resource", "When"]);
    expect(headers.join(" ")).not.toMatch(/ip|address/i);
    await expect(page.locator("table")).not.toContainText(/ip address/i);
  });
});

/**
 * Empty- and error-state branches of AuditLog.elm.
 *
 * These are driven with a fulfilled response rather than real data on purpose:
 *   - EMPTY is not reachable against a real user — `/api/auth/register` itself
 *     writes a `user.registered` audit entry (auth_controller), so every live
 *     account already has ≥1 row;
 *   - ERROR (a 5xx) cannot be provoked on demand from a healthy backend.
 * This mirrors the route-fulfillment already used in settings.spec.ts for the
 * consent-save failure branch. The seeded `settings` user supplies a real,
 * authed session so AuditLog.init actually fires the request we intercept.
 */
test.describe("Settings — Audit Log (empty & error states)", () => {
  test.use({ storageState: suiteAuthFile("settings") });

  test("empty state renders when the user has no audit entries", async ({
    page,
  }) => {
    await page.route("**/api/settings/audit-log**", (route) =>
      route.fulfill({
        status: 200,
        contentType: "application/json",
        body: JSON.stringify({
          entries: [],
          total: 0,
          page: 1,
          per_page: 25,
        }),
      })
    );

    await page.goto("/settings/audit-log");
    await page.getByTestId("settings-hub").waitFor({ timeout: 5000 });

    // AuditLog.elm:94-96 empty branch.
    await expect(page.locator(".audit-log__empty")).toContainText(
      "No audit entries yet."
    );
    await expect(page.locator(".audit-log__table")).toHaveCount(0);
  });

  test("error state renders when the audit-log request fails", async ({
    page,
  }) => {
    // A 500 (not 401) drives the Failure branch; a 401 would instead redirect to
    // /login via the SessionExpired out-message.
    await page.route("**/api/settings/audit-log**", (route) =>
      route.fulfill({
        status: 500,
        contentType: "application/json",
        body: "{}",
      })
    );

    await page.goto("/settings/audit-log");
    await page.getByTestId("settings-hub").waitFor({ timeout: 5000 });

    // AuditLog.elm:90-91 failure branch.
    await expect(page.locator(".error")).toContainText(
      "Failed to load your audit log. Please try again."
    );
    await expect(page.locator(".audit-log__table")).toHaveCount(0);
  });
});

/**
 * Register a throwaway user via the API and confirm its email through the
 * test-helper token. Returns the email and confirmation token (null when the
 * helper endpoint is unavailable, so the caller can test.skip). `/api/auth/register`
 * is on the shared `:auth` rate bucket (60/60s per IP), so a transient 429 burst
 * is absorbed with a bounded backoff-retry. Mirrors gdpr.spec.ts.
 */
async function registerAndConfirm(
  request: APIRequestContext,
  prefix: string
): Promise<{ email: string; token: string | null }> {
  const email = uniqueEmail(prefix);

  let reg = await registerViaApi(request, { email, password: E2E_PASSWORD });
  for (
    let attempt = 1;
    attempt <= 4 && !reg.ok() && reg.status() === 429;
    attempt++
  ) {
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
