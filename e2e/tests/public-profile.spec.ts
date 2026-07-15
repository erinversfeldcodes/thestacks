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

// Deterministic seed ISBNs (see apps/core/priv/repo/seeds.exs). Pinning the
// visible spine + the age-gated row to KNOWN books removes the old reliance on
// "whatever per_page=1 returns first".
const VISIBLE_ISBN = "9780061120084"; // "The Left Hand of Darkness" — public
const AGE_GATED_ISBN = "9780140449242"; // "Demons" — age_gated

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

    // Resolve deterministic catalogue book ids by ISBN so the visible spine and
    // the age-gate row are PINNED to known seed books. The catalogue includes
    // age-gated books for an authenticated browser, so the owner token is used.
    const [visibleBookId, ageGatedBookId] = await resolveCatalogueIds(
      request,
      ownerAuth,
      [VISIBLE_ISBN, AGE_GATED_ISBN]
    );

    // A platform-visible "library" with one platform-visible, NON-age-gated
    // placed book (the deterministic visible spine). Order matters and mirrors
    // the visibility ceiling: a placement may not exceed its bookshelf's
    // visibility, so the bookshelf is loosened to "platform" BEFORE the placement
    // (which itself defaults to "owner"). A platform bookshelf alone would still
    // hide every spine — visibility is enforced per-placement.
    const placementId = await placeBook(request, ownerAuth, "library", visibleBookId);
    await setBookshelfVisibility(request, ownerAuth, "library", "platform");
    await setPlacementVisibility(request, ownerAuth, placementId, "platform");

    // A platform-visible "antilibrary" holding ONLY the age-gated "Demons", so
    // the shelf's viewer-visible `count` is a clean age-gate signal: 0 when the
    // gated spine is suppressed, 1 once the viewer is age-verified.
    const gatedPlacementId = await placeBook(request, ownerAuth, "antilibrary", ageGatedBookId);
    await setBookshelfVisibility(request, ownerAuth, "antilibrary", "platform");
    await setPlacementVisibility(request, ownerAuth, gatedPlacementId, "platform");

    // An owner-only "wishlist" that must NOT surface to the viewer.
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

    // ── Age gate — the age-gated spine is suppressed unless the viewer is verified ──
    // The "antilibrary" holds exactly one platform-visible but AGE-GATED
    // placement, so the profile-shelf endpoint's viewer-visible `count` is a
    // clean age-gate signal — a suppressed spine reads as a shelf with no gap
    // (count 0), never a leak that a gated book exists.
    const gatedShelfPath = `/api/u/${ownerHandle}/bookshelves/antilibrary`;

    // Anonymous viewer — never age-verified → the gated spine is suppressed.
    const anonGated = await expectOk(request.get(gatedShelfPath), "anon gated shelf");
    expect((await anonGated.json()).count, "anon must not see the age-gated spine").toBe(0);

    // The signed-in viewer is a fresh reader (age_verified defaults false), so the
    // gated spine is still suppressed. Reuse the browser session's own token
    // (no extra :auth login) for the viewer-scoped reads.
    const viewerAuth = (
      await page.evaluate(() =>
        JSON.parse(localStorage.getItem("stacks-auth") || "{}")
      )
    ).token as string;
    const unverifiedGated = await expectOk(
      request.get(gatedShelfPath, {
        headers: { Authorization: `Bearer ${viewerAuth}` },
      }),
      "unverified gated shelf"
    );
    expect(
      (await unverifiedGated.json()).count,
      "unverified viewer must not see the age-gated spine"
    ).toBe(0);

    // Once the viewer verifies their age, the same gated placement becomes visible.
    await expectOk(
      request.put("/api/settings/age_verification", {
        headers: { Authorization: `Bearer ${viewerAuth}` },
        data: { age_verified: true },
      }),
      "viewer age-verify"
    );
    const verifiedGated = await expectOk(
      request.get(gatedShelfPath, {
        headers: { Authorization: `Bearer ${viewerAuth}` },
      }),
      "verified gated shelf"
    );
    expect(
      (await verifiedGated.json()).count,
      "verified viewer sees the age-gated spine"
    ).toBe(1);

    // ── Ghost gate — an unknown handle is "Reader not found" ──────────────
    const unknownHandle = `nobody_${Math.floor(Math.random() * 1_000_000)}`;
    await page.goto(`/u/${unknownHandle}`);
    await expect(page.locator(".profile__name")).toHaveText("Reader not found", {
      timeout: 10000,
    });
    // The rendered "not found" text passes identically for a 403; assert the
    // WIRE status is 404 so the 404-not-403 ghost-indistinguishability invariant
    // (the epic's core security property) is actually proven, not just implied.
    const unknownResp = await request.get(`/api/u/${unknownHandle}`);
    expect(unknownResp.status(), "unknown handle must be 404, never 403").toBe(404);

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

  test("a blocked viewer gets 404 at the wire, while others still see the profile", async ({
    request,
  }) => {
    // A discoverable owner.
    const owner = await registerAndConfirm(request, "e2e-profile-blocktarget");
    test.skip(
      owner.token === null,
      "requires the /api/test/confirmation-token helper (STACKS_E2E_TEST_HELPERS=1)"
    );
    const ownerAuth = await loginViaApi(request, owner.email, E2E_PASSWORD);
    await expectOk(
      request.put("/api/settings/profile_visibility", {
        headers: { Authorization: `Bearer ${ownerAuth}` },
        data: { profile_visibility: "platform" },
      }),
      "loosen profile"
    );
    const handle = `e2e_blocktarget_${Math.floor(Math.random() * 1_000_000)}`;
    await expectOk(
      request.put("/api/settings/profile", {
        headers: { Authorization: `Bearer ${ownerAuth}` },
        data: { handle },
      }),
      "set handle"
    );
    const ownerId = (
      await (
        await expectOk(
          request.get("/api/auth/me", { headers: { Authorization: `Bearer ${ownerAuth}` } }),
          "owner /me"
        )
      ).json()
    ).user.id;

    // A viewer who blocks the owner must no longer resolve them — and the 404 is
    // indistinguishable from an absent user (never 403). Block is bidirectional.
    const viewer = await registerAndConfirm(request, "e2e-profile-blocker");
    const viewerAuth = await loginViaApi(request, viewer.email, E2E_PASSWORD);
    await expectOk(
      request.post(`/api/users/${ownerId}/block`, {
        headers: { Authorization: `Bearer ${viewerAuth}` },
      }),
      "block owner"
    );

    const blocked = await request.get(`/api/u/${handle}`, {
      headers: { Authorization: `Bearer ${viewerAuth}` },
    });
    expect(blocked.status(), "blocked viewer must get 404, never 403").toBe(404);

    // An uninvolved anonymous viewer still sees the platform profile — proving the
    // 404 is block-specific, not a broken profile.
    const anon = await request.get(`/api/u/${handle}`);
    expect(anon.status()).toBe(200);
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
 * Resolve catalogue book ids for the given seed ISBNs, in order. The catalogue
 * carries `primary_edition.isbn`, so pinning by ISBN keeps the fixtures
 * deterministic (rather than depending on catalogue ordering). Uses the owner
 * token so age-gated seed books are included in the listing.
 */
async function resolveCatalogueIds(
  request: APIRequestContext,
  authToken: string,
  isbns: string[]
): Promise<string[]> {
  const cat = await expectOk(
    request.get("/api/catalogue?per_page=200", {
      headers: { Authorization: `Bearer ${authToken}` },
    }),
    "catalogue"
  );
  const books = ((await cat.json()).books ?? []) as Array<{
    id: string;
    primary_edition?: { isbn?: string };
  }>;
  return isbns.map((isbn) => {
    const match = books.find((b) => b.primary_edition?.isbn === isbn);
    expect(match, `catalogue must contain a book with ISBN ${isbn}`).toBeDefined();
    return (match as { id: string }).id;
  });
}

/**
 * Place a specific book onto the owner's given bookshelf via the API and return
 * the new placement's id, so the caller can loosen its visibility and give the
 * platform-visible shelf a spine to render for the viewer.
 */
async function placeBook(
  request: APIRequestContext,
  authToken: string,
  bookshelfName: string,
  bookId: string
): Promise<string> {
  const placed = await expectOk(
    request.post(`/api/bookshelves/${bookshelfName}/placements`, {
      headers: { Authorization: `Bearer ${authToken}` },
      data: { book_id: bookId },
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
