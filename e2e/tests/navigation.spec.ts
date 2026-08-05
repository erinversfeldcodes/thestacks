import { test, expect, type Page } from "@playwright/test";
import { suiteAuthFile } from "./helpers";

/**
 * Open a top-level nav disclosure (Bookshelves / Marketplace / Admin) by its
 * label (#318 TR-1). The Wave 8 nav replaced the CSS `:hover`/`:focus-within`
 * reveal — which was unreachable by touch — with a real
 * `<button class="app-nav__disclosure" aria-haspopup aria-expanded>` whose menu
 * is in the DOM ONLY once it is clicked open. Idempotent: a navigation does NOT
 * reset `openNavMenu`, so a disclosure can already be open on entry — click only
 * when it is closed, then assert it is open.
 */
async function openNavDisclosure(page: Page, label: string): Promise<void> {
  const trigger = page.locator(
    `button.app-nav__disclosure:has-text("${label}")`
  );
  await expect(trigger).toBeVisible({ timeout: 5000 });
  if ((await trigger.getAttribute("aria-expanded")) !== "true") {
    await trigger.click();
  }
  await expect(trigger).toHaveAttribute("aria-expanded", "true");
}

// The five bookshelves — top-level links on the OLD nav, now dropdown links
// inside the Bookshelves disclosure (#318 TR-1). `href` doubles as the exact
// pathname each dropdown link points at.
const bookshelves = [
  { label: "Library", href: "/library" },
  { label: "Antilibrary", href: "/antilibrary" },
  { label: "Wish List", href: "/wishlist" },
  { label: "Reading Pile", href: "/reading-pile" },
  { label: "Looking for a Home", href: "/looking-for-home" },
];

test.describe("Navbar navigation — authenticated", () => {
  test.use({ storageState: suiteAuthFile("navigation") });

  // The five bookshelves are reached by OPENING the Bookshelves disclosure and
  // clicking the dropdown link — they are no longer top-level `app-nav__link`s.
  for (const shelf of bookshelves) {
    test(`opening Bookshelves → "${shelf.label}" navigates to ${shelf.href}`, async ({
      page,
    }) => {
      await page.goto("/antilibrary");
      await page.waitForSelector(".app-nav__link", { timeout: 10000 });

      await openNavDisclosure(page, "Bookshelves");

      const shelfLink = page.locator(
        `a.app-nav__dropdown-link[href="${shelf.href}"]`
      );
      await expect(shelfLink).toBeVisible({ timeout: 5000 });
      await shelfLink.click();

      // Exact pathname match via a predicate (a dynamically-built RegExp trips
      // semgrep's non-literal-regexp rule, blocking in `just ci`).
      await expect(page).toHaveURL((url) => url.pathname === shelf.href, {
        timeout: 10000,
      });
      await expect(page.getByTestId("user-menu")).toBeVisible();
    });
  }

  // Search is a top-level destination now (#318 TR-1), not buried in a menu.
  test('clicking "Search" navigates to /search', async ({ page }) => {
    await page.goto("/antilibrary");
    await page.waitForSelector(".app-nav__link", { timeout: 10000 });

    const searchLink = page.locator('a.app-nav__link[href="/search"]');
    await expect(searchLink).toBeVisible({ timeout: 5000 });
    await searchLink.click();

    await expect(page).toHaveURL((url) => url.pathname === "/search", {
      timeout: 10000,
    });
    await expect(page.getByTestId("user-menu")).toBeVisible();
  });

  // Add Book is a PERSISTENT primary action (#318 TR-1): always in the DOM,
  // reachable on touch, never behind a disclosure.
  test('clicking "Add Book" navigates to /upload', async ({ page }) => {
    await page.goto("/antilibrary");
    await page.waitForSelector(".app-nav__link", { timeout: 10000 });

    const addBook = page.locator('a.app-nav__add-book[href="/upload"]');
    await expect(addBook).toBeVisible({ timeout: 5000 });
    await addBook.click();

    await expect(page).toHaveURL((url) => url.pathname === "/upload", {
      timeout: 10000,
    });
    await expect(page.getByTestId("user-menu")).toBeVisible();
  });

  // The settings family now lives in the account/user menu (#318 TR-1) — a
  // button-based dropdown that opens on click. "Profile" is the first entry and
  // points at /settings/profile (the destination the old "Settings" item used).
  test('opening the account menu → "Profile" navigates to /settings/profile', async ({
    page,
  }) => {
    await page.goto("/antilibrary");
    await page.waitForSelector(".app-nav__link", { timeout: 10000 });

    await page.getByTestId("user-menu").click();
    const profile = page.locator(
      'button.app-nav__dropdown-link:has-text("Profile")'
    );
    await expect(profile).toBeVisible({ timeout: 5000 });
    await profile.click();

    await expect(page).toHaveURL((url) => url.pathname === "/settings/profile", {
      timeout: 10000,
    });
    await expect(page.getByTestId("user-menu")).toBeVisible();
  });

  test("navigating between all shelves preserves auth state", async ({ page }) => {
    await page.goto("/antilibrary");
    await page.waitForSelector(".app-nav__link", { timeout: 10000 });

    for (const shelf of bookshelves) {
      await openNavDisclosure(page, "Bookshelves");
      const shelfLink = page.locator(
        `a.app-nav__dropdown-link[href="${shelf.href}"]`
      );
      await expect(shelfLink).toBeVisible({ timeout: 5000 });
      await shelfLink.click();
      await expect(page).toHaveURL((url) => url.pathname === shelf.href, {
        timeout: 10000,
      });
      await expect(page.getByTestId("user-menu")).toBeVisible();
    }

    // Sign In link should NOT be visible when authenticated
    await expect(page.locator('a.app-nav__link[href="/login"]')).not.toBeVisible();
  });
});

test.describe("Navbar navigation — unauthenticated", () => {
  test("shows Catalogue, Search, Marketplace, About and Sign In as top-level links", async ({
    page,
  }) => {
    await page.goto("/login");

    // Elm now boots without awaiting GET /api/config, but first paint is still
    // async — `allTextContents()` does NOT auto-wait, so wait for the nav to
    // render before reading it (otherwise we read [] on a cold page).
    const navLinks = page.locator(".app-nav__link");
    await expect(navLinks.first()).toBeVisible({ timeout: 10000 });
    const texts = await navLinks.allTextContents();

    // The Wave 8 unauth nav (#318) is a flat row of top-level links.
    expect(texts).toContain("Catalogue");
    expect(texts).toContain("Search");
    expect(texts).toContain("Marketplace");
    expect(texts).toContain("About");
    expect(texts).toContain("Sign In");

    // Authenticated-only surfaces are absent for a signed-out visitor.
    expect(texts).not.toContain("Bookshelves");
    expect(texts).not.toContain("Add Book");

    // About is a top-level nav item (no brand dropdown any more) → /about.
    await expect(page.locator('a.app-nav__link[href="/about"]')).toBeVisible();
    // And there is no disclosure trigger at all in the unauth nav.
    await expect(page.locator("button.app-nav__disclosure")).toHaveCount(0);
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

    // Browser tab title (`Main.pageTitle PageNotFound` — derived from the page
    // that was built, not from the route that was asked for, since #360).
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

  test("Marketplace disclosure reveals Browse, Create Listing and My Listings", async ({
    page,
  }) => {
    await page.goto("/library");
    await page.waitForSelector(".app-nav__link", { timeout: 10000 });

    // The Marketplace primary is a disclosure BUTTON now (#318 TR-1) — clicked
    // open, not hovered; its sub-links are absent from the DOM until then.
    await openNavDisclosure(page, "Marketplace");

    const browse = page.locator(
      'a.app-nav__dropdown-link[href="/marketplace"]'
    );
    await expect(browse).toBeVisible({ timeout: 5000 });
    await expect(browse).toHaveText("Browse");

    const createListing = page.locator(
      'a.app-nav__dropdown-link[href="/marketplace/create"]'
    );
    await expect(createListing).toBeVisible();
    await expect(createListing).toHaveText("Create Listing");

    const myListings = page.locator(
      'a.app-nav__dropdown-link[href="/marketplace/mine"]'
    );
    await expect(myListings).toBeVisible();
    await expect(myListings).toHaveText("My Listings");
  });
});
