import { test, expect } from "@playwright/test";
import { suiteAuthFile } from "./helpers";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/** Ensure at least one active listing exists for the current user.
 *  Reuses an existing active listing or creates+activates a new one.
 *  Must be called after page.goto() so localStorage is accessible.
 *  Returns the listing ID (existing or newly created).
 *
 *  Parallel-safe: if a concurrent test wins the create race (unique constraint
 *  violation on book_id), we wait briefly and re-check /api/listings/mine so
 *  the parallel test's activated listing is returned instead. */
async function createActiveListing(page: import("@playwright/test").Page): Promise<string> {
  const listing = await page.evaluate(async () => {
    const auth = JSON.parse(localStorage.getItem("stacks-auth") || "{}");
    const token: string = auth?.token ?? auth?.jwt ?? "";

    const getActiveListing = async (): Promise<string> => {
      const mineResp = await fetch("/api/listings/mine", {
        headers: { Authorization: `Bearer ${token}` },
      });
      if (!mineResp.ok) return "";
      const mineData = await mineResp.json();
      const active = (mineData?.listings ?? []).find((l: any) => l.status === "active");
      return active?.id ?? "";
    };

    // If the user already has an active listing, reuse it.
    const existingId = await getActiveListing();
    if (existingId) return existingId;

    // Use a book the user already has on a shelf — create_listing requires a placement
    const placementsResp = await fetch("/api/placements/mine", {
      headers: { Authorization: `Bearer ${token}` },
    });
    const placementsData = placementsResp.ok ? await placementsResp.json() : { placements: [] };
    const bookId: string = placementsData?.placements?.[0]?.book_id ?? "";

    // Create draft
    const createResp = await fetch("/api/listings", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${token}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        book_id: bookId,
        pricing_mode: "fixed",
        price_cents: 15000,
        condition: "good",
        description: "E2E test listing",
        contact_info: "e2e-test@thestacks.test",
      }),
    });
    const createData = await createResp.json();
    const listingId: string = createData?.listing?.id ?? "";

    if (!listingId) {
      // A parallel test likely won the create race (unique constraint on book_id).
      // Wait briefly for it to activate, then return its listing.
      await new Promise((r) => setTimeout(r, 1500));
      return await getActiveListing();
    }

    // Activate
    await fetch(`/api/listings/${listingId}/activate`, {
      method: "PUT",
      headers: { Authorization: `Bearer ${token}` },
    });

    return listingId;
  });

  return listing;
}

/** Locate the browse card for a SPECIFIC listing.
 *
 *  Browse is a global feed of every user's active listings ordered by
 *  `listed_at DESC` (Marketplace.list_active_listings/1), so `.first()` is
 *  whichever listing was most recently activated by ANY user — not necessarily
 *  the one this test created. `public-profile.spec.ts` activates listings with
 *  no `contact_info`, and `createActiveListing` below REUSES the suite user's
 *  existing listing (leaving its `listed_at` stale), so after that spec has run
 *  once the foreign listing sorts first permanently. Addressing the card by its
 *  href keeps the assertions pinned to the listing under test. */
function listingCard(page: import("@playwright/test").Page, listingId: string) {
  return page.locator(`.marketplace__card[href="/marketplace/${listingId}"]`);
}

// ---------------------------------------------------------------------------
// Unauthenticated browse
// ---------------------------------------------------------------------------

test.describe("Marketplace — unauthenticated browse", () => {
  test("browse page loads without authentication", async ({ page }) => {
    await page.goto("/marketplace");
    await expect(page.locator(".page--marketplace-browse")).toBeVisible({
      timeout: 10000,
    });
    await expect(page.locator("h1")).toContainText("Marketplace");
  });

  test("browse page shows grid or empty state (never blank)", async ({ page }) => {
    await page.goto("/marketplace");
    await expect(page.locator(".page--marketplace-browse")).toBeVisible({
      timeout: 10000,
    });
    // Wait for loading to settle — page renders either grid or empty message
    await page.waitForFunction(
      () => {
        const grid = document.querySelector(".marketplace__grid");
        const empty = document.querySelector(".marketplace__empty");
        const loading = document.querySelector(".loading");
        return (grid !== null || empty !== null) && loading === null;
      },
      { timeout: 10000 }
    );
    const hasGrid = await page.locator(".marketplace__grid").isVisible();
    const hasEmpty = await page.locator(".marketplace__empty").isVisible();
    expect(hasGrid || hasEmpty).toBe(true);
  });

  test("/marketplace/mine redirects unauthenticated users to login", async ({
    page,
  }) => {
    // MarketplaceMyListings requires auth — Elm redirects to the login page.
    await page.goto("/marketplace/mine");
    await expect(page.locator(".page--login")).toBeVisible({
      timeout: 10000,
    });
  });
});

// ---------------------------------------------------------------------------
// Authenticated browse + listing lifecycle
// ---------------------------------------------------------------------------

test.describe("Marketplace — authenticated", () => {
  test.use({ storageState: suiteAuthFile("catalogue") });

  test("Marketplace nav entry is visible when authenticated", async ({
    page,
  }) => {
    await page.goto("/library");
    await page.waitForSelector(".app-nav__link", { timeout: 10000 });

    // Marketplace is a disclosure BUTTON now (#318 TR-1), not a top-level link;
    // its Browse/Create/Mine links live behind it. Assert the entry point is
    // present, then open it and confirm Browse points at /marketplace.
    const marketplace = page.locator(
      'button.app-nav__disclosure:has-text("Marketplace")'
    );
    await expect(marketplace).toBeVisible();
    await marketplace.click();
    await expect(marketplace).toHaveAttribute("aria-expanded", "true");
    await expect(
      page.locator('a.app-nav__dropdown-link[href="/marketplace"]')
    ).toBeVisible({ timeout: 5000 });
  });

  test("active listing appears on browse page and shows contact info on detail", async ({
    page,
  }) => {
    await page.goto("/marketplace");
    await expect(page.locator(".page--marketplace-browse")).toBeVisible({
      timeout: 10000,
    });

    // Create a listing so we have something to browse
    const listingId = await createActiveListing(page);
    expect(listingId).not.toBe("");

    // Reload browse page — our listing should now appear
    await page.goto("/marketplace");
    await expect(page.locator(".marketplace__grid")).toBeVisible({
      timeout: 15000,
    });
    await expect(listingCard(page, listingId)).toBeVisible();

    // Click OUR card → navigate to its detail page
    await listingCard(page, listingId).click();
    // Exact pathname match via predicate, not `new RegExp(listingId)` — building
    // a regex from a variable trips semgrep's non-literal-regexp rule (blocking
    // in `just ci`). The predicate is also stricter than the substring regex.
    await expect(page).toHaveURL((url) => url.pathname === `/marketplace/${listingId}`, {
      timeout: 10000,
    });
    await expect(page.locator(".marketplace-detail")).toBeVisible({
      timeout: 10000,
    });

    // Contact info should be visible on active listing
    await expect(page.locator(".marketplace-detail__contact")).toBeVisible();
    await expect(page.locator(".marketplace-detail__contact")).toContainText(
      "e2e-test@thestacks.test"
    );
  });

  test("listing card shows condition badge and price", async ({ page }) => {
    // Create a listing to guarantee something is on the page
    await page.goto("/marketplace");
    await expect(page.locator(".page--marketplace-browse")).toBeVisible({
      timeout: 10000,
    });

    const listingId = await createActiveListing(page);
    expect(listingId).not.toBe("");
    await page.goto("/marketplace");
    await expect(page.locator(".marketplace__grid")).toBeVisible({
      timeout: 15000,
    });

    const card = listingCard(page, listingId);
    await expect(card.locator(".marketplace__condition-badge")).toBeVisible();
    await expect(card.locator(".marketplace__price")).toBeVisible();
    await expect(card.locator(".marketplace__card-title")).toBeVisible();
    await expect(card.locator(".marketplace__card-author")).toBeVisible();
  });

  test("/marketplace/mine loads and shows My Listings page", async ({
    page,
  }) => {
    await page.goto("/marketplace/mine");
    await expect(page.locator(".page--marketplace-mine")).toBeVisible({
      timeout: 10000,
    });
  });

  test("back link on detail page returns to marketplace", async ({ page }) => {
    await page.goto("/marketplace");
    const listingId = await createActiveListing(page);
    expect(listingId).not.toBe("");
    await page.goto("/marketplace");
    await page.locator(".marketplace__grid").waitFor({ timeout: 15000 });
    await listingCard(page, listingId).click();
    await page.locator(".marketplace-detail__back a").click();
    await expect(page).toHaveURL(/\/marketplace$/, { timeout: 10000 });
  });
});
