import { test, expect } from "@playwright/test";
import type { APIRequestContext, APIResponse, Page } from "@playwright/test";
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

const VISIBLE_ISBN = "9780061120084"; // "The Left Hand of Darkness" — public
const AGE_GATED_ISBN = "9780140449242"; // "Demons" — age_gated

/**
 * A shelf row on the profile hub, identified by its own BROWSE LINK.
 *
 * ⚠️ Not by the row's text. A `.profile__shelf` row is an `<li>` that holds the browse
 * anchor AND — when the shelf advertises an Atom feed — a sibling "Feed" anchor
 * (`Page.Profile.viewFeedLink`). Playwright matches a RegExp `hasText` against the
 * element's whole `textContent`, so the row reads `"LibraryFeed"` and the anchored
 * `/^Library$/` this spec used to pass matched NOTHING once the subscribe link shipped.
 * The row was rendering correctly the whole time; the locator described a DOM that had
 * stopped existing.
 *
 * `exact: true` keeps this at least as tight as the anchored regex was meant to be — the
 * row must carry the "Library" link, never a "Library of Babel" one — while staying
 * immune to further additive siblings inside the row.
 */
function shelfRow(page: Page, label: string) {
  return page
    .locator(".profile__shelf")
    .filter({ has: page.getByRole("link", { name: label, exact: true }) });
}

test.describe("Public profiles — view, browse & discover (live browser journey)", () => {
  test("a discoverable reader's profile shows visible shelves only, browses read-only, and is discoverable by search", async ({
    page,
    request,
  }) => {
    const ownerName = `E2E Reader ${Math.floor(Math.random() * 1_000_000)}`;
    const owner = await mintOrSkip(request, {
      email: uniqueEmail("e2e-profile-owner"),
      displayName: ownerName,
    });
    const ownerAuth = owner.token;

    await expectOk(
      request.put("/api/settings/profile_visibility", {
        headers: { Authorization: `Bearer ${ownerAuth}` },
        data: { profile_visibility: "public" },
      }),
      "loosen profile"
    );

    const handle = `e2e_reader_${Math.floor(Math.random() * 1_000_000)}`;
    const setHandle = await expectOk(
      request.put("/api/settings/profile", {
        headers: { Authorization: `Bearer ${ownerAuth}` },
        data: { handle },
      }),
      "set handle"
    );
    const ownerHandle = ((await setHandle.json()).handle as string) ?? handle;

    await expectOk(
      request.put("/api/test/age-verification", {
        data: { email: owner.email, verified: true },
      }),
      "owner age-verify"
    );

    const [visibleBookId, ageGatedBookId] = await resolveCatalogueIds(
      request,
      ownerAuth,
      [VISIBLE_ISBN, AGE_GATED_ISBN]
    );

    const placementId = await placeBook(request, ownerAuth, "library", visibleBookId);
    await setBookshelfVisibility(request, ownerAuth, "library", "platform");
    await setPlacementVisibility(request, ownerAuth, placementId, "platform");

    const gatedPlacementId = await placeBook(request, ownerAuth, "antilibrary", ageGatedBookId);
    await setBookshelfVisibility(request, ownerAuth, "antilibrary", "public");
    await setPlacementVisibility(request, ownerAuth, gatedPlacementId, "public");

    await setBookshelfVisibility(request, ownerAuth, "wishlist", "owner");

    const viewer = await mintOrSkip(request, {
      email: uniqueEmail("e2e-profile-viewer"),
    });
    await injectSession(page, viewer);
    await ensureBookOnLibrary(page);

    await page.goto(`/u/${ownerHandle}`);
    await expect(page.getByTestId("onboarding-overlay")).not.toBeVisible();
    await expect(page.locator(".profile__name")).toHaveText(ownerName, {
      timeout: 10000,
    });
    await expect(page.locator(".profile__handle")).toHaveText(`@${ownerHandle}`);

    await expect(shelfRow(page, "Library")).toHaveCount(1);
    await expect(shelfRow(page, "Wish List")).toHaveCount(0);

    await shelfRow(page, "Library")
      .getByRole("link", { name: "Library", exact: true })
      .click();
    await expect(page).toHaveURL((url) => url.pathname === `/u/${ownerHandle}/library`);
    await expect(page.getByTestId("bookshelf-page")).toBeVisible({ timeout: 10000 });
    await expect(page.getByTestId("book-spine").first()).toBeVisible();
    await expect(page.getByRole("button", { name: "Add shelf" })).toHaveCount(0);

    const gatedShelfPath = `/api/u/${ownerHandle}/bookshelves/antilibrary`;

    const anonGated = await expectOk(request.get(gatedShelfPath), "anon gated shelf");
    expect((await anonGated.json()).count, "anon must not see the age-gated spine").toBe(0);

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

    const unknownHandle = `nobody_${Math.floor(Math.random() * 1_000_000)}`;
    await page.goto(`/u/${unknownHandle}`);
    await expect(page.locator(".profile__name")).toHaveText("Reader not found", {
      timeout: 10000,
    });
    const unknownResp = await request.get(`/api/u/${unknownHandle}`);
    expect(unknownResp.status(), "unknown handle must be 404, never 403").toBe(404);

    await page.goto("/search");
    await expect(page.getByTestId("onboarding-overlay")).not.toBeVisible();
    await page.getByTestId("search-input").fill(ownerName);

    const readerCard = page.getByTestId("reader-card");
    await expect(readerCard).toHaveCount(1, { timeout: 10000 });
    await expect(readerCard).toContainText(`@${ownerHandle}`);

    await readerCard.click();
    await expect(page).toHaveURL((url) => url.pathname === `/u/${ownerHandle}`);
    await expect(page.locator(".profile__name")).toHaveText(ownerName, {
      timeout: 10000,
    });
  });

  test("a blocked viewer gets 404 at the wire, while others still see the profile", async ({
    request,
  }) => {
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

    const anon = await request.get(`/api/u/${handle}`);
    expect(anon.status()).toBe(200);
  });

  test("an anonymous browser renders a public profile + public shelf, but a platform profile is not found", async ({
    browser,
    request,
  }) => {
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

    const plat = await mintOrSkip(request, {
      email: uniqueEmail("e2e-anon-platform"),
    });
    const platAuth = plat.token;
    await setProfileVisibility(request, platAuth, "platform");
    const platHandle = await claimHandle(request, platAuth, "e2e_platform");

    const anonCtx = await browser.newContext({ storageState: { cookies: [], origins: [] } });
    const page = await anonCtx.newPage();
    try {
      await page.goto(`/u/${pubHandle}`);
      await expect(page.locator(".profile__name")).toHaveText(publicName, { timeout: 10000 });
      await expect(shelfRow(page, "Library")).toHaveCount(1);

      await shelfRow(page, "Library")
        .getByRole("link", { name: "Library", exact: true })
        .click();
      await expect(page).toHaveURL((url) => url.pathname === `/u/${pubHandle}/library`);
      await expect(page.getByTestId("bookshelf-page")).toBeVisible({ timeout: 10000 });
      await expect(page.getByTestId("book-spine").first()).toBeVisible();
      await expect(page.getByRole("button", { name: "Add shelf" })).toHaveCount(0);

      await page.goto(`/u/${platHandle}`);
      await expect(page.locator(".profile__name")).toHaveText("Reader not found", {
        timeout: 10000,
      });
    } finally {
      await anonCtx.close();
    }
  });

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

  test("view_as=unauthenticated re-scopes the owner's own shelf (platform placement hidden)", async ({
    page,
    request,
  }) => {
    const owner = await mintOrSkip(request, {
      email: uniqueEmail("e2e-viewas-owner"),
    });
    await injectSession(page, owner);
    const ownerAuth = owner.token;

    await setProfileVisibility(request, ownerAuth, "public");
    const [visibleBookId] = await resolveCatalogueIds(request, ownerAuth, [VISIBLE_ISBN]);
    const placementId = await placeBook(request, ownerAuth, "library", visibleBookId);
    await setBookshelfVisibility(request, ownerAuth, "library", "public");
    await setPlacementVisibility(request, ownerAuth, placementId, "platform");

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

  test("an active looking_for_home listing punches through for a signed-in viewer, not for anon", async ({
    request,
  }) => {
    const owner = await mintOrSkip(request, {
      email: uniqueEmail("e2e-mkt-owner"),
    });
    const ownerAuth = owner.token;
    await setProfileVisibility(request, ownerAuth, "public");
    const ownerHandle = await claimHandle(request, ownerAuth, "e2e_mkt");

    const [bookId] = await resolveCatalogueIds(request, ownerAuth, [VISIBLE_ISBN]);
    const placementId = await placeBook(request, ownerAuth, "looking_for_home", bookId);
    await setBookshelfVisibility(request, ownerAuth, "looking_for_home", "public");
    await setPlacementVisibility(request, ownerAuth, placementId, "owner");

    const shelfPath = `/api/u/${ownerHandle}/bookshelves/looking_for_home`;

    const viewer = await mintOrSkip(request, {
      email: uniqueEmail("e2e-mkt-viewer"),
    });
    const viewerAuth = viewer.token;
    const beforeAuthed = { Authorization: `Bearer ${viewerAuth}` };
    const before = await expectOk(request.get(shelfPath, { headers: beforeAuthed }), "pre-listing");
    expect((await before.json()).count, "owner-rung placement hidden before listing").toBe(0);

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

    const afterAuthed = await expectOk(
      request.get(shelfPath, { headers: beforeAuthed }),
      "post-listing authed"
    );
    expect((await afterAuthed.json()).count, "active listing punches through for a platform viewer").toBe(1);

    const afterAnon = await expectOk(request.get(shelfPath), "post-listing anon");
    expect((await afterAnon.json()).count, "no punch-through for an anonymous viewer").toBe(0);

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
