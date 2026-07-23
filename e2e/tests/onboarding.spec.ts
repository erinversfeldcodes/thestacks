import { test, expect } from "@playwright/test";
import { mintOrSkip, injectSession, uniqueEmail } from "./helpers";

/**
 * Onboarding overlay (Issue #124, punch #10 — E2E leg).
 *
 * The overlay only renders for an authenticated user who is BOTH confirmed AND
 * has zero placements (`shouldShowOnboarding`). Every seeded user — including
 * the "auth" suite user — is given placements, so we mint a fresh confirmed,
 * placement-free user at test time via POST /api/test/session (Issue #280) and
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
    // 1. Mint a fresh, confirmed, placement-free user and inject its session.
    const session = await mintOrSkip(request, {
      email: uniqueEmail("e2e-onboarding"),
      displayName: "Onboarding Newcomer",
    });
    await injectSession(page, session);

    // 2. Boot the SPA authenticated — with no placements, the onboarding overlay
    //    must appear (same landing the post-login redirect used).
    await page.goto("/antilibrary");

    const overlay = page.getByTestId("onboarding-overlay");
    await expect(overlay).toBeVisible({ timeout: 15000 });
    await expect(overlay).toContainText("Welcome to The Stacks");

    // Progress dots: three steps (profile → privacy → complete; the age step
    // was removed in ADR-020), first one active.
    const dots = overlay.locator(".onboarding-overlay__dot");
    await expect(dots).toHaveCount(3);
    await expect(
      overlay.locator(".onboarding-overlay__dot--active")
    ).toHaveCount(1);
    await expect(dots.nth(0)).toHaveClass(/onboarding-overlay__dot--active/);

    // Advancing moves the active dot forward and swaps the step content.
    await overlay.getByTestId("onboarding-continue-btn").click();
    await expect(dots.nth(1)).toHaveClass(/onboarding-overlay__dot--active/);
    await expect(dots.nth(0)).not.toHaveClass(
      /onboarding-overlay__dot--active/
    );

    // The Skip link dismisses the overlay entirely.
    await overlay.getByRole("button", { name: "Skip" }).click();
    await expect(page.getByTestId("onboarding-overlay")).toHaveCount(0);
  });
});
