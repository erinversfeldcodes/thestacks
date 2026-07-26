import { test, expect } from "@playwright/test";
import { suiteAuthFile } from "./helpers";

test.describe("Navbar navigation — authenticated", () => {
  test.use({ storageState: suiteAuthFile("navigation") });

  // Top-level nav items (visible as direct links)
  const topLevelItems = [
    { label: "Library", path: "/library", href: "/library" },
    { label: "Antilibrary", path: "/antilibrary", href: "/antilibrary" },
    { label: "Wish List", path: "/wishlist", href: "/wishlist" },
    { label: "Reading Pile", path: "/reading-pile", href: "/reading-pile" },
    { label: "Looking for a Home", path: "/looking-for-home", href: "/looking-for-home" },
    { label: "Catalogue", path: "/catalogue", href: "/catalogue" },
  ];

  // Dropdown items (nested inside dropdown menus, use app-nav__dropdown-link)
  const dropdownItems = [
    { label: "Search", path: "/search", href: "/search", parent: "Catalogue" },
    { label: "Add Book", path: "/upload", href: "/upload", parent: "Catalogue" },
    { label: "Settings", path: "/settings/profile", href: "/settings/profile", parent: null },
  ];

  for (const item of topLevelItems) {
    test(`clicking "${item.label}" navigates to ${item.path}`, async ({ page }) => {
      await page.goto("/antilibrary");
      await page.waitForSelector(".app-nav__link", { timeout: 10000 });

      const navLink = page.locator(`a.app-nav__link[href="${item.href}"]`);
      await expect(navLink).toBeVisible({ timeout: 5000 });

      await navLink.click();

      await expect(page).toHaveURL(new RegExp(item.path.replace(/\//g, "\\/")), {
        timeout: 10000,
      });

      await expect(page.getByTestId('user-menu')).toBeVisible();
    });
  }

  for (const item of dropdownItems) {
    test(`clicking "${item.label}" navigates to ${item.path}`, async ({ page }) => {
      await page.goto("/antilibrary");
      await page.waitForSelector(".app-nav__link", { timeout: 10000 });

      // Hover over the parent dropdown to reveal the dropdown menu
      if (item.parent) {
        const parentLink = page.locator(`a.app-nav__link:has-text("${item.parent}")`);
        await parentLink.hover();
      } else {
        // Settings is under the user name dropdown (button-based, needs click to open)
        const userDropdown = page.getByTestId('user-menu');
        await userDropdown.click();
      }

      if (item.parent) {
        const dropdownLink = page.locator(`a.app-nav__dropdown-link[href="${item.href}"]`);
        await expect(dropdownLink).toBeVisible({ timeout: 5000 });
        await dropdownLink.click();
      } else {
        // UserMenu uses button elements with onClick, not <a> links
        const dropdownLink = page.locator('button.app-nav__dropdown-link:has-text("Settings")');
        await expect(dropdownLink).toBeVisible({ timeout: 5000 });
        await dropdownLink.click();
      }

      await expect(page).toHaveURL(new RegExp(item.path.replace(/\//g, "\\/")), {
        timeout: 10000,
      });

      await expect(page.getByTestId('user-menu')).toBeVisible();
    });
  }

  test("navigating between all shelves preserves auth state", async ({ page }) => {
    await page.goto("/antilibrary");
    await page.waitForSelector(".app-nav__link", { timeout: 10000 });

    const shelves = [
      { href: "/library", label: "Library" },
      { href: "/antilibrary", label: "Antilibrary" },
      { href: "/wishlist", label: "Wish List" },
      { href: "/reading-pile", label: "Reading Pile" },
      { href: "/looking-for-home", label: "Looking for a Home" },
    ];

    for (const shelf of shelves) {
      await page.locator(`a.app-nav__link[href="${shelf.href}"]`).click();
      await expect(page).toHaveURL(new RegExp(shelf.href.replace(/\//g, "\\/")), {
        timeout: 10000,
      });
      await expect(page.getByTestId('user-menu')).toBeVisible();
    }

    // Sign In link should NOT be visible when authenticated
    await expect(page.locator('a.app-nav__link[href="/login"]')).not.toBeVisible();
  });
});

test.describe("Navbar navigation — unauthenticated", () => {
  test("only Catalogue and Sign In are visible in nav, About under brand dropdown", async ({ page }) => {
    await page.goto("/login");

    // Elm now boots without awaiting GET /api/config, but first paint is still
    // async — `allTextContents()` does NOT auto-wait, so wait for the nav to
    // render before reading it (otherwise we read [] on a cold page).
    const navLinks = page.locator(".app-nav__link");
    await expect(navLinks.first()).toBeVisible({ timeout: 10000 });
    const texts = await navLinks.allTextContents();

    expect(texts).toContain("Catalogue");
    expect(texts).toContain("Sign In");
    expect(texts).not.toContain("Costs");
    expect(texts).not.toContain("Library");
    expect(texts).not.toContain("Add Book");
    expect(texts).not.toContain("Search");

    // Costs is no longer a nav item (#235): it lives under About, which sits in
    // the brand dropdown (About → /costs + /metrics). Assert the About link.
    const brand = page.locator(".app-header__brand");
    await brand.hover();
    await expect(page.locator('a.app-nav__dropdown-link[href="/about"]')).toBeVisible({ timeout: 3000 });
  });
});

// ── Home page (US-15.1.1) ────────────────────────────────────────────────────
// The shipped home CTAs are the #235 About/Marketplace pair (the old
// "View Antilibrary"/"Add a Book" buttons were removed). Assert the shipped
// markup — `viewHome` in Main.elm renders it identically for auth/unauth.
test.describe("Home page — unauthenticated", () => {
  test("renders the title, subtitle and About/Marketplace CTAs", async ({
    page,
  }) => {
    await page.goto("/");

    await expect(page.locator("h1.home__title")).toHaveText("The Stacks");
    await expect(page.locator("p.home__subtitle")).toHaveText(
      "Your personal collection, beautifully organised."
    );

    const about = page.locator("a.btn--primary.home__link--about");
    await expect(about).toBeVisible();
    await expect(about).toHaveText("About The Stacks");
    await expect(about).toHaveAttribute("href", "/about");

    const marketplace = page.locator("a.btn--secondary.home__link--marketplace");
    await expect(marketplace).toBeVisible();
    await expect(marketplace).toHaveText("Browse the Marketplace");
    await expect(marketplace).toHaveAttribute("href", "/marketplace");
  });
});

// ── Platform footer (US-15.3.1) ──────────────────────────────────────────────
// `viewFooter` sits in the top-level `view`, so the footer renders on EVERY
// page — home, an authenticated shelf, and the 404 page. Assert it on all three.
test.describe("Platform footer", () => {
  const FOOTER_TEXT = "The Stacks — open source book management";

  test("footer renders on the home page (unauthenticated)", async ({ page }) => {
    await page.goto("/");
    const footer = page.locator("footer.app-footer");
    await expect(footer).toBeVisible();
    await expect(footer.locator("p.app-footer__text")).toHaveText(FOOTER_TEXT);
  });

  test("footer renders on the 404 page", async ({ page }) => {
    await page.goto("/nonexistent-page");
    const footer = page.locator("footer.app-footer");
    await expect(footer).toBeVisible();
    await expect(footer.locator("p.app-footer__text")).toHaveText(FOOTER_TEXT);
  });
});

test.describe("Platform footer — authenticated", () => {
  test.use({ storageState: suiteAuthFile("navigation") });

  test("footer renders on an authenticated bookshelf page", async ({ page }) => {
    await page.goto("/library");
    // Wait for the authenticated shell to render before reading the footer.
    await expect(page.getByTestId("user-menu")).toBeVisible({ timeout: 10000 });

    const footer = page.locator("footer.app-footer");
    await expect(footer).toBeVisible();
    await expect(footer.locator("p.app-footer__text")).toHaveText(
      "The Stacks — open source book management"
    );
  });
});

// ── 404 Not Found page (US-16.1.1) ───────────────────────────────────────────
test.describe("404 Not Found page", () => {
  test("an unknown route renders the 404 page with nav, footer, title and Go Home", async ({
    page,
  }) => {
    await page.goto("/nonexistent-page");

    // Browser tab title (pageTitle NotFound).
    await expect(page).toHaveTitle("Not Found — The Stacks");

    // Page content.
    await expect(
      page.locator(".page--not-found h1")
    ).toHaveText("Page Not Found");
    await expect(page.locator(".page--not-found p")).toHaveText(
      "The page you're looking for doesn't exist."
    );

    const goHome = page.locator('.page--not-found a[href="/"]');
    await expect(goHome).toBeVisible();
    await expect(goHome).toHaveText("Go Home");

    // Nav bar and footer are still visible on the 404 page.
    await expect(page.locator("header.app-header")).toBeVisible();
    await expect(page.locator("footer.app-footer")).toBeVisible();
  });
});

// ── Swipe navigation (US-15.2.2) ─────────────────────────────────────────────
// The app.js touch listener reads touchstart `touches[0].clientX` and touchend
// `changedTouches[0].clientX`; a dx < -50 with |dx| > |dy| fires
// `onSwipe.send("left")`. Dispatch real TouchEvents (dx = -240) to drive the
// same path a mobile user's swipe takes. Requires a touch-enabled context.
test.describe("Swipe navigation — authenticated", () => {
  test.use({ hasTouch: true, storageState: suiteAuthFile("navigation") });

  async function swipeLeft(page: import("@playwright/test").Page): Promise<void> {
    await page.evaluate(() => {
      const startX = 320;
      const y = 300;
      const endX = startX - 240; // dx = -240 → "left" (well past the 50px gate)
      const mk = (x: number) =>
        new Touch({
          identifier: 1,
          target: document.body,
          clientX: x,
          clientY: y,
        });
      document.dispatchEvent(
        new TouchEvent("touchstart", {
          touches: [mk(startX)],
          changedTouches: [mk(startX)],
          bubbles: true,
        })
      );
      document.dispatchEvent(
        new TouchEvent("touchend", {
          touches: [],
          changedTouches: [mk(endX)],
          bubbles: true,
        })
      );
    });
  }

  test("swiping left on /library navigates to /antilibrary", async ({
    page,
  }) => {
    await page.goto("/library");
    // Wait for the authenticated shelf to render before gesturing.
    await expect(page.getByTestId("user-menu")).toBeVisible({ timeout: 10000 });
    await expect(page).toHaveURL(/\/library/);

    await swipeLeft(page);

    // swipeLeft advances Library → AntiLibrary via SwipeNavigation.
    await expect(page).toHaveURL(/\/antilibrary/, { timeout: 10000 });
  });

  test("swiping left on /search does not navigate (non-bookshelf route)", async ({
    page,
  }) => {
    await page.goto("/search");
    await expect(page.getByTestId("user-menu")).toBeVisible({ timeout: 10000 });
    await expect(page).toHaveURL(/\/search/);

    await swipeLeft(page);

    // Search is not a bookshelf route → SwipeNavigation returns Nothing, so the
    // gesture is a no-op. Give the port + update a beat to run, then assert the
    // URL is unchanged. (This is a genuine no-op assertion, not a vacuous guard:
    // the positive-navigation case above proves the gesture path is live.)
    await page.waitForTimeout(1000);
    await expect(page).toHaveURL(/\/search/);
  });
});

// ── Marketplace dropdown (US-15.2.1) ─────────────────────────────────────────
test.describe("Marketplace dropdown — authenticated", () => {
  test.use({ storageState: suiteAuthFile("navigation") });

  test("Marketplace dropdown reveals Create Listing and My Listings", async ({
    page,
  }) => {
    await page.goto("/library");
    await page.waitForSelector(".app-nav__link", { timeout: 10000 });

    // The Marketplace primary is a dropdown toggle (href="/marketplace"); its
    // sub-links live in a sibling menu kept display:none until hover.
    const marketplaceToggle = page.locator(
      'a.app-nav__link[href="/marketplace"]'
    );
    await expect(marketplaceToggle).toBeVisible();
    await marketplaceToggle.hover();

    const createListing = page.locator(
      'a.app-nav__dropdown-link[href="/marketplace/create"]'
    );
    await expect(createListing).toBeVisible({ timeout: 5000 });
    await expect(createListing).toHaveText("Create Listing");

    const myListings = page.locator(
      'a.app-nav__dropdown-link[href="/marketplace/mine"]'
    );
    await expect(myListings).toBeVisible();
    await expect(myListings).toHaveText("My Listings");
  });
});
