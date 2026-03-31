import { test, expect } from "@playwright/test";
import { suiteAuthFile } from "./helpers";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/** Ensure at least one active listing exists for the current user.
 *  Reuses an existing active listing or creates+activates a new one.
 *  Must be called after page.goto() so localStorage is accessible.
 *  Returns the listing ID (existing or newly created). */
async function createActiveListing(page: import("@playwright/test").Page): Promise<string> {
  const listing = await page.evaluate(async () => {
    const auth = JSON.parse(localStorage.getItem("stacks-auth") || "{}");
    const token: string = auth?.token ?? auth?.jwt ?? "";

    // If the user already has an active listing, reuse it (avoids unique constraint
    // violations when parallel tests share the same catalogue user auth state).
    const mineResp = await fetch("/api/listings/mine", {
      headers: { Authorization: `Bearer ${token}` },
    });
    if (mineResp.ok) {
      const mineData = await mineResp.json();
      const active = (mineData?.listings ?? []).find((l: any) => l.status === "active");
      if (active) return active.id;
    }

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

    // Activate
    await fetch(`/api/listings/${listingId}/activate`, {
      method: "PUT",
      headers: { Authorization: `Bearer ${token}` },
    });

    return listingId;
  });

  return listing;
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

  test("Marketplace nav link is visible when authenticated", async ({
    page,
  }) => {
    await page.goto("/library");
    await page.waitForSelector(".app-nav__link", { timeout: 10000 });
    await expect(
      page.locator('a.app-nav__link[href="/marketplace"]')
    ).toBeVisible();
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

    // Reload browse page — listing should now appear
    await page.goto("/marketplace");
    await expect(page.locator(".marketplace__grid")).toBeVisible({
      timeout: 15000,
    });
    await expect(page.locator(".marketplace__card").first()).toBeVisible();

    // Click first card → navigate to detail page
    await page.locator(".marketplace__card").first().click();
    await expect(page).toHaveURL(/\/marketplace\//, { timeout: 10000 });
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

    const firstCard = page.locator(".marketplace__card").first();
    await expect(firstCard.locator(".marketplace__condition-badge")).toBeVisible();
    await expect(firstCard.locator(".marketplace__price")).toBeVisible();
    await expect(firstCard.locator(".marketplace__card-title")).toBeVisible();
    await expect(firstCard.locator(".marketplace__card-author")).toBeVisible();
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
    await createActiveListing(page);
    await page.goto("/marketplace");
    await page.locator(".marketplace__grid").waitFor({ timeout: 15000 });
    await page.locator(".marketplace__card").first().click();
    await page.locator(".marketplace-detail__back a").click();
    await expect(page).toHaveURL(/\/marketplace$/, { timeout: 10000 });
  });
});
