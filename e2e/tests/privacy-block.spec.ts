import { test, expect } from "@playwright/test";
import type { APIRequestContext, APIResponse } from "@playwright/test";
import {
  E2E_PASSWORD,
  uniqueEmail,
  registerViaApi,
  fetchConfirmationToken,
  signInViaForm,
  ensureBookOnLibrary,
} from "./helpers";

/**
 * Browser E2E for the user-blocking journey — US-10.1.2, Issue #122 punch #14
 * (child issue #199). Drives the REAL preview stack (no mocking): the ⋯
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
 * Both require the /api/test/confirmation-token helper (STACKS_E2E_TEST_HELPERS=1)
 * and `test.skip` cleanly without it, matching gdpr/onboarding/confirm-email.
 *
 * A brand-new user is placement-free, so the GLOBAL onboarding overlay
 * intercepts pointer events everywhere (incl. the ⋯ trigger and settings);
 * `ensureBookOnLibrary` places a book to satisfy the onboarding check, and we
 * assert the overlay is gone before interacting.
 *
 * `/api/auth/{register,login,confirm}` all share the `:auth` rate bucket
 * (60/60s per IP, shared across the parallel suite), so every auth call is
 * wrapped in a bounded 429-backoff retry, and the flow is a SINGLE round-trip
 * test (block → verify hidden → unblock → verify restored) to minimise
 * `:auth` traffic (6 auth calls total rather than 12 across two tests).
 */

test.describe("Privacy — block & unblock (live browser journey)", () => {
  test("blocking a blog author from the ⋯ menu hides their post; unblocking restores it", async ({
    page,
    request,
  }) => {
    // ── AUTHOR (B) — API only ────────────────────────────────────────────
    const authorName = `E2E Author ${Math.floor(Math.random() * 1_000_000)}`;
    const author = await registerAndConfirm(request, "e2e-block-author", authorName);
    test.skip(
      author.token === null,
      "requires the /api/test/confirmation-token helper (STACKS_E2E_TEST_HELPERS=1)"
    );

    const authorAuth = await loginViaApi(request, author.email, E2E_PASSWORD);

    // A fresh user defaults to profile_visibility "owner" (most restrictive),
    // so a "platform" post would be rejected by the visibility ceiling. Loosen
    // the profile first so the post is visible to another signed-in reader.
    const loosen = await request.put("/api/settings/profile_visibility", {
      headers: { Authorization: `Bearer ${authorAuth}` },
      data: { profile_visibility: "platform" },
    });
    expect(loosen.ok(), `loosen profile failed: HTTP ${loosen.status()}`).toBeTruthy();

    const postTitle = `Marginalia ${Math.floor(Math.random() * 1_000_000)}`;
    const postId = await createPublishedPost(request, authorAuth, postTitle);

    // ── BLOCKER (A) — browser ────────────────────────────────────────────
    const blocker = await registerAndConfirm(request, "e2e-block-blocker");
    // (helper presence already asserted above; A shares the same helper flag.)

    await signInViaForm(page, blocker.email, E2E_PASSWORD);
    await ensureBookOnLibrary(page);

    // A can see B's post before blocking.
    await page.goto(`/blog/${postId}`);
    await expect(page.getByTestId("onboarding-overlay")).not.toBeVisible();
    await expect(page.locator(".blog-post__title")).toHaveText(postTitle, {
      timeout: 10000,
    });

    // ── Block from the ⋯ overflow menu ───────────────────────────────────
    // The ⋯ trigger carries aria-label "Reader actions" (#202 polish); target
    // it by role so the test tracks the accessible affordance.
    await page.getByRole("button", { name: "Reader actions" }).click();

    // Menu action names the author: "Block <name>". Exact match so it can't
    // collide with the modal's bare "Block" confirm button.
    await page
      .getByRole("button", { name: `Block ${authorName}`, exact: true })
      .click();

    // Confirmation modal appears and NAMES the author (#203).
    const modal = page.getByTestId("block-user-modal");
    await expect(modal).toBeVisible();
    await expect(modal).toContainText(`Block ${authorName}?`);

    // Confirm the block (modal's danger button, text "Block").
    await modal.getByRole("button", { name: "Block", exact: true }).click();

    // On success the host re-fetches the post, which now resolves to :hidden
    // (bidirectional block → 404) → the "no longer available" dead-end.
    await expect(page.getByText("This post is no longer available.")).toBeVisible({
      timeout: 10000,
    });
    await expect(page.locator(".blog-post__title")).toHaveCount(0);

    // ── Unblock from Settings → Privacy → Blocked Users ──────────────────
    await page.goto("/settings/privacy");
    await expect(page.getByTestId("onboarding-overlay")).not.toBeVisible();

    const blockedSection = page.getByTestId("blocked-users-section");
    await expect(blockedSection).toBeVisible({ timeout: 10000 });

    // The blocked-users list names B.
    const blockedRow = blockedSection.locator(".blocked-user", {
      hasText: authorName,
    });
    await expect(blockedRow).toBeVisible();

    await blockedRow.getByRole("button", { name: "Unblock" }).click();

    // The row is removed from the list on a successful unblock.
    await expect(blockedRow).toHaveCount(0, { timeout: 10000 });

    // ── B's content reappears for A ──────────────────────────────────────
    await page.goto(`/blog/${postId}`);
    await expect(page.locator(".blog-post__title")).toHaveText(postTitle, {
      timeout: 10000,
    });
    await expect(page.getByText("This post is no longer available.")).toHaveCount(0);
  });
});

/**
 * Register a throwaway user via the API and confirm its email through the
 * test-helper token. Returns the email and the confirmation token (null when
 * the helper endpoint is unavailable, so the caller can `test.skip`).
 *
 * `/api/auth/register` is under the `:auth` bucket (60/60s per IP), shared
 * across the whole parallel suite, so a transient 429 burst is absorbed with a
 * bounded backoff-retry rather than failing the test outright.
 */
async function registerAndConfirm(
  request: APIRequestContext,
  prefix: string,
  displayName?: string
): Promise<{ email: string; token: string | null }> {
  const email = uniqueEmail(prefix);

  const reg = await withAuthBackoff(() =>
    registerViaApi(request, { email, password: E2E_PASSWORD, displayName })
  );
  expect(reg.ok(), `register failed with HTTP ${reg.status()}`).toBeTruthy();

  const token = await fetchConfirmationToken(request, email);
  if (token === null) return { email, token: null };

  const confirm = await withAuthBackoff(() =>
    request.get(`/api/auth/confirm/${token}`)
  );
  expect(confirm.ok()).toBeTruthy();
  return { email, token };
}

/**
 * Log a confirmed user in via the API and return the bearer token. Also under
 * the `:auth` bucket, so it shares the same bounded 429-backoff.
 */
async function loginViaApi(
  request: APIRequestContext,
  email: string,
  password: string
): Promise<string> {
  const resp = await withAuthBackoff(() =>
    request.post("/api/auth/login", { data: { email, password } })
  );
  expect(resp.ok(), `login failed with HTTP ${resp.status()}`).toBeTruthy();
  const body = await resp.json();
  return body.token as string;
}

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

/**
 * Run an `:auth`-bucket request with a bounded 429 backoff. The bucket is
 * 60/60s per IP shared across the parallel suite, so a burst can transiently
 * 429; retry up to 4 times with a linear backoff before giving up.
 */
async function withAuthBackoff(
  fn: () => Promise<APIResponse>
): Promise<APIResponse> {
  let resp = await fn();
  for (let attempt = 1; attempt <= 4 && !resp.ok() && resp.status() === 429; attempt++) {
    await new Promise((resolve) => setTimeout(resolve, 2000 * attempt));
    resp = await fn();
  }
  return resp;
}
