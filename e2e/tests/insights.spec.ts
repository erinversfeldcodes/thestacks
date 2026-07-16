import { test, expect } from "@playwright/test";
import type { APIRequestContext } from "@playwright/test";
import {
  E2E_PASSWORD,
  uniqueEmail,
  registerViaApi,
  fetchConfirmationToken,
  signInViaForm,
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
 * The throwaway-user fixture (register → confirm → sign in → place a book)
 * mirrors audit-log.spec.ts: it suppresses the onboarding overlay and gives the
 * derivations real own-data to work from.
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

test.describe("Personal inference view (/me/insights)", () => {
  test("authed own-only: renders the sections and consent-gates the risk illustrations", async ({
    page,
    request,
  }) => {
    const { email, token } = await registerAndConfirm(request, "e2e-insights");
    test.skip(
      token === null,
      "requires the /api/test/confirmation-token helper (STACKS_E2E_TEST_HELPERS=1)"
    );

    await signInViaForm(page, email, E2E_PASSWORD);
    await ensureBookOnLibrary(page);

    await page.goto("/me/insights");
    await expect(page.getByTestId("insights-page")).toBeVisible({
      timeout: 15_000,
    });

    // The three grounded sections render from the user's own data.
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

    // Revealing re-fetches with ?reveal_risk=true and shows the labelled block.
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
