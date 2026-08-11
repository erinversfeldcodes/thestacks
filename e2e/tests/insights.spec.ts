import { test, expect } from "@playwright/test";
import {
  uniqueEmail,
  mintOrSkip,
  injectSession,
  ensureBookOnLibrary,
} from "./helpers";

/**
 * Browser E2E for the authed, own-only personal-inference view
 * (Issue #242, ADR-019 §3a):
 *   /me/insights  →  GET /api/me/inferences
 *
 * Drives the real Elm page against a running backend. The load-bearing
 * behaviours proved live:
 *   - a signed-in user sees their OWN interest / behaviour / de-anonymisation
 *     sections (computed ephemerally from their own shelf — nothing persisted);
 *   - the sensitive "what a third party could infer" section is CONSENT-GATED:
 *     hidden until an explicit reveal action, which re-fetches with
 *     ?reveal_risk=true;
 *   - the route is auth-guarded (unauthenticated → login page).
 *
 * The throwaway-user fixture mints an isolated, confirmed user via
 * POST /api/test/session (Issue #280) and injects the session — outside the
 * `:auth` rate bucket, so this non-auth-testing spec no longer competes with the
 * parallel suite for the shared 60/60s budget. Injecting a placement-free user
 * still triggers the onboarding overlay, so a book is placed to suppress it and
 * give the derivations real own-data. Skips cleanly where the helper is off.
 */

test.describe("Personal inference view (/me/insights)", () => {
  test("authed own-only: renders the sections and consent-gates the risk illustrations", async ({
    page,
    request,
  }) => {
    const session = await mintOrSkip(request, {
      email: uniqueEmail("e2e-insights"),
    });

    await injectSession(page, session);
    await ensureBookOnLibrary(page);

    await page.goto("/me/insights");
    await expect(page.getByTestId("insights-page")).toBeVisible({
      timeout: 15_000,
    });

    await expect(page.getByTestId("insights-interest")).toBeVisible();
    await expect(page.getByTestId("insights-behaviour")).toBeVisible();
    await expect(page.getByTestId("insights-deanon")).toBeVisible();
    await expect(
      page.getByTestId("insights-deanon-explanation")
    ).not.toBeEmpty();

    // Consent gate: the sensitive illustrations are hidden until the explicit
    // reveal action; the gate button is shown, the revealed block is not.
    await expect(page.getByTestId("insights-risk-revealed")).toHaveCount(0);
    const reveal = page.getByTestId("insights-reveal-risk");
    await expect(reveal).toBeVisible();

    await reveal.click();
    await expect(page.getByTestId("insights-risk-revealed")).toBeVisible({
      timeout: 10_000,
    });
  });
});

/**
 * The view is auth-required (Main.elm requiresAuth `_ -> True`); initPage
 * returns the Login page with no session. Mirrors the /settings auth guards.
 */
test.describe("Personal inference view — auth guard", () => {
  test.use({ storageState: { cookies: [], origins: [] } });

  test("unauthenticated visit to /me/insights renders the login page", async ({
    page,
  }) => {
    await page.goto("/me/insights");

    await expect(page.getByTestId("login-submit")).toBeVisible({
      timeout: 10_000,
    });
    await expect(page.getByTestId("insights-page")).toHaveCount(0);
  });
});
