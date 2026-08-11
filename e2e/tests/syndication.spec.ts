import { test, expect } from "@playwright/test";
import { mintSession, injectSession, uniqueEmail, type MintedSession } from "./helpers";
import type { Page } from "@playwright/test";

/**
 * POSSE syndication (US-6.2.1, wave 11c): a public post's syndication panel,
 * the canonical-tagged export, the anonymous-only blog feed, and the loop
 * closing via "Also published at".
 *
 * The feed's security property — a valid token changes NOTHING — is asserted
 * at the API level here because that is where the property lives; the panel
 * journey is driven in the browser.
 *
 * NOTE: a minted user's profile_visibility must allow public posts (the
 * ceiling rule): posts cannot be MORE exposed than the profile. The spec
 * raises the profile to public first via the settings API.
 */

async function landOn(page: Page, session: MintedSession, pathName: string): Promise<void> {
  await injectSession(page, session);
  await page.goto(pathName);
  const overlay = page.getByTestId("onboarding-overlay");
  const appeared = await overlay
    .waitFor({ state: "visible", timeout: 3000 })
    .then(() => true)
    .catch(() => false);
  if (appeared) {
    await overlay.getByTestId("onboarding-skip-btn").click();
    await expect(overlay).not.toBeVisible();
  }
}

async function publishPublicPost(
  request: import("@playwright/test").APIRequestContext,
  token: string,
  title: string,
): Promise<string> {
  const auth = { Authorization: `Bearer ${token}` };

  const vis = await request.put("/api/settings/profile_visibility", {
    headers: auth,
    data: { profile_visibility: "public" },
  });
  expect(vis.ok(), `profile visibility: HTTP ${vis.status()}`).toBeTruthy();

  const created = await request.post("/api/blog/posts", {
    headers: auth,
    data: { title, body: "A margin note, made public.", visibility: "public" },
  });
  expect(created.status(), "create post").toBe(201);
  const postId = (await created.json()).post.id as string;

  const published = await request.post(`/api/blog/posts/${postId}/publish`, { headers: auth });
  expect(published.ok(), "publish post").toBeTruthy();
  return postId;
}

test.describe("Syndication (POSSE)", () => {
  test("the panel appears on the author's public post with canonical, exports and feed URL", async ({
    page,
    request,
  }) => {
    const session = await mintSession(request, { email: uniqueEmail("posse-panel") });
    test.skip(session === null, "session-mint helper unavailable");
    if (!session) return;

    const postId = await publishPublicPost(request, session.token, "The Annotated Shelf");

    await landOn(page, session, `/blog/${postId}`);

    const panel = page.getByTestId("syndication-panel");
    await expect(panel).toBeVisible();

    await expect(page.getByTestId("syndication-canonical-url")).toContainText(`/blog/${postId}`);
    await expect(page.getByTestId("syndication-feed-url")).toContainText("/api/feeds/u/");
    await expect(page.getByTestId("syndication-export-markdown")).toBeVisible();

    const toggle = page.getByTestId("syndication-include-toggle");
    await expect(toggle).toBeChecked();

    await toggle.click();
    await expect(toggle).not.toBeChecked();

    const me = await request.get("/api/auth/me", {
      headers: { Authorization: `Bearer ${session.token}` },
    });
    const handle = (await me.json()).user.handle as string;
    await expect
      .poll(async () => (await (await request.get(`/api/feeds/u/${handle}/blog`)).text()), {
        timeout: 10_000,
      })
      .not.toContain("The Annotated Shelf");
  });

  test("copying the markdown export records a syndication; pasting the URL back closes the loop", async ({
    page,
    request,
    context,
  }) => {
    const session = await mintSession(request, { email: uniqueEmail("posse-loop") });
    test.skip(session === null, "session-mint helper unavailable");
    if (!session) return;

    await context.grantPermissions(["clipboard-read", "clipboard-write"]);
    const postId = await publishPublicPost(request, session.token, "On Marginalia");

    await landOn(page, session, `/blog/${postId}`);
    await page.getByTestId("syndication-export-markdown").click();

    await expect(page.getByTestId("syndication-panel")).toContainText(
      "Copied — paste it into Substack",
    );
    const clipboard = await page.evaluate(() => navigator.clipboard.readText());
    expect(clipboard).toContain("Originally published on [The Stacks]");
    expect(clipboard).toContain(`/blog/${postId}`);

    const input = page.getByTestId("syndication-also-at-input");
    await expect(input).toBeVisible();
    await input.fill("https://erin.substack.com/p/on-marginalia");
    await input.press("Enter");

    await expect(page.getByTestId("syndication-backlink")).toHaveText(
      "https://erin.substack.com/p/on-marginalia",
    );
  });

  test("a non-public post replaces the panel with the honest sentence — affordances absent", async ({
    page,
    request,
  }) => {
    const session = await mintSession(request, { email: uniqueEmail("posse-private") });
    test.skip(session === null, "session-mint helper unavailable");
    if (!session) return;

    const auth = { Authorization: `Bearer ${session.token}` };
    const created = await request.post("/api/blog/posts", {
      headers: auth,
      data: { title: "Private thoughts", body: "Not for the feed.", visibility: "owner" },
    });
    const postId = (await created.json()).post.id as string;

    await landOn(page, session, `/blog/${postId}`);

    await expect(page.getByTestId("syndication-unavailable")).toBeVisible();
    await expect(page.getByTestId("syndication-export-markdown")).toHaveCount(0);
  });

  test("the blog feed serves the public post as Atom — and a valid token changes nothing", async ({
    request,
  }) => {
    const session = await mintSession(request, { email: uniqueEmail("posse-feed") });
    test.skip(session === null, "session-mint helper unavailable");
    if (!session) return;

    await publishPublicPost(request, session.token, "For the feed");

    const auth = { Authorization: `Bearer ${session.token}` };
    const platformPost = await request.post("/api/blog/posts", {
      headers: auth,
      data: { title: "Platform readers only", body: "…", visibility: "platform" },
    });
    const platformId = (await platformPost.json()).post.id as string;
    await request.post(`/api/blog/posts/${platformId}/publish`, { headers: auth });

    const me = await request.get("/api/auth/me", { headers: auth });
    const handle = (await me.json()).user.handle as string;

    const anon = await request.get(`/api/feeds/u/${handle}/blog`);
    expect(anon.status()).toBe(200);
    expect(anon.headers()["content-type"]).toContain("application/atom+xml");
    const anonBody = await anon.text();
    expect(anonBody).toContain("For the feed");
    expect(anonBody).not.toContain("Platform readers only");

    const authed = await request.get(`/api/feeds/u/${handle}/blog`, { headers: auth });
    const authedBody = await authed.text();
    expect(authedBody).toContain("For the feed");
    expect(authedBody).not.toContain("Platform readers only");
  });
});
