import { test, expect } from "@playwright/test";
import type { Browser, Page } from "@playwright/test";
import { suiteAuthFile, apiCallFromPage } from "./helpers";

/**
 * Browser + API E2E for per-shelf Atom RSS feeds (US-6.1, Issue #119 §1/§3).
 *
 * Covers the two halves of the feature that landed on feat/119-e2e:
 *   - #263: the RSS affordance is driven from the shelf's REAL visibility
 *     (previously hardcoded "platform"), so the icon appears only for a
 *     platform-visible bookshelf and is hidden otherwise.
 *   - #264: the feed is served from op.feed_cache with event-driven regen; the
 *     public FeedController returns Atom 1.0 with ETag / 304 / Cache-Control.
 *
 * These drive REAL API responses — no page.route() mocking (project E2E rule).
 * The RSS affordance only renders on the unified Bookshelf page (library /
 * antilibrary / wishlist) for the OWNER viewing their own shelf, and only when
 * the shelf's visibility is "platform". We flip visibility through the real
 * PUT /api/bookshelves/:name/visibility endpoint and reset to "owner" after.
 *
 * Serial mode: every test mutates the SAME suite user's shelf visibility, so
 * running them in parallel would race on shared state. Each test also sets the
 * exact visibility it needs up front, so it is self-contained regardless of
 * order, and afterAll restores all three shelves to the "owner" default.
 */

test.use({ storageState: suiteAuthFile("bookshelf") });
test.describe.configure({ mode: "serial" });

/**
 * Raise/lower the suite user's PROFILE visibility.
 *
 * The `bookshelf` suite user is seeded with `profile_visibility = "owner"`,
 * which is a HARD ceiling (#195, `validate_bookshelf_profile_ceiling/3`): a
 * shelf may not be more visible than the profile, so an "owner" profile forces
 * every shelf to "owner" and a `PUT …/visibility -> platform` is rejected 422
 * ("less restrictive than the profile visibility ceiling"). These specs flip
 * shelves to "platform", so we raise the profile ceiling to "platform" for the
 * duration of the file and restore it to "owner" afterwards — the spec owns its
 * own precondition and needs no seed change (works local/CI/preview).
 */
async function setProfileVisibility(
  browser: Browser,
  visibility: string,
): Promise<void> {
  const context = await browser.newContext({
    storageState: suiteAuthFile("bookshelf"),
  });
  try {
    const page = await context.newPage();
    await page.goto("/library");
    const res = await apiCallFromPage(
      page,
      "PUT",
      "/api/settings/profile_visibility",
      { profile_visibility: visibility },
    );
    expect(
      res.status,
      `PUT /api/settings/profile_visibility -> ${visibility} (got ${res.status})`,
    ).toBe(200);
  } finally {
    await context.close();
  }
}

// Raise the profile ceiling before any test flips a shelf to "platform", and
// restore it after the whole file — afterAll always runs, including on failure,
// so the shared suite user is left as seeded ("owner") for other suites.
// bookshelf.spec.ts is the only other spec on this suite user and never asserts
// on profile/shelf visibility, so the brief raise cannot interfere with it.
test.beforeAll(async ({ browser }) => {
  await setProfileVisibility(browser, "platform");
});

test.afterAll(async ({ browser }) => {
  await setProfileVisibility(browser, "owner");
});

async function setVisibility(
  page: Page,
  shelf: string,
  visibility: string,
): Promise<void> {
  const res = await apiCallFromPage(
    page,
    "PUT",
    `/api/bookshelves/${shelf}/visibility`,
    { visibility },
  );
  expect(
    res.status,
    `PUT /api/bookshelves/${shelf}/visibility -> ${visibility} (got ${res.status})`,
  ).toBe(200);
}

async function currentUserId(page: Page): Promise<string> {
  const userId = await page.evaluate(() => {
    const auth = JSON.parse(localStorage.getItem("stacks-auth") || "{}");
    return auth.userId as string;
  });
  expect(userId, "suite user has a userId in localStorage").toBeTruthy();
  return userId;
}

test.describe("RSS affordance on a bookshelf (US-6.1 §1)", () => {
  test.afterAll(async ({ browser }) => {
    // Reset shelves this suite user touched back to the "owner" default so we
    // do not leave a platform-visible shelf that could surprise other specs.
    const context = await browser.newContext({
      storageState: suiteAuthFile("bookshelf"),
    });
    const page = await context.newPage();
    await page.goto("/library");
    for (const shelf of ["library", "wishlist", "antilibrary"]) {
      await apiCallFromPage(
        page,
        "PUT",
        `/api/bookshelves/${shelf}/visibility`,
        {
          visibility: "owner",
        },
      );
    }
    await context.close();
  });

  test("RSS button renders when the bookshelf is platform-visible, and the popover shows the feed URL + help text", async ({
    page,
  }) => {
    await page.goto("/wishlist");
    // Establish the exact state this test needs, then reload so the page picks
    // up the server's real visibility (init defaults to "owner" until loaded).
    await setVisibility(page, "wishlist", "platform");
    const userId = await currentUserId(page);

    await page.goto("/wishlist");
    await page.waitForSelector(".shelf-wishlist", { timeout: 10000 });

    // #263: the RSS affordance is now gated on the shelf's real visibility.
    const rssButton = page.locator(".rss-link__button");
    await expect(rssButton).toBeVisible({ timeout: 10000 });

    // Popover is hidden until the button is clicked (ToggleUrl).
    await expect(page.locator(".rss-link__popover")).toHaveCount(0);

    await rssButton.click();

    const popover = page.locator(".rss-link__popover");
    await expect(popover).toBeVisible();
    await expect(popover.locator(".rss-link__help")).toContainText(
      "Subscribe in your RSS reader:",
    );
    // The feed URL input carries the exact public feed path for this shelf.
    await expect(popover.locator(".rss-link__url")).toHaveValue(
      `/api/feeds/${userId}/wishlist`,
    );
  });

  test("RSS button is hidden when the bookshelf is not platform-visible", async ({
    page,
  }) => {
    await page.goto("/antilibrary");
    await setVisibility(page, "antilibrary", "owner");

    await page.goto("/antilibrary");
    await page.waitForSelector(".shelf-antilibrary", { timeout: 10000 });

    // The owner is on their own shelf (so the RSS control WOULD render if the
    // shelf were platform-visible), but visibility is "owner" -> RSSLink.view
    // returns `text ""`, so no button exists.
    await expect(page.locator(".rss-link__button")).toHaveCount(0);
  });
});

test.describe("Feed API — GET /api/feeds/:user_id/:bookshelf_name (US-6.1 §3)", () => {
  test.afterAll(async ({ browser }) => {
    const context = await browser.newContext({
      storageState: suiteAuthFile("bookshelf"),
    });
    const page = await context.newPage();
    await page.goto("/library");
    await apiCallFromPage(page, "PUT", "/api/bookshelves/library/visibility", {
      visibility: "owner",
    });
    await context.close();
  });

  test("200 application/atom+xml with valid Atom, ETag and Cache-Control for a platform shelf; 304 on matching If-None-Match", async ({
    page,
    request,
  }) => {
    await page.goto("/library");
    await setVisibility(page, "library", "platform");
    const userId = await currentUserId(page);
    const feedUrl = `/api/feeds/${userId}/library`;

    // The feed endpoint is PUBLIC — no auth header required.
    const resp = await request.get(feedUrl);
    expect(resp.status()).toBe(200);
    expect(resp.headers()["content-type"]).toContain("application/atom+xml");

    // Cache-Control: public, max-age=300 (Issue #119 §9 — previously unasserted).
    expect(resp.headers()["cache-control"]).toBe("public, max-age=300");

    // ETag present.
    const etag = resp.headers()["etag"];
    expect(etag, "feed response carries an ETag").toBeTruthy();

    // Valid Atom 1.0: XML prolog + feed element in the Atom namespace.
    const body = await resp.text();
    expect(body).toContain("<?xml");
    expect(body).toContain('<feed xmlns="http://www.w3.org/2005/Atom"');
    expect(body).toContain("<id>urn:stacks:feed:");

    // 304 Not Modified when the client echoes the ETag back.
    const notModified = await request.get(feedUrl, {
      headers: { "If-None-Match": etag },
    });
    expect(notModified.status()).toBe(304);
  });

  test("404 for a non-existent user/bookshelf", async ({ request }) => {
    // A well-formed but non-existent user id -> get_bookshelf returns nil -> 404.
    const resp = await request.get(
      "/api/feeds/00000000-0000-0000-0000-000000000000/library",
    );
    expect(resp.status()).toBe(404);
  });

  test("403 for a non-platform-visible bookshelf", async ({
    page,
    request,
  }) => {
    await page.goto("/wishlist");
    await setVisibility(page, "wishlist", "owner");
    const userId = await currentUserId(page);

    const resp = await request.get(`/api/feeds/${userId}/wishlist`);
    expect(resp.status()).toBe(403);
  });
});
