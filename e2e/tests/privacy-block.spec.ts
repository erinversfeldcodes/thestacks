import { test, expect } from "@playwright/test";
import type { APIRequestContext } from "@playwright/test";
import {
  uniqueEmail,
  mintOrSkip,
  injectSession,
  ensureBookOnLibrary,
} from "./helpers";

/**
 * Browser E2E for the user-blocking journey —, punch
 * (child issue). Drives the REAL preview stack (no mocking): the ⋯
 * overflow → confirmation-modal → block flow on a blog post, and the reverse
 * unblock from Settings → Privacy → Blocked Users.
 *
 * WHY throwaway users (not the shared seeded suite users): this test MUTATES
 * bidirectional block state (op.user_blocks) and the author's profile/blog
 * visibility. Running it against a seeded user would leave cross-suite residue
 * and race the parallel suite. So it owns two single-purpose fixtures:
 *   - AUTHOR (B): registered via API, loosens profile to "platform", then
 *     authors a published platform-visible blog post (visible to any signed-in
 *     reader). B never touches the browser — API only.
 *   - BLOCKER (A): registered via API + confirmed, then drives the browser.
 *
 * Both users are minted via POST /api/test/session — one call that
 * creates a confirmed user AND returns its session token, outside the `:auth`
 * rate bucket. This replaces the register→confirm→login dance (and its
 * 429-backoff), so this non-auth-testing spec no longer competes with the
 * parallel suite for the shared 60/60s `:auth` budget. `test.skip` cleanly when
 * the helper is unavailable, matching gdpr/reading-journey.
 *
 * A brand-new user is placement-free, so the GLOBAL onboarding overlay
 * intercepts pointer events everywhere (incl. the ⋯ trigger and settings);
 * `ensureBookOnLibrary` places a book to satisfy the onboarding check, and we
 * assert the overlay is gone before interacting.
 */

test.describe("Privacy — block & unblock (live browser journey)", () => {
  test("blocking a blog author from the ⋯ menu hides their post; unblocking restores it", async ({
    page,
    request,
  }) => {
    const authorName = `E2E Author ${Math.floor(Math.random() * 1_000_000)}`;
    const author = await mintOrSkip(request, {
      email: uniqueEmail("e2e-block-author"),
      displayName: authorName,
    });
    const authorAuth = author.token;

    const loosen = await request.put("/api/settings/profile_visibility", {
      headers: { Authorization: `Bearer ${authorAuth}` },
      data: { profile_visibility: "platform" },
    });
    expect(loosen.ok(), `loosen profile failed: HTTP ${loosen.status()}`).toBeTruthy();

    const postTitle = `Marginalia ${Math.floor(Math.random() * 1_000_000)}`;
    const postId = await createPublishedPost(request, authorAuth, postTitle);

    const blocker = await mintOrSkip(request, {
      email: uniqueEmail("e2e-block-blocker"),
    });

    await injectSession(page, blocker);
    await ensureBookOnLibrary(page);

    await page.goto(`/blog/${postId}`);
    await expect(page.getByTestId("onboarding-overlay")).not.toBeVisible();
    await expect(page.locator(".blog-post__title")).toHaveText(postTitle, {
      timeout: 10000,
    });

    await page.getByRole("button", { name: "Reader actions" }).click();

    await page
      .getByRole("button", { name: `Block ${authorName}`, exact: true })
      .click();

    const modal = page.getByTestId("block-user-modal");
    await expect(modal).toBeVisible();
    await expect(modal).toContainText(`Block ${authorName}?`);

    await modal.getByRole("button", { name: "Block", exact: true }).click();

    await expect(page.getByText("This post is no longer available.")).toBeVisible({
      timeout: 10000,
    });
    await expect(page.locator(".blog-post__title")).toHaveCount(0);

    await page.goto("/settings/privacy");
    await expect(page.getByTestId("onboarding-overlay")).not.toBeVisible();

    const blockedSection = page.getByTestId("blocked-users-section");
    await expect(blockedSection).toBeVisible({ timeout: 10000 });

    const blockedRow = blockedSection.locator(".blocked-user", {
      hasText: authorName,
    });
    await expect(blockedRow).toBeVisible();

    await blockedRow.getByRole("button", { name: "Unblock" }).click();

    await expect(blockedRow).toHaveCount(0, { timeout: 10000 });

    await page.goto(`/blog/${postId}`);
    await expect(page.locator(".blog-post__title")).toHaveText(postTitle, {
      timeout: 10000,
    });
    await expect(page.getByText("This post is no longer available.")).toHaveCount(0);
  });
});

/**
 * Create a published, platform-visible blog post authored by the token holder
 * and return its id. Requires the author's profile to already be "platform"
 * (else the visibility ceiling rejects a platform post).
 */
async function createPublishedPost(
  request: APIRequestContext,
  authToken: string,
  title: string
): Promise<string> {
  const create = await request.post("/api/blog/posts", {
    headers: { Authorization: `Bearer ${authToken}` },
    data: {
      title,
      body: "A quiet note in the margins, visible to the platform.",
      visibility: "platform",
    },
  });
  expect(create.ok(), `create post failed: HTTP ${create.status()}`).toBeTruthy();
  const created = await create.json();
  const postId = created.post.id as string;

  const publish = await request.post(`/api/blog/posts/${postId}/publish`, {
    headers: { Authorization: `Bearer ${authToken}` },
  });
  expect(publish.ok(), `publish failed: HTTP ${publish.status()}`).toBeTruthy();

  return postId;
}
