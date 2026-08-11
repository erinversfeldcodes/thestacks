import { test, expect } from "@playwright/test";
import {
  suiteAuthFile,
  uniqueEmail,
  mintOrSkip,
  injectSession,
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
 *   - the user is minted via POST /api/test/session (Issue #280) rather than the
 *     register→confirm→login dance, so this non-auth-testing spec no longer draws
 *     on the shared `:auth` rate bucket;
 *   - the helper endpoint is gated behind STACKS_E2E_TEST_HELPERS=1, so the
 *     throwaway case test.skips cleanly when it is unavailable.
 */

test.describe("Settings — Audit Log (live entries)", () => {
  test("renders the user's own entries (action/resource/when) and never an IP column", async ({
    page,
    request,
  }) => {
    const session = await mintOrSkip(request, {
      email: uniqueEmail("e2e-auditlog"),
    });

    await injectSession(page, session);
    await ensureBookOnLibrary(page);

    await page.goto("/settings/audit-log");
    await page.getByTestId("settings-hub").waitFor({ timeout: 5000 });
    await expect(page.locator(".page__title").last()).toContainText("Audit Log");

    const rows = page.locator(".audit-log__row");
    await expect(rows.first()).toBeVisible({ timeout: 10000 });
    await expect(page.locator(".audit-log__table")).toContainText(
      "placement.created"
    );

    await expect(rows.first().locator(".audit-log__action")).not.toBeEmpty();
    await expect(rows.first().locator(".audit-log__resource")).not.toBeEmpty();
    await expect(
      rows.first().locator(".audit-log__timestamp")
    ).not.toBeEmpty();

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

    await expect(page.locator(".audit-log__empty")).toContainText(
      "No audit entries yet."
    );
    await expect(page.locator(".audit-log__table")).toHaveCount(0);
  });

  test("error state renders when the audit-log request fails", async ({
    page,
  }) => {
    await page.route("**/api/settings/audit-log**", (route) =>
      route.fulfill({
        status: 500,
        contentType: "application/json",
        body: "{}",
      })
    );

    await page.goto("/settings/audit-log");
    await page.getByTestId("settings-hub").waitFor({ timeout: 5000 });

    await expect(page.locator(".error")).toContainText(
      "Failed to load your audit log. Please try again."
    );
    await expect(page.locator(".audit-log__table")).toHaveCount(0);
  });
});
