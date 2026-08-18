import { test, expect } from "@playwright/test";
import { suiteAuthFile, apiCallFromPage } from "./helpers";

/**
 * Browser E2E for the CORE privacy/visibility flows (, child of the
 * epic). Covers punch-list items,,,,
 *   - Profile visibility save + auth guard
 *   - Per-shelf visibility save
 *   - Blog editor visibility dropdown → draft/publish
 *   - ViewAs preview banner + Exit preview
 *   - Search-engine privacy (robots.txt + noindex meta)
 *
 * Block/unblock and the hidden-placement spine / greyed ceiling options
 * are OUT of scope for (separate children of).
 *
 * All server-side enforcement (ceiling 422s, cross-user leakage, ViewAs Phase-2
 * authorization, robots.txt server response) is already covered at the Elixir
 * controller/plug/property layers per the audit. This spec adds the missing
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
 * epic's finalization preview gate, which should confirm the selectors
 * flagged in the accompanying report.
 */

test.describe("Privacy — Profile & Shelf visibility", () => {
  test.use({ storageState: suiteAuthFile("settings") });

  test("profile visibility: select Discoverable → Save → 'Saved!' confirmation", async ({
    page,
  }) => {
    await page.goto("/settings/privacy");

    const profileSection = page
      .locator(".settings-section")
      .filter({ has: page.getByRole("button", { name: "Save Profile Visibility" }) });

    const profileSelect = profileSection.locator("select");
    await expect(profileSelect).toBeVisible({ timeout: 10000 });

    await profileSelect.selectOption("platform");

    const saved = page.waitForResponse(
      (r) =>
        new URL(r.url()).pathname === "/api/settings/profile_visibility" &&
        r.request().method() === "PUT",
      { timeout: 15000 }
    );
    await profileSection
      .getByRole("button", { name: "Save Profile Visibility" })
      .click();
    expect(
      (await saved).status(),
      "PUT /api/settings/profile_visibility"
    ).toBe(200);

    await expect(
      page.getByRole("button", { name: "Saved!" })
    ).toBeVisible({ timeout: 10000 });
    await expect(page.getByText("Visibility updated.")).toBeVisible();
    await expect(page.locator(".error")).toHaveCount(0);

    // "Saved!" is the button's own state. The select is seeded from the stored
    // visibility on load, so only a reload reports what was stored.
    await page.reload();
    const reloadedSection = page
      .locator(".settings-section")
      .filter({
        has: page.getByRole("button", { name: "Save Profile Visibility" }),
      });
    await expect(reloadedSection.locator("select")).toHaveValue("platform", {
      timeout: 10000,
    });
  });

  test("shelf visibility: select 'Only me' → Save issues an accepted PUT", async ({
    page,
  }) => {
    await page.goto("/settings/privacy");

    const firstShelfRow = page.locator(".privacy__shelf-row").first();
    await expect(firstShelfRow).toBeVisible({ timeout: 10000 });

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
    await expect(page.getByText("Visibility updated.")).toBeVisible();

    // An accepted PUT and a stored value are different claims — the row is
    // rebuilt from the server's shelf list on load, so reload and read it back
    // before restoring the original.
    await page.reload();
    const reloadedRow = page.locator(".privacy__shelf-row").first();
    await expect(reloadedRow.locator("select")).toHaveValue("owner", {
      timeout: 10000,
    });

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
 * Punch — Blog editor visibility dropdown → Save Draft / Publish.
 *
 * Uses the seeded `settings` user (authed, placement-backed → no onboarding
 * overlay on /blog/new). Any authenticated user may author posts. Visibility is
 * left at "Only me" (owner): owner is always within the profile ceiling, so the
 * create/update/publish calls succeed no matter the user's profile visibility —
 * keeping this test independent of the profile-visibility test's ordering under
 * `fullyParallel`.
 */
test.describe("Privacy — Blog editor visibility", () => {
  test.use({ storageState: suiteAuthFile("settings") });

  test("blog editor: set visibility → Save Draft → 'Draft saved!' → Publish → 'Published!'", async ({
    page,
  }) => {
    await page.goto("/blog/new");

    const postTitle = `E2E privacy draft ${Date.now()}`;
    const title = page.getByPlaceholder("Post title");
    await expect(title).toBeVisible({ timeout: 10000 });
    await title.fill(postTitle);
    await page
      .getByPlaceholder("Write your post here...")
      .fill("Body written by the privacy E2E spec.");

    await page.locator(".blog-editor__form select").selectOption("owner");

    const created = page.waitForResponse(
      (r) =>
        new URL(r.url()).pathname === "/api/blog/posts" &&
        r.request().method() === "POST",
      { timeout: 15000 }
    );
    await page.getByRole("button", { name: "Save Draft" }).click();
    const createResp = await created;
    expect(createResp.status(), "POST /api/blog/posts").toBe(201);
    const postId = (await createResp.json()).post.id as string;
    await expect(
      page.getByRole("button", { name: "Draft saved!" })
    ).toBeVisible({ timeout: 10000 });

    const published = page.waitForResponse(
      (r) =>
        new URL(r.url()).pathname === `/api/blog/posts/${postId}/publish` &&
        r.request().method() === "POST",
      { timeout: 15000 }
    );
    await page.getByRole("button", { name: "Publish" }).click();
    expect(
      (await published).status(),
      `POST /api/blog/posts/${postId}/publish`
    ).toBe(200);
    await expect(
      page.getByRole("button", { name: "Published!" })
    ).toBeVisible({ timeout: 10000 });

    await expect(page.locator(".error")).toHaveCount(0);

    // "Published!" is a button label. Publication is `published_at` being set on
    // the stored post, which only a fresh read can report.
    const stored = await apiCallFromPage(page, "GET", `/api/blog/posts/${postId}`);
    expect(stored.status, `GET /api/blog/posts/${postId}`).toBe(200);
    const storedPost = (stored.data as { post: { title: string; published_at: string } })
      .post;
    expect(storedPost.title).toBe(postTitle);
    expect(storedPost.published_at, "the stored post carries a publish time")
      .toBeTruthy();

    await page.goto(`/blog/${postId}`);
    await expect(page.locator(".blog-post__title")).toHaveText(postTitle, {
      timeout: 10000,
    });
  });
});

/**
 * Punch — ViewAs preview banner + Exit preview.
 *
 * `Components.ViewAsBar` renders unconditionally from the browser URL
 * (Main.elm:2231) for ANY authenticated user — the banner is pure client-side.
 * Backend ViewAs authorization (owner / resource-owner only, Phase 2) is a
 * separate, plug-level concern already covered by view_as_plug_test.exs; it does
 * not gate this banner, and /settings/privacy is a plain SPA-shell route
 * (PageController catch-all, no ViewAsPlug), so no view_as-gated API call fires.
 * We therefore drive the banner with the rate-friendly seeded `settings` user.
 */
test.describe("Privacy — ViewAs preview", () => {
  test.use({ storageState: suiteAuthFile("settings") });

  test("view_as banner appears and 'Exit preview' strips the param", async ({
    page,
  }) => {
    await page.goto("/settings/privacy?view_as=unauthenticated");

    const banner = page.locator(".view-as-bar");
    await expect(banner).toBeVisible({ timeout: 10000 });
    await expect(banner).toContainText("Viewing as: Not logged in");

    const exit = banner.getByText("Exit preview");
    await expect(exit).toBeVisible();

    await exit.click();
    await expect(banner).not.toBeVisible();
    expect(page.url()).not.toContain("view_as");
  });
});

/**
 * Punch — Search-engine privacy.
 *
 * Server-side robots.txt content is covered by robots_test.exs; this adds the
 * browser-level guarantees: the crawler directives are actually served, and the
 * SPA shell carries the noindex meta.
 */
test.describe("Privacy — Search engine privacy", () => {
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
    await expect(page.locator('meta[name="robots"]')).toHaveAttribute(
      "content",
      "noindex, nofollow"
    );
  });

});

/**
 * The search-privacy informational line lives on the AUTHED settings page
 * (Privacy.elm `settings-section__note` — built in), so it needs the seeded user.
 */
test.describe("Privacy — search-privacy info text", () => {
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
 * Punch (auth guard) — the privacy settings page requires authentication.
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

    await expect(page.getByTestId("login-submit")).toBeVisible({ timeout: 10000 });
    await expect(
      page.getByRole("button", { name: "Save Profile Visibility" })
    ).toHaveCount(0);
  });
});
