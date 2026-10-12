import { test, expect } from "@playwright/test";
import { suiteAuthFile, apiCallFromPage } from "./helpers";

/**
 * Edits made before the privacy settings have loaded must not be lost.
 *
 * The privacy page seeds its controls with defaults, then overwrites them from
 * `GET /api/settings/privacy` once that answers. On a cold deployed stack that
 * answer can land AFTER a reader's first click — and the overwrite silently
 * discarded the click. Worse, a Save that followed wrote the stale default back
 * to the server with a 200 and a "Saved!", so the reader was told their change
 * took when it had been undone under them. Locally the fetch wins that race by
 * milliseconds, which is why the three settings specs were green here and red
 * on the preview in three consecutive runs.
 *
 * This spec forces the race by delaying the hydration response. The contract
 * under test is that the controls are not interactive until the page knows
 * the stored state — Playwright's actionability wait then naturally holds the
 * click/select until hydration has landed, exactly as a reader's click would
 * be held by a disabled control.
 */
const HYDRATION_DELAY_MS = 1500;

function privacySettingsGet(r: { url(): string; request(): { method(): string } }): boolean {
  return (
    new URL(r.url()).pathname === "/api/settings/privacy" && r.request().method() === "GET"
  );
}

test.describe("Settings — edits made before hydration", () => {
  test.use({ storageState: suiteAuthFile("settings") });

  test.beforeEach(async ({ page }) => {
    await page.route("**/api/settings/privacy", async (route) => {
      if (route.request().method() === "GET") {
        await new Promise((resolve) => setTimeout(resolve, HYDRATION_DELAY_MS));
      }
      await route.continue();
    });
  });

  test("a visibility change made before settings load is the one that gets saved", async ({
    page,
  }) => {
    await page.goto("/settings/privacy");
    // Start from a stored value that differs from the edit, or an overwrite
    // would be invisible.
    const seeded = await apiCallFromPage(page, "PUT", "/api/settings/profile_visibility", {
      profile_visibility: "owner",
    });
    expect(seeded.status, "seeding profile visibility to owner").toBe(200);

    const hydrated = page.waitForResponse(privacySettingsGet, { timeout: 15000 });
    await page.reload();

    const profileSection = page
      .locator(".settings-section")
      .filter({ has: page.getByRole("button", { name: "Save Profile Visibility" }) });
    const profileSelect = profileSection.locator("select");

    // The edit, issued as early as the control allows it.
    await profileSelect.selectOption("platform");
    await hydrated;

    // Hydration has landed: the edit must still be standing.
    await expect(profileSelect).toHaveValue("platform");

    const saved = page.waitForResponse(
      (r) =>
        new URL(r.url()).pathname === "/api/settings/profile_visibility" &&
        r.request().method() === "PUT",
      { timeout: 15000 },
    );
    await profileSection.getByRole("button", { name: "Save Profile Visibility" }).click();
    expect((await saved).status(), "PUT /api/settings/profile_visibility").toBe(200);

    // And what the server now holds is the edit, not the default.
    await page.reload();
    await expect(
      page
        .locator(".settings-section")
        .filter({ has: page.getByRole("button", { name: "Save Profile Visibility" }) })
        .locator("select"),
    ).toHaveValue("platform", { timeout: 10000 });
  });

  test("a consent toggle flipped before settings load stays flipped", async ({ page }) => {
    await page.goto("/settings/privacy");
    const revoked = await apiCallFromPage(page, "POST", "/api/gdpr/consent", {
      consent: false,
      type: "analytics",
    });
    expect(revoked.status, "seeding analytics consent to off").toBe(200);

    const hydrated = page.waitForResponse(privacySettingsGet, { timeout: 15000 });
    await page.reload();

    const toggle = page.getByTestId("analytics-consent-toggle");
    await toggle.click();
    await hydrated;

    await expect(toggle).toHaveText("On");
  });
});
