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
 * Browser E2E for the public-profile epic (#210) — the reader-facing half of the
 * visibility model. Drives the REAL preview stack (no mocking) across the
 * viewer perspective the visibility matrix cares about:
 *
 *   US-10.5.2 (view profile)  — /u/:handle renders the reader's identity + only
 *                               the bookshelves the viewer may see.
 *   US-10.5.3 (browse shelf)  — /u/:handle/:name renders the shelf read-only:
 *                               visible spines, NO owner controls.
 *   US-10.5.4 (discover)      — people search surfaces a discoverable reader and
 *                               links to their profile.
 *   Ghost gate                — an unknown/ghost handle is "Reader not found"
 *                               (indistinguishable from absent, by design).
 *
 * WHY throwaway users (not the shared seeded suite users): this test MUTATES
 * profile/bookshelf visibility and handle. It owns two single-purpose fixtures:
 *   - OWNER (B): registered via API, loosened to a discoverable "platform"
 *     profile with a claimed handle, a platform-visible "library" (one placed
 *     book) and an owner-only "wishlist". B never touches the browser — API only.
 *   - VIEWER (A): registered + confirmed, then drives the browser as a second
 *     signed-in reader.
 *
 * Both require the /api/test/confirmation-token helper (STACKS_E2E_TEST_HELPERS=1)
 * and `test.skip` cleanly without it, matching gdpr/onboarding/privacy-block.
 *
 * A brand-new viewer is placement-free, so the GLOBAL onboarding overlay
 * intercepts pointer events everywhere; `ensureBookOnLibrary` places a book to
 * clear it, and we assert the overlay is gone before interacting.
 *
 * `/api/auth/{register,login,confirm}` share the `:auth` rate bucket (60/60s per
 * IP, shared across the parallel suite), so every auth call is wrapped in a
 * bounded 429-backoff and the whole journey is a SINGLE round-trip test to keep
 * `:auth` traffic low.
 */

test.describe("Public profiles — view, browse & discover (live browser journey)", () => {
  test("a discoverable reader's profile shows visible shelves only, browses read-only, and is discoverable by search", async ({
    page,
    request,
  }) => {
    // ── OWNER (B) — API only ──────────────────────────────────────────────
    const ownerName = `E2E Reader ${Math.floor(Math.random() * 1_000_000)}`;
    const owner = await registerAndConfirm(request, "e2e-profile-owner", ownerName);
    test.skip(
      owner.token === null,
      "requires the /api/test/confirmation-token helper (STACKS_E2E_TEST_HELPERS=1)"
    );
    const ownerAuth = await loginViaApi(request, owner.email, E2E_PASSWORD);

    // A fresh user defaults to profile_visibility "owner" (a ghost). Loosen to
    // "platform" so another signed-in reader can discover and view the profile.
    await expectOk(
      request.put("/api/settings/profile_visibility", {
        headers: { Authorization: `Bearer ${ownerAuth}` },
        data: { profile_visibility: "platform" },
      }),
      "loosen profile"
    );

    // Claim a handle (US-10.5.1). The 200 echoes the normalised (lowercased)
    // value, which is exactly what /u/:handle resolves.
    const handle = `e2e_reader_${Math.floor(Math.random() * 1_000_000)}`;
    const setHandle = await expectOk(
      request.put("/api/settings/profile", {
        headers: { Authorization: `Bearer ${ownerAuth}` },
        data: { handle },
      }),
      "set handle"
    );
    const ownerHandle = ((await setHandle.json()).handle as string) ?? handle;

    // A platform-visible "library" with one platform-visible placed book, and
    // an owner-only "wishlist" that must NOT surface to the viewer. Order matters
    // and mirrors the visibility ceiling: a placement may not exceed its
    // bookshelf's visibility, so the bookshelf is loosened to "platform" BEFORE
    // the placement (which itself defaults to "owner"). A platform bookshelf
    // alone would still hide every spine — visibility is enforced per-placement.
    const placementId = await placeFirstCatalogueBook(request, ownerAuth, "library");
    await setBookshelfVisibility(request, ownerAuth, "library", "platform");
    await setPlacementVisibility(request, ownerAuth, placementId, "platform");
    await setBookshelfVisibility(request, ownerAuth, "wishlist", "owner");

    // ── VIEWER (A) — browser ──────────────────────────────────────────────
    const viewer = await registerAndConfirm(request, "e2e-profile-viewer");
    await signInViaForm(page, viewer.email, E2E_PASSWORD);
    await ensureBookOnLibrary(page);

    // ── US-10.5.2 — the profile hub shows identity + visible shelves only ──
    await page.goto(`/u/${ownerHandle}`);
    await expect(page.getByTestId("onboarding-overlay")).not.toBeVisible();
    await expect(page.locator(".profile__name")).toHaveText(ownerName, {
      timeout: 10000,
    });
    await expect(page.locator(".profile__handle")).toHaveText(`@${ownerHandle}`);

    // The platform "library" is browsable; the owner-only "wishlist" is not.
    const shelfLinks = page.locator(".profile__shelf");
    await expect(shelfLinks.filter({ hasText: "Library" })).toHaveCount(1);
    await expect(shelfLinks.filter({ hasText: "Wish List" })).toHaveCount(0);

    // ── US-10.5.3 — browse the shelf read-only ────────────────────────────
    await shelfLinks.filter({ hasText: "Library" }).getByRole("link").click();
    await expect(page).toHaveURL(new RegExp(`/u/${ownerHandle}/library$`));
    await expect(page.getByTestId("bookshelf-page")).toBeVisible({ timeout: 10000 });
    // At least one visible spine renders…
    await expect(page.getByTestId("book-spine").first()).toBeVisible();
    // …and NO owner control leaks into the read-only view (SECURITY).
    await expect(page.getByRole("button", { name: "Add shelf" })).toHaveCount(0);

    // ── Ghost gate — an unknown handle is "Reader not found" ──────────────
    await page.goto(`/u/nobody_${Math.floor(Math.random() * 1_000_000)}`);
    await expect(page.locator(".profile__name")).toHaveText("Reader not found", {
      timeout: 10000,
    });

    // ── US-10.5.4 — people search discovers the reader → profile ──────────
    await page.goto("/search");
    await expect(page.getByTestId("onboarding-overlay")).not.toBeVisible();
    await page.getByTestId("search-input").fill(ownerName);

    const readerCard = page.getByTestId("reader-card");
    await expect(readerCard).toHaveCount(1, { timeout: 10000 });
    await expect(readerCard).toContainText(`@${ownerHandle}`);

    // The card links to the profile — follow it and land on the hub.
    await readerCard.click();
    await expect(page).toHaveURL(new RegExp(`/u/${ownerHandle}$`));
    await expect(page.locator(".profile__name")).toHaveText(ownerName, {
      timeout: 10000,
    });
  });
});

/**
 * Register a throwaway user via the API and confirm its email through the
 * test-helper token. Returns the email and confirmation token (null when the
 * helper endpoint is unavailable, so the caller can `test.skip`). `/register` is
 * under the shared `:auth` bucket, so a transient 429 is absorbed with backoff.
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

/** Log a confirmed user in via the API and return the bearer token. */
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
 * Place the first catalogue book onto the owner's given bookshelf via the API
 * and return the new placement's id, so the caller can loosen its visibility and
 * give the platform-visible shelf a spine to render for the viewer.
 */
async function placeFirstCatalogueBook(
  request: APIRequestContext,
  authToken: string,
  bookshelfName: string
): Promise<string> {
  const cat = await expectOk(request.get("/api/catalogue?per_page=1"), "catalogue");
  const books = (await cat.json()).books ?? [];
  expect(books.length, "catalogue has at least one book to place").toBeGreaterThan(0);

  const placed = await expectOk(
    request.post(`/api/bookshelves/${bookshelfName}/placements`, {
      headers: { Authorization: `Bearer ${authToken}` },
      data: { book_id: books[0].id },
    }),
    `place book on ${bookshelfName}`
  );
  return (await placed.json()).placement.id as string;
}

/** Set a placement's visibility (owner | group | platform) via the API. */
async function setPlacementVisibility(
  request: APIRequestContext,
  authToken: string,
  placementId: string,
  visibility: string
): Promise<void> {
  await expectOk(
    request.put(`/api/placements/${placementId}/visibility`, {
      headers: { Authorization: `Bearer ${authToken}` },
      data: { visibility },
    }),
    `set placement → ${visibility}`
  );
}

/** Set a bookshelf's visibility (owner | group | platform) via the API. */
async function setBookshelfVisibility(
  request: APIRequestContext,
  authToken: string,
  bookshelfName: string,
  visibility: string
): Promise<void> {
  await expectOk(
    request.put(`/api/bookshelves/${bookshelfName}/visibility`, {
      headers: { Authorization: `Bearer ${authToken}` },
      data: { visibility },
    }),
    `set ${bookshelfName} → ${visibility}`
  );
}

/** Await a request, assert it succeeded, and return the response. */
async function expectOk(
  pending: Promise<APIResponse>,
  label: string
): Promise<APIResponse> {
  const resp = await pending;
  expect(resp.ok(), `${label} failed: HTTP ${resp.status()}`).toBeTruthy();
  return resp;
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
