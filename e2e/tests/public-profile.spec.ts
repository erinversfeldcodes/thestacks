import { test, expect } from "@playwright/test";
import type { APIRequestContext, APIResponse } from "@playwright/test";
import {
  uniqueEmail,
  mintOrSkip,
  injectSession,
  ensureBookOnLibrary,
  apiCallFromPage,
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
 * WHY throwaway users (not the shared seeded suite users): these tests MUTATE
 * profile/bookshelf visibility and handle. Each owns single-purpose fixtures,
 * e.g.:
 *   - OWNER (B): a discoverable "public" profile with a claimed handle, a
 *     platform-visible "library" (one placed book) and an owner-only "wishlist".
 *     B never touches the browser — API only.
 *   - VIEWER (A): drives the browser as a second signed-in reader.
 *
 * Every fixture is minted via POST /api/test/session (Issue #280) — one call
 * that creates a confirmed user AND returns its session token/user id, OUTSIDE
 * the `:auth` rate bucket. This replaces the register→confirmation-token→confirm
 * →login dance (and its 429-backoff): the parallel suite shares the `:auth`
 * budget (60/60s per IP), and this spec's back-to-back fresh-user creation under
 * #116's consolidated preview gate was the proven 429 source (PE P2-1). Browser
 * fixtures inject the minted session directly; API-only fixtures use the token.
 * `mintOrSkip` skips cleanly where the helper is unavailable, matching
 * gdpr/reading-journey.
 *
 * A brand-new viewer is placement-free, so the GLOBAL onboarding overlay
 * intercepts pointer events everywhere; `ensureBookOnLibrary` places a book to
 * clear it, and we assert the overlay is gone before interacting.
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
    const owner = await mintOrSkip(request, {
      email: uniqueEmail("e2e-profile-owner"),
      displayName: ownerName,
    });
    const ownerAuth = owner.token;

    // A fresh user defaults to profile_visibility "owner" (a ghost). Loosen to
    // "platform" so another signed-in reader can discover and view the profile.
    await expectOk(
      request.put("/api/settings/profile_visibility", {
        headers: { Authorization: `Bearer ${ownerAuth}` },
        data: { profile_visibility: "public" },
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

    // Age-verify the OWNER first (ADR-020: provider-sourced, set via the
    // STACKS_E2E_TEST_HELPERS helper). With AGE_GATING_ENABLED=true in E2E, the
    // catalogue includes age-gated books ONLY for an age-verified browser; a
    // freshly-registered owner defaults `age_verified` false, so the age-gated
    // "Demons" (AGE_GATED_ISBN) would be hidden and resolveCatalogueIds would
    // throw. The owner is verified here so it can resolve BOTH pinned books.
    await expectOk(
      request.put("/api/test/age-verification", {
        data: { email: owner.email, verified: true },
      }),
      "owner age-verify"
    );

    // Resolve deterministic catalogue book ids by ISBN so the visible spine and
    // the age-gate row are PINNED to known seed books. The catalogue includes
    // age-gated books only for an age-verified browser, which is why the owner
    // is age-verified first (above); the owner token is used for the read.
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

    // A PUBLIC "antilibrary" holding ONLY the age-gated "Demons", so the shelf's
    // viewer-visible `count` is a clean age-gate signal: 0 when the gated spine is
    // suppressed, 1 once the viewer is age-verified. Public (not platform) so the
    // anonymous age-gate check below can reach the shelf at all (#225).
    const gatedPlacementId = await placeBook(request, ownerAuth, "antilibrary", ageGatedBookId);
    await setBookshelfVisibility(request, ownerAuth, "antilibrary", "public");
    await setPlacementVisibility(request, ownerAuth, gatedPlacementId, "public");

    // An owner-only "wishlist" that must NOT surface to the viewer.
    await setBookshelfVisibility(request, ownerAuth, "wishlist", "owner");

    // ── VIEWER (A) — browser ──────────────────────────────────────────────
    const viewer = await mintOrSkip(request, {
      email: uniqueEmail("e2e-profile-viewer"),
    });
    await injectSession(page, viewer);
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
    await expect(shelfLinks.filter({ hasText: /^Library$/ })).toHaveCount(1);
    await expect(shelfLinks.filter({ hasText: "Wish List" })).toHaveCount(0);

    // ── US-10.5.3 — browse the shelf read-only ────────────────────────────
    await shelfLinks.filter({ hasText: /^Library$/ }).getByRole("link").click();
    await expect(page).toHaveURL((url) => url.pathname === `/u/${ownerHandle}/library`);
    await expect(page.getByTestId("bookshelf-page")).toBeVisible({ timeout: 10000 });
    // At least one visible spine renders…
    await expect(page.getByTestId("book-spine").first()).toBeVisible();
    // …and NO owner control leaks into the read-only view (SECURITY).
    await expect(page.getByRole("button", { name: "Add shelf" })).toHaveCount(0);

    // ── Age gate — the age-gated spine is suppressed unless the viewer is verified ──
    // The "antilibrary" holds exactly one PUBLIC but AGE-GATED
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
    // ADR-020: verification is provider-sourced — set via the STACKS_E2E_TEST_HELPERS
    // helper (scoped to the viewer's `@thestacks.test` email), not the removed
    // self-declared `PUT /api/settings/age_verification` endpoint.
    await expectOk(
      request.put("/api/test/age-verification", {
        data: { email: viewer.email, verified: true },
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
    await expect(page).toHaveURL((url) => url.pathname === `/u/${ownerHandle}`);
    await expect(page.locator(".profile__name")).toHaveText(ownerName, {
      timeout: 10000,
    });
  });

  test("a blocked viewer gets 404 at the wire, while others still see the profile", async ({
    request,
  }) => {
    // A discoverable owner.
    const owner = await mintOrSkip(request, {
      email: uniqueEmail("e2e-profile-blocktarget"),
    });
    const ownerAuth = owner.token;
    await expectOk(
      request.put("/api/settings/profile_visibility", {
        headers: { Authorization: `Bearer ${ownerAuth}` },
        data: { profile_visibility: "public" },
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
    const ownerId = owner.userId;

    // A viewer who blocks the owner must no longer resolve them — and the 404 is
    // indistinguishable from an absent user (never 403). Block is bidirectional.
    const viewer = await mintOrSkip(request, {
      email: uniqueEmail("e2e-profile-blocker"),
    });
    const viewerAuth = viewer.token;
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

    // An uninvolved anonymous viewer still sees the public profile — proving the
    // 404 is block-specific, not a broken profile.
    const anon = await request.get(`/api/u/${handle}`);
    expect(anon.status()).toBe(200);
  });

  // ── #226 item 1 — anon RENDERED: public vs platform (Members) ───────────────
  // The core #225 promise, rendered: a logged-out browser SEES a `public` profile
  // + browses its `public` shelf spine, but a `platform` (Members) profile reads
  // as "Reader not found". Previously only wire-level (status codes) — this proves
  // the shipped Elm actually renders the anon projection.
  test("an anonymous browser renders a public profile + public shelf, but a platform profile is not found", async ({
    browser,
    request,
  }) => {
    // Public owner (B) — discoverable, with a PUBLIC library holding one public,
    // non-age-gated spine so an anon viewer has something to render.
    const publicName = `E2E Public ${Math.floor(Math.random() * 1_000_000)}`;
    const pub = await mintOrSkip(request, {
      email: uniqueEmail("e2e-anon-public"),
      displayName: publicName,
    });
    const pubAuth = pub.token;
    await setProfileVisibility(request, pubAuth, "public");
    const pubHandle = await claimHandle(request, pubAuth, "e2e_public");
    const [visibleBookId] = await resolveCatalogueIds(request, pubAuth, [VISIBLE_ISBN]);
    const pubPlacementId = await placeBook(request, pubAuth, "library", visibleBookId);
    await setBookshelfVisibility(request, pubAuth, "library", "public");
    await setPlacementVisibility(request, pubAuth, pubPlacementId, "public");

    // Platform owner (C) — signed-in-only; an anon viewer must NOT resolve it.
    const plat = await mintOrSkip(request, {
      email: uniqueEmail("e2e-anon-platform"),
    });
    const platAuth = plat.token;
    await setProfileVisibility(request, platAuth, "platform");
    const platHandle = await claimHandle(request, platAuth, "e2e_platform");

    // A pristine ANONYMOUS browser context (no stored auth).
    const anonCtx = await browser.newContext({ storageState: { cookies: [], origins: [] } });
    const page = await anonCtx.newPage();
    try {
      // Public profile renders identity + the public shelf link…
      await page.goto(`/u/${pubHandle}`);
      await expect(page.locator(".profile__name")).toHaveText(publicName, { timeout: 10000 });
      const shelfLinks = page.locator(".profile__shelf");
      await expect(shelfLinks.filter({ hasText: /^Library$/ })).toHaveCount(1);

      // …and the public shelf browses read-only with a visible spine, no controls.
      await shelfLinks.filter({ hasText: /^Library$/ }).getByRole("link").click();
      await expect(page).toHaveURL((url) => url.pathname === `/u/${pubHandle}/library`);
      await expect(page.getByTestId("bookshelf-page")).toBeVisible({ timeout: 10000 });
      await expect(page.getByTestId("book-spine").first()).toBeVisible();
      await expect(page.getByRole("button", { name: "Add shelf" })).toHaveCount(0);

      // The platform (Members) profile is "Reader not found" to a logged-out viewer.
      await page.goto(`/u/${platHandle}`);
      await expect(page.locator(".profile__name")).toHaveText("Reader not found", {
        timeout: 10000,
      });
    } finally {
      await anonCtx.close();
    }
  });

  // ── #226 item 5 — block on the profile HUB, RENDERED ────────────────────────
  // The existing block test asserts the wire 404; this asserts the blocked viewer
  // actually RENDERS "Reader not found" on the hub (browser), not just a status.
  test("a signed-in blocked viewer renders 'Reader not found' on the profile hub", async ({
    page,
    request,
  }) => {
    const owner = await mintOrSkip(request, {
      email: uniqueEmail("e2e-blockhub-owner"),
    });
    const ownerAuth = owner.token;
    await setProfileVisibility(request, ownerAuth, "public");
    const ownerHandle = await claimHandle(request, ownerAuth, "e2e_blockhub");
    const ownerId = owner.userId;

    // Viewer blocks the owner, then drives the browser to the owner's hub.
    const viewer = await mintOrSkip(request, {
      email: uniqueEmail("e2e-blockhub-viewer"),
    });
    await injectSession(page, viewer);
    await ensureBookOnLibrary(page);
    await expectOk(
      request.post(`/api/users/${ownerId}/block`, {
        headers: { Authorization: `Bearer ${viewer.token}` },
      }),
      "block owner"
    );

    await page.goto(`/u/${ownerHandle}`);
    await expect(page.getByTestId("onboarding-overlay")).not.toBeVisible();
    await expect(page.locator(".profile__name")).toHaveText("Reader not found", {
      timeout: 10000,
    });
  });

  // ── #226 item 4 — view_as actually RE-SCOPES the owner's own shelf ──────────
  // privacy.spec.ts only proves the banner renders. This drives the real
  // ViewAsPlug + resolver on the live stack: the owner's platform placement is
  // present in their own view, but hidden under `?view_as=unauthenticated`.
  test("view_as=unauthenticated re-scopes the owner's own shelf (platform placement hidden)", async ({
    page,
    request,
  }) => {
    const owner = await mintOrSkip(request, {
      email: uniqueEmail("e2e-viewas-owner"),
    });
    await injectSession(page, owner);
    const ownerAuth = owner.token;

    // A PUBLIC library (reachable by anon) holding a single PLATFORM placement
    // (signed-in-only). Profile is public so the public shelf is within the
    // ceiling. This isolates placement-level re-scoping: the shelf stays visible
    // to anon (200) while the platform spine is what disappears — not the shelf.
    await setProfileVisibility(request, ownerAuth, "public");
    const [visibleBookId] = await resolveCatalogueIds(request, ownerAuth, [VISIBLE_ISBN]);
    const placementId = await placeBook(request, ownerAuth, "library", visibleBookId);
    await setBookshelfVisibility(request, ownerAuth, "library", "public");
    await setPlacementVisibility(request, ownerAuth, placementId, "platform");

    // Drive the fetch FROM the authenticated browser so it runs through the real
    // ViewAsPlug (which requires :authenticated). The owner sees their own
    // platform placement; the anonymous projection hides it while the (public)
    // shelf itself stays reachable.
    const own = await apiCallFromPage(page, "GET", "/api/bookshelves/library");
    expect(own.status).toBe(200);
    expect((own.data as { count: number }).count, "owner sees own platform placement").toBe(1);

    const previewed = await apiCallFromPage(
      page,
      "GET",
      "/api/bookshelves/library?view_as=unauthenticated"
    );
    expect(previewed.status).toBe(200);
    expect(
      (previewed.data as { count: number }).count,
      "the anonymous projection hides the platform placement"
    ).toBe(0);
  });

  // ── #226 item 6 — marketplace ceiling-punch, live E2E ───────────────────────
  // An ACTIVE looking_for_home listing makes an owner-rung placement visible to a
  // signed-in viewer (punch), surfaces in the public listings browse, but stays
  // hidden from an anonymous profile-shelf reader. Complements the resolver unit
  // (visibility_test.exs) and the new controller test (profile_controller_test).
  test("an active looking_for_home listing punches through for a signed-in viewer, not for anon", async ({
    request,
  }) => {
    const owner = await mintOrSkip(request, {
      email: uniqueEmail("e2e-mkt-owner"),
    });
    const ownerAuth = owner.token;
    await setProfileVisibility(request, ownerAuth, "public");
    const ownerHandle = await claimHandle(request, ownerAuth, "e2e_mkt");

    // An owner-rung placement on a PUBLIC looking_for_home shelf (the shelf is
    // reachable; only the placement's rung is restrictive).
    const [bookId] = await resolveCatalogueIds(request, ownerAuth, [VISIBLE_ISBN]);
    const placementId = await placeBook(request, ownerAuth, "looking_for_home", bookId);
    await setBookshelfVisibility(request, ownerAuth, "looking_for_home", "public");
    await setPlacementVisibility(request, ownerAuth, placementId, "owner");

    const shelfPath = `/api/u/${ownerHandle}/bookshelves/looking_for_home`;

    // Before listing: owner-rung placement is hidden from a signed-in viewer.
    const viewer = await mintOrSkip(request, {
      email: uniqueEmail("e2e-mkt-viewer"),
    });
    const viewerAuth = viewer.token;
    const beforeAuthed = { Authorization: `Bearer ${viewerAuth}` };
    const before = await expectOk(request.get(shelfPath, { headers: beforeAuthed }), "pre-listing");
    expect((await before.json()).count, "owner-rung placement hidden before listing").toBe(0);

    // Create + activate a marketplace listing on that placement's book.
    const created = await expectOk(
      request.post("/api/listings", {
        headers: { Authorization: `Bearer ${ownerAuth}` },
        data: { book_id: bookId, pricing_mode: "fixed", price_cents: 12_000, condition: "good" },
      }),
      "create listing"
    );
    const listingId = (await created.json()).listing.id as string;
    await expectOk(
      request.put(`/api/listings/${listingId}/activate`, {
        headers: { Authorization: `Bearer ${ownerAuth}` },
      }),
      "activate listing"
    );

    // Punch-through: the signed-in viewer now sees the placement…
    const afterAuthed = await expectOk(
      request.get(shelfPath, { headers: beforeAuthed }),
      "post-listing authed"
    );
    expect((await afterAuthed.json()).count, "active listing punches through for a platform viewer").toBe(1);

    // …an anonymous profile-shelf reader still does NOT (punch is platform-only)…
    const afterAnon = await expectOk(request.get(shelfPath), "post-listing anon");
    expect((await afterAnon.json()).count, "no punch-through for an anonymous viewer").toBe(0);

    // …and the active listing is discoverable in the public listings browse.
    const listings = await expectOk(request.get("/api/listings"), "public listings browse");
    const ids = ((await listings.json()).listings ?? []).map((l: { id: string }) => l.id);
    expect(ids, "the active listing surfaces in the public browse").toContain(listingId);
  });
});

/**
 * Resolve catalogue book ids for the given seed ISBNs, in order. The catalogue
 * carries `primary_edition.isbn`, so pinning by ISBN keeps the fixtures
 * deterministic (rather than depending on catalogue ordering). Uses the owner
 * token so age-gated seed books are included in the listing.
 *
 * The catalogue caps `per_page` at 100 (catalogue_controller.ex) while the seed
 * set is larger, so a single page misses books past position 100. We PAGE THROUGH
 * (100 at a time, bounded by the reported `total`) until every requested ISBN is
 * resolved — never assuming a book lands on page 1.
 */
async function resolveCatalogueIds(
  request: APIRequestContext,
  authToken: string,
  isbns: string[]
): Promise<string[]> {
  type CatBook = { id: string; primary_edition?: { isbn?: string } };
  const byIsbn = new Map<string, string>();
  const wanted = new Set(isbns);

  let page = 1;
  let total = Infinity;
  let seen = 0;
  // Bound the loop defensively; 100/page over the seed set is a handful of pages.
  while (seen < total && wanted.size > byIsbn.size && page <= 50) {
    const resp = await expectOk(
      request.get(`/api/catalogue?per_page=100&page=${page}`, {
        headers: { Authorization: `Bearer ${authToken}` },
      }),
      `catalogue page ${page}`
    );
    const body = (await resp.json()) as { books?: CatBook[]; total?: number };
    const books = body.books ?? [];
    total = body.total ?? books.length;
    seen += books.length;
    for (const b of books) {
      const isbn = b.primary_edition?.isbn;
      if (isbn && wanted.has(isbn)) byIsbn.set(isbn, b.id);
    }
    if (books.length === 0) break;
    page += 1;
  }

  return isbns.map((isbn) => {
    const id = byIsbn.get(isbn);
    expect(id, `catalogue must contain a book with ISBN ${isbn}`).toBeDefined();
    return id as string;
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

/** Set a user's profile visibility (owner | group | platform | public) via the API. */
async function setProfileVisibility(
  request: APIRequestContext,
  authToken: string,
  visibility: string
): Promise<void> {
  await expectOk(
    request.put("/api/settings/profile_visibility", {
      headers: { Authorization: `Bearer ${authToken}` },
      data: { profile_visibility: visibility },
    }),
    `set profile → ${visibility}`
  );
}

/**
 * Claim a random handle with the given prefix and return the normalised
 * (lowercased) value the server echoes — exactly what /u/:handle resolves.
 */
async function claimHandle(
  request: APIRequestContext,
  authToken: string,
  prefix: string
): Promise<string> {
  const handle = `${prefix}_${Math.floor(Math.random() * 1_000_000)}`;
  const resp = await expectOk(
    request.put("/api/settings/profile", {
      headers: { Authorization: `Bearer ${authToken}` },
      data: { handle },
    }),
    "set handle"
  );
  return ((await resp.json()).handle as string) ?? handle;
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
