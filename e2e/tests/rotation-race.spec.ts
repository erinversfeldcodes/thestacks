import { test, expect } from "@playwright/test";

const DEV_EMAIL = "owner@thestacks.app";
const DEV_PASSWORD = "dev-password-123";

/**
 * Issue #180 Phase 2 — cross-tab token-rotation race.
 *
 * Two tabs (pages) in ONE browser context share the same localStorage, so a
 * `stacks-auth` write in one tab fires a `storage` event in the other. This
 * suite exercises the SAME code path a real rotation race hits:
 *
 *   - tab A rotates its token (writes a new `stacks-auth`) → tab B must ADOPT it
 *     and stay signed in (no spurious redirect to /login);
 *   - tab A logs out (clears `stacks-auth`) → tab B must log out too.
 *
 * SIMULATION CAVEAT: a fully-real refresh race is non-deterministic to drive
 * (both tabs' 7h renewal timers, server-side rotation grace). We instead drive
 * the exact wiring under test by writing localStorage from tab A and dispatching
 * the `storage` event in tab B (what the browser does natively across tabs).
 * The EXACT-token in-memory adoption is asserted precisely by the pure
 * `adoptExternalAuth` unit tests (frontend/tests/RotationRaceTest.elm); a
 * fabricated token is not server-valid, so in-memory adoption cannot be proven
 * via an authed request here — we assert the observable outcome (no spurious
 * logout on rotation; propagated logout on clear).
 */
test.describe("Cross-tab token rotation race (Issue #180 Phase 2)", () => {
  async function signIn(page: import("@playwright/test").Page) {
    await page.goto("/login");
    await page.fill('input[id="email"]', DEV_EMAIL);
    await page.fill('input[id="password"]', DEV_PASSWORD);
    await page.getByTestId("login-submit").click();
    await page.waitForURL("**/antilibrary", { timeout: 15000 });
  }

  test("a sibling tab's token rotation does NOT log the other tab out", async ({
    browser,
  }) => {
    const context = await browser.newContext();
    const pageA = await context.newPage();
    await signIn(pageA);

    // Tab B joins the same context and is authed from the shared localStorage.
    const pageB = await context.newPage();
    await pageB.goto("/antilibrary");
    await expect(pageB.getByTestId("user-menu")).toBeVisible();

    // Tab A rotates its token: rewrite stacks-auth with a fresh token value.
    const rotated = await pageA.evaluate(() => {
      const raw = localStorage.getItem("stacks-auth");
      const parsed = JSON.parse(raw as string);
      parsed.token = "rotated-token-" + Date.now();
      const next = JSON.stringify(parsed);
      localStorage.setItem("stacks-auth", next);
      return next;
    });

    // Deliver that write to tab B as the browser would (same-origin storage event).
    await pageB.evaluate((newValue) => {
      window.dispatchEvent(
        new StorageEvent("storage", { key: "stacks-auth", newValue })
      );
    }, rotated);

    // Tab B adopts the rotated token and stays signed in — NOT redirected.
    await expect(pageB.getByTestId("user-menu")).toBeVisible();
    await expect(pageB).not.toHaveURL(/\/login$/);
    await expect(pageB.locator('input[id="email"]')).not.toBeVisible();

    await context.close();
  });

  test("a sibling tab's logout (clearAuth) logs the other tab out", async ({
    browser,
  }) => {
    const context = await browser.newContext();
    const pageA = await context.newPage();
    await signIn(pageA);

    const pageB = await context.newPage();
    await pageB.goto("/antilibrary");
    await expect(pageB.getByTestId("user-menu")).toBeVisible();

    // Tab A logs out: clearAuth removes stacks-auth (storage event newValue=null).
    await pageA.evaluate(() => localStorage.removeItem("stacks-auth"));
    await pageB.evaluate(() => {
      window.dispatchEvent(
        new StorageEvent("storage", { key: "stacks-auth", newValue: null })
      );
    });

    // Tab B follows the sibling logout → redirected to the login form.
    await expect(pageB.locator('input[id="email"]')).toBeVisible({
      timeout: 10000,
    });

    await context.close();
  });
});
