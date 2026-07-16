import { test, expect } from "@playwright/test";
import {
  fetchConfirmationToken,
  registerViaApi,
  signInViaForm,
  uniqueEmail,
} from "./helpers";

/**
 * Onboarding overlay (Issue #124, punch #10 — E2E leg).
 *
 * The overlay only renders for an authenticated user who is BOTH confirmed
 * (so they can log in) AND has zero placements (`shouldShowOnboarding`). Every
 * seeded user — including the "auth" suite user — is given placements, so we
 * mint a fresh confirmed user with an empty library at test time:
 *
 *   register (unconfirmed) → confirm via test-helper token → sign in.
 *
 * This is the only way to exercise Main.elm's onboarding wiring end-to-end;
 * the opaque Nav.Key blocks unit-testing it.
 */
test.describe("First-run onboarding overlay", () => {
  test("a confirmed user with no placements sees the overlay, steps through it, and can skip", async ({
    page,
    request,
  }) => {
    // 1. Mint a fresh, placement-free user.
    const email = uniqueEmail("e2e-onboarding");
    const password = "a-strong-password";
    const reg = await registerViaApi(request, {
      email,
      password,
      displayName: "Onboarding Newcomer",
    });
    expect(reg.ok()).toBeTruthy();

    // 2. Confirm the email via the test-helper token so the user can log in.
    const token = await fetchConfirmationToken(request, email);
    test.skip(
      token === null,
      "requires the /api/test/confirmation-token helper (STACKS_E2E_TEST_HELPERS=1)"
    );
    const confirm = await request.get(`/api/auth/confirm/${token}`);
    expect(confirm.ok()).toBeTruthy();

    // 3. Sign in — with no placements, the onboarding overlay must appear.
    await signInViaForm(page, email, password);

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
