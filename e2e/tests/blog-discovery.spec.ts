import { test, expect } from "@playwright/test";
import { mintSession, injectSession } from "./helpers";

/**
 * The blog as something a reader can FIND.
 *
 * `/api/blog/posts` used to answer a bare request with 422 "user_id is
 * required", so the archive page — which asks exactly that — could only ever
 * render its error state, and the only way to read anything was to already know
 * whose post you wanted. These tests drive the two ways in: the public archive
 * for a stranger, and the entry point on a signed-in reader's home.
 *
 * Each test publishes its own post through the app's own API rather than
 * relying on a seed, so it means the same thing on a fresh database.
 */

const POST_BODY =
  "The light there is wrong for reading and right for everything else.";

/** Publish a public post by a public-profile author, the way the app does it. */
async function publishPublicPost(
  request: import("@playwright/test").APIRequestContext,
  title: string,
) {
  const session = await mintSession(request, { displayName: "Ada Reader" });
  test.skip(session === null, "test-session helper is not enabled here");
  const auth = { Authorization: `Bearer ${session!.token}` };

  // A post may not be more visible than its author's profile, so the ceiling
  // has to be raised before a public post is even accepted.
  const vis = await request.put("/api/settings/profile_visibility", {
    headers: auth,
    data: { profile_visibility: "public" },
  });
  expect(vis.ok()).toBeTruthy();

  const created = await request.post("/api/blog/posts", {
    headers: auth,
    data: { title, body: POST_BODY, visibility: "public" },
  });
  expect(created.status()).toBe(201);
  const { post } = await created.json();

  const published = await request.post(`/api/blog/posts/${post.id}/publish`, {
    headers: auth,
  });
  expect(published.ok()).toBeTruthy();

  return { session: session!, post };
}

test.describe("Blog discovery — signed out", () => {
  test.use({ storageState: { cookies: [], origins: [] } });

  test("the archive lists a published public post with its author and preview", async ({
    page,
    request,
  }) => {
    const title = `A shelf by the window ${Date.now()}`;
    await publishPublicPost(request, title);

    await page.goto("/blog");

    const item = page.locator(".blog-archive__item", { hasText: title });
    await expect(item).toBeVisible({ timeout: 15000 });

    // The byline and the preview are the two things a cross-author list needs
    // and the two the summary payload did not carry.
    await expect(item.locator(".blog-archive__item-author")).toHaveText(
      "Ada Reader",
    );
    await expect(item.locator(".blog-archive__item-preview")).toContainText(
      "The light there is wrong for reading",
    );
    await expect(page.getByText("Could not load posts")).toHaveCount(0);
  });
});

test.describe("Blog discovery — signed in", () => {
  test.use({ storageState: { cookies: [], origins: [] } });

  test("the home offers a way into the blog", async ({ page, request }) => {
    const session = await mintSession(request, { displayName: "Reader" });
    test.skip(session === null, "test-session helper is not enabled here");
    await injectSession(page, session!);

    await page.goto("/");

    // A minted reader has no placements, so the onboarding overlay opens over
    // the home and its backdrop swallows every click. Dismiss it via its own
    // Skip button — the home underneath is what this test is about.
    const overlay = page.getByTestId("onboarding-overlay");
    const appeared = await overlay
      .waitFor({ state: "visible", timeout: 3000 })
      .then(() => true)
      .catch(() => false);
    if (appeared) {
      await overlay.getByTestId("onboarding-skip-btn").click();
      await expect(overlay).not.toBeVisible();
    }

    const link = page.getByTestId("home-blog");
    await expect(link).toBeVisible({ timeout: 15000 });

    await link.click();
    await expect(page).toHaveURL(/\/blog$/);
    await expect(page.getByRole("heading", { name: "Blog" })).toBeVisible();
  });
});
