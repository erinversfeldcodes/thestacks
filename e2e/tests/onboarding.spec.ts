import { test, expect } from "@playwright/test";
import { mintOrSkip, injectSession, uniqueEmail } from "./helpers";

/**
 * Onboarding overlay (, punch — E2E leg).
 *
 * The overlay only renders for an authenticated user who is BOTH confirmed AND
 * has zero placements (`shouldShowOnboarding`). Every seeded user — including
 * the "auth" suite user — is given placements, so we mint a fresh confirmed,
 * placement-free user at test time via POST /api/test/session and
 * inject its session. Minting is outside the `:auth` rate bucket, so this
 * overlay spec (whose subject is onboarding, NOT registration) no longer draws
 * on the shared budget; a placement-free authenticated user is exactly the
 * overlay precondition. This is the only way to exercise Main.elm's onboarding
 * wiring end-to-end; the opaque Nav.Key blocks unit-testing it.
 */
test.describe("First-run onboarding overlay", () => {
  test("a confirmed user with no placements sees the overlay, steps through it, and can skip", async ({
    page,
    request,
  }) => {
    const session = await mintOrSkip(request, {
      email: uniqueEmail("e2e-onboarding"),
      displayName: "Onboarding Newcomer",
    });
    await injectSession(page, session);

    await page.goto("/antilibrary");

    const overlay = page.getByTestId("onboarding-overlay");
    await expect(overlay).toBeVisible({ timeout: 15000 });
    await expect(overlay).toContainText("Welcome to The Stacks");

    const dots = overlay.locator(".onboarding-overlay__dot");
    await expect(dots).toHaveCount(4);
    await expect(
      overlay.locator(".onboarding-overlay__dot--active")
    ).toHaveCount(1);
    await expect(dots.nth(0)).toHaveClass(/onboarding-overlay__dot--active/);

    // Leaving a step records it (PUT /api/onboarding/step/:step), which is what
    // lets a reader who closes the tab resume where they stopped.
    const recorded = page.waitForResponse(
      (r) =>
        new URL(r.url()).pathname === "/api/onboarding/step/profile" &&
        r.request().method() === "PUT",
      { timeout: 15000 }
    );
    await overlay.getByTestId("onboarding-continue-btn").click();
    expect(
      (await recorded).status(),
      "PUT /api/onboarding/step/profile"
    ).toBe(200);

    await expect(dots.nth(1)).toHaveClass(/onboarding-overlay__dot--active/);
    await expect(dots.nth(0)).not.toHaveClass(
      /onboarding-overlay__dot--active/
    );
    await expect(overlay.getByTestId("onboarding-upload-embed")).toBeVisible();

    await overlay.getByTestId("onboarding-skip-btn").click();
    await expect(page.getByTestId("onboarding-overlay")).toHaveCount(0);
  });

  /**
   * Stepping forward advances an index the overlay holds in memory, and that
   * index reads the same whether or not the step was ever recorded server-side.
   * The reader who comes back is the one who finds out: the overlay reopens
   * (they still have no books) and resumes from the server's `next_step`.
   *
   * Leaving Welcome records "profile", whose next step is "privacy" — the
   * consent step. So the returning reader lands on consent: not on Welcome
   * (nothing was stored) and not on upload (the client index was restored
   * rather than the server's answer).
   */
  test("a step completed before leaving is not offered again on the reader's return", async ({
    page,
    request,
  }) => {
    const session = await mintOrSkip(request, {
      email: uniqueEmail("e2e-onboarding-resume"),
      displayName: "Returning Newcomer",
    });
    await injectSession(page, session);
    await page.goto("/antilibrary");

    const overlay = page.getByTestId("onboarding-overlay");
    await expect(overlay).toBeVisible({ timeout: 15000 });
    await expect(overlay).toContainText("Welcome to The Stacks");

    const recorded = page.waitForResponse(
      (r) =>
        new URL(r.url()).pathname === "/api/onboarding/step/profile" &&
        r.request().method() === "PUT",
      { timeout: 15000 }
    );
    await overlay.getByTestId("onboarding-continue-btn").click();
    expect((await recorded).status()).toBe(200);
    await expect(overlay.getByTestId("onboarding-upload-embed")).toBeVisible();

    await page.reload();

    const reopened = page.getByTestId("onboarding-overlay");
    await expect(reopened).toBeVisible({ timeout: 15000 });
    await expect(
      reopened.getByTestId("onboarding-consent-embed"),
      "the overlay did not resume from the server's next step, so the completed step was never stored"
    ).toBeVisible({ timeout: 15000 });
    await expect(reopened).not.toContainText("Welcome to The Stacks");
  });
});
