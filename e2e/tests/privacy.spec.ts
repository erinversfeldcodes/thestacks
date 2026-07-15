import { test, expect } from "@playwright/test";
import { suiteAuthFile } from "./helpers";

/**
 * Browser E2E for the CORE privacy/visibility flows (Issue #198, child of the
 * #122 epic). Covers punch-list items #13, #15, #17, #18, #19:
 *   - #13 Profile visibility save + auth guard        (US-10.1.1)
 *   - #15 Per-shelf visibility save                   (US-10.2.1)
 *   - #17 Blog editor visibility dropdown → draft/publish (US-10.2.3)
 *   - #18 ViewAs preview banner + Exit preview         (US-10.3.1)
 *   - #19 Search-engine privacy (robots.txt + noindex meta) (US-10.4.1)
 *
 * Block/unblock (#14) and the hidden-placement spine / greyed ceiling options
 * (#16) are OUT of scope for #198 (separate children of #122).
 *
 * All server-side enforcement (ceiling 422s, cross-user leakage, ViewAs Phase-2
 * authorization, robots.txt server response) is already covered at the Elixir
 * controller/plug/property layers per the #122 audit. This spec adds the missing
 * BROWSER-level coverage: that the shipped Elm UI actually drives those flows.
 *
 * ── User strategy ───────────────────────────────────────────────────────────
 * Non-destructive authed flows use the SEEDED `settings` suite user
 * (`suiteAuthFile("settings")`): it already HAS placements, so the global
 * onboarding overlay (whose backdrop intercepts clicks everywhere) never
 * appears, and it adds zero load to the shared `:auth` rate bucket (60/60s per
 * IP). No throwaway registrations are minted here — every flow below is either
 * idempotent (profile→"Discoverable", shelf→"Only me") or a benign per-user
 * write (a blog draft), none of which disturbs the shelf/placement state other
 * settings tests rely on.
 *
 * NOTE (live-drive deferred): this spec cannot be executed here — there is no
 * running preview. It is validated only for parse + discovery
 * (`npx playwright test privacy.spec.ts --list`). Live execution happens at the
 * #122 epic's finalization preview gate, which should confirm the selectors
 * flagged in the accompanying report.
 */

test.describe("Privacy — Profile & Shelf visibility (US-10.1.1 / US-10.2.1)", () => {
  test.use({ storageState: suiteAuthFile("settings") });

  // Punch #13 — profile visibility save.
  test("profile visibility: select Discoverable → Save → 'Saved!' confirmation", async ({
    page,
  }) => {
    await page.goto("/settings/privacy");

    // Scope to the Profile Visibility section (the one holding the profile save
    // button) so the profile <select> can't be confused with a shelf-row select.
    const profileSection = page
      .locator(".settings-section")
      .filter({ has: page.getByRole("button", { name: "Save Profile Visibility" }) });

    const profileSelect = profileSection.locator("select");
    await expect(profileSelect).toBeVisible({ timeout: 10000 });

    // "Discoverable" == platform. Loosening to platform is idempotent and does
    // NOT trigger the recap job to cap this user's shelves (recap only tightens
    // toward "owner"), so the seeded user's shelf state is left untouched.
    await profileSelect.selectOption("platform");

    await profileSection
      .getByRole("button", { name: "Save Profile Visibility" })
      .click();

    // On success viewSaveButton swaps the label to "Saved!" (Privacy.elm:472-474)…
    await expect(
      page.getByRole("button", { name: "Saved!" })
    ).toBeVisible({ timeout: 10000 });
    // …and the shared viewFeedback renders this exact copy (Privacy.elm:484-485).
    await expect(page.getByText("Visibility updated.")).toBeVisible();
    await expect(page.locator(".error")).toHaveCount(0);
  });

  // Punch #15 — per-shelf visibility save.
  //
  // The shelf row Save button fires PUT /api/bookshelves/:name/visibility. The
  // Shelf Visibility section renders `viewFeedback model.savingShelf` (built in
  // #196), so a success shows "Visibility updated." — asserted below alongside
  // the accepted PUT (200). "Only me" (owner) is the most-restrictive value and
  // is always within any profile ceiling, so this is 200 regardless of the
  // seeded user's profile visibility.
  test("shelf visibility: select 'Only me' → Save issues an accepted PUT", async ({
    page,
  }) => {
    await page.goto("/settings/privacy");

    const firstShelfRow = page.locator(".privacy__shelf-row").first();
    await expect(firstShelfRow).toBeVisible({ timeout: 10000 });

    // Capture the original value so we can restore it — this shelf is shared with
    // the parallel privacy-placement spec; leaving it at "owner" would disable
    // that spec's placement options.
    const original = await firstShelfRow.locator("select").inputValue();

    await firstShelfRow.locator("select").selectOption("owner");

    const [resp] = await Promise.all([
      page.waitForResponse(
        (r) =>
          /\/api\/bookshelves\/[^/]+\/visibility$/.test(r.url()) &&
          r.request().method() === "PUT"
      ),
      firstShelfRow.getByRole("button", { name: "Save" }).click(),
    ]);

    expect(resp.status()).toBe(200);
    await expect(page.locator(".error")).toHaveCount(0);
    // Shelf save shows the same feedback as profile save (Privacy.elm viewFeedback
    // model.savingShelf → "Visibility updated." on success — built in #196).
    await expect(page.getByText("Visibility updated.")).toBeVisible();

    // Restore the shared shelf to its original visibility. Await the restore PUT
    // so it completes before teardown — no residue on the shared seeded user.
    await firstShelfRow.locator("select").selectOption(original);
    await Promise.all([
      page.waitForResponse(
        (r) =>
          /\/api\/bookshelves\/[^/]+\/visibility$/.test(r.url()) &&
          r.request().method() === "PUT"
      ),
      firstShelfRow.getByRole("button", { name: "Save" }).click(),
    ]);
  });
});

/**
 * Punch #17 — Blog editor visibility dropdown → Save Draft / Publish (US-10.2.3).
 *
 * Uses the seeded `settings` user (authed, placement-backed → no onboarding
 * overlay on /blog/new). Any authenticated user may author posts. Visibility is
 * left at "Only me" (owner): owner is always within the profile ceiling, so the
 * create/update/publish calls succeed no matter the user's profile visibility —
 * keeping this test independent of the profile-visibility test's ordering under
 * `fullyParallel`.
 */
test.describe("Privacy — Blog editor visibility (US-10.2.3)", () => {
  test.use({ storageState: suiteAuthFile("settings") });

  test("blog editor: set visibility → Save Draft → 'Draft saved!' → Publish → 'Published!'", async ({
    page,
  }) => {
    await page.goto("/blog/new");

    const title = page.getByPlaceholder("Post title");
    await expect(title).toBeVisible({ timeout: 10000 });
    await title.fill(`E2E privacy draft ${Date.now()}`);
    await page
      .getByPlaceholder("Write your post here...")
      .fill("Body written by the #198 privacy E2E spec.");

    // The lone <select> in the editor form is the visibility dropdown
    // (Editor.elm:287-295). "owner" == "Only me".
    await page.locator(".blog-editor__form select").selectOption("owner");

    // Save Draft → viewSaveButton swaps to "Draft saved!" (Editor.elm:311-313).
    await page.getByRole("button", { name: "Save Draft" }).click();
    await expect(
      page.getByRole("button", { name: "Draft saved!" })
    ).toBeVisible({ timeout: 10000 });

    // Publish → viewPublishButton swaps to "Published!" (Editor.elm:327-329).
    await page.getByRole("button", { name: "Publish" }).click();
    await expect(
      page.getByRole("button", { name: "Published!" })
    ).toBeVisible({ timeout: 10000 });

    await expect(page.locator(".error")).toHaveCount(0);
  });
});

/**
 * Punch #18 — ViewAs preview banner + Exit preview (US-10.3.1).
 *
 * `Components.ViewAsBar` renders unconditionally from the browser URL
 * (Main.elm:2231) for ANY authenticated user — the banner is pure client-side.
 * Backend ViewAs authorization (owner / resource-owner only, Phase 2) is a
 * separate, plug-level concern already covered by view_as_plug_test.exs; it does
 * not gate this banner, and /settings/privacy is a plain SPA-shell route
 * (PageController catch-all, no ViewAsPlug), so no view_as-gated API call fires.
 * We therefore drive the banner with the rate-friendly seeded `settings` user.
 */
test.describe("Privacy — ViewAs preview (US-10.3.1)", () => {
  test.use({ storageState: suiteAuthFile("settings") });

  test("view_as banner appears and 'Exit preview' strips the param", async ({
    page,
  }) => {
    await page.goto("/settings/privacy?view_as=unauthenticated");

    const banner = page.locator(".view-as-bar");
    await expect(banner).toBeVisible({ timeout: 10000 });
    // ViewAsBar humanizes the perspective: `unauthenticated` → "Not logged in"
    // (perspectiveLabel, ViewAsBar.elm:30-34 — built in #196). Exact copy per #122 §1.
    await expect(banner).toContainText("Viewing as: Not logged in");

    const exit = banner.getByText("Exit preview");
    await expect(exit).toBeVisible();

    // removeViewAs (ViewAsBar.elm:55-91) rebuilds the URL without view_as; the
    // link href is the bare path, so the banner disappears after navigation.
    await exit.click();
    await expect(banner).not.toBeVisible();
    expect(page.url()).not.toContain("view_as");
  });
});

/**
 * Punch #19 — Search-engine privacy (US-10.4.1).
 *
 * Server-side robots.txt content is covered by robots_test.exs; this adds the
 * browser-level guarantees: the crawler directives are actually served, and the
 * SPA shell carries the noindex meta.
 */
test.describe("Privacy — Search engine privacy (US-10.4.1)", () => {
  test("robots.txt disallows user-content paths", async ({ request }) => {
    const resp = await request.get("/robots.txt");
    expect(resp.ok()).toBeTruthy();
    const body = await resp.text();
    for (const p of ["/api/", "/u/", "/shelf/", "/post/", "/listing/"]) {
      expect(body, `robots.txt should disallow ${p}`).toContain(`Disallow: ${p}`);
    }
  });

  test("SPA shell carries the noindex, nofollow robots meta", async ({ page }) => {
    await page.goto("/");
    // priv/static/index.html (source: apps/core/assets/index.html:6) — the shell
    // served for every SPA route.
    await expect(page.locator('meta[name="robots"]')).toHaveAttribute(
      "content",
      "noindex, nofollow"
    );
  });

});

/**
 * The search-privacy informational line lives on the AUTHED settings page
 * (Privacy.elm `settings-section__note` — built in #196), so it needs the seeded user.
 */
test.describe("Privacy — search-privacy info text (US-10.4.1)", () => {
  test.use({ storageState: suiteAuthFile("settings") });

  test("settings page shows the 'never appear in search engine results' info text", async ({
    page,
  }) => {
    await page.goto("/settings/privacy");
    await expect(
      page.getByText(
        "Your profile and content will never appear in search engine results."
      )
    ).toBeVisible({ timeout: 10000 });
  });
});

/**
 * Punch #13 (auth guard) — the privacy settings page requires authentication.
 *
 * SettingsPrivacy is an auth-required route (Main.elm requiresAuth `_ -> True`);
 * initPage returns the Login page when there is no session (Main.elm:410-411).
 */
test.describe("Privacy — auth guard", () => {
  test.use({ storageState: { cookies: [], origins: [] } });

  test("unauthenticated visit to /settings/privacy renders the login page", async ({
    page,
  }) => {
    await page.goto("/settings/privacy");

    // The login form's submit control proves the Login page was rendered.
    await expect(page.getByTestId("login-submit")).toBeVisible({ timeout: 10000 });
    // And the privacy form must NOT be reachable while unauthenticated.
    await expect(
      page.getByRole("button", { name: "Save Profile Visibility" })
    ).toHaveCount(0);
  });
});
