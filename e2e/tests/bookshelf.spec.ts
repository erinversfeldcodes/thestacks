import { test, expect } from "@playwright/test";

const DEV_EMAIL = "owner@thestacks.app";
const DEV_PASSWORD = "dev-password-123";

/**
 * Helper: sign in and navigate to a bookshelf page via the SPA router
 * (preserves Elm in-memory auth state).
 */
async function signInAndNavigate(
  page: import("@playwright/test").Page,
  path: string
) {
  await page.goto("/login");
  await page.fill('input[id="email"]', DEV_EMAIL);
  await page.fill('input[id="password"]', DEV_PASSWORD);
  await page.click("button.login-form__submit");
  await page.waitForURL("/", { timeout: 10000 });
  // Navigate via SPA link or direct goto — bookshelf pages re-fetch on init
  await page.goto(path);
}

test.describe("Bookshelf pages — visual themes", () => {
  test("Library page has shelf-library class and damask wallpaper", async ({
    page,
  }) => {
    await signInAndNavigate(page, "/library");
    await expect(page.locator(".shelf-library")).toBeVisible();
    await expect(page.locator(".wallpaper--damask")).toBeVisible();
  });

  test("AntiLibrary page has shelf-antilibrary class and botanical wallpaper", async ({
    page,
  }) => {
    await signInAndNavigate(page, "/antilibrary");
    await expect(page.locator(".shelf-antilibrary")).toBeVisible();
    await expect(page.locator(".wallpaper--botanical")).toBeVisible();
  });

  test("WishList page has shelf-wishlist class and floral wallpaper", async ({
    page,
  }) => {
    await signInAndNavigate(page, "/wishlist");
    await expect(page.locator(".shelf-wishlist")).toBeVisible();
    await expect(page.locator(".wallpaper--floral")).toBeVisible();
  });
});

test.describe("Bookshelf pages — accessibility attributes", () => {
  test("Library bookshelf rows have role=list", async ({ page }) => {
    await signInAndNavigate(page, "/library");
    // Wait for content to load
    await page.waitForSelector(".shelf-library", { timeout: 10000 });
    // If books are present, check for role=list on the bookshelf row container
    const bookshelfRow = page.locator('.bookshelf__row[role="list"]');
    const emptyShelf = page.locator(".empty-shelf");
    // Either we have books with role=list rows, or an empty shelf is shown
    const hasBooks = (await bookshelfRow.count()) > 0;
    const isEmpty = (await emptyShelf.count()) > 0;
    expect(hasBooks || isEmpty).toBeTruthy();
    if (hasBooks) {
      await expect(bookshelfRow.first()).toHaveAttribute("role", "list");
    }
  });

  test("Library books have role=listitem", async ({ page }) => {
    await signInAndNavigate(page, "/library");
    await page.waitForSelector(".shelf-library", { timeout: 10000 });
    const bookItem = page.locator('.bookshelf__book[role="listitem"]');
    const emptyShelf = page.locator(".empty-shelf");
    const hasBooks = (await bookItem.count()) > 0;
    const isEmpty = (await emptyShelf.count()) > 0;
    expect(hasBooks || isEmpty).toBeTruthy();
    if (hasBooks) {
      await expect(bookItem.first()).toHaveAttribute("role", "listitem");
    }
  });

  test("Shelf labels have aria-label attribute", async ({ page }) => {
    await signInAndNavigate(page, "/library");
    await page.waitForSelector(".shelf-library", { timeout: 10000 });
    const shelfLabel = page.locator(".shelf-label");
    await expect(shelfLabel).toHaveAttribute("aria-label", /Library/);
  });

  test("Reading Pile decorative armchair has aria-hidden", async ({ page }) => {
    await signInAndNavigate(page, "/reading-pile");
    await page.waitForSelector(".shelf-reading-pile", { timeout: 10000 });
    const armchair = page.locator(".reading-nook__armchair");
    await expect(armchair).toHaveAttribute("aria-hidden", "true");
  });

  test("Reading Pile decorative rug has aria-hidden", async ({ page }) => {
    await signInAndNavigate(page, "/reading-pile");
    await page.waitForSelector(".shelf-reading-pile", { timeout: 10000 });
    const rug = page.locator(".reading-nook__rug");
    await expect(rug).toHaveAttribute("aria-hidden", "true");
  });
});

test.describe("Bookshelf pages — empty shelf hint text (US-1.6.5)", () => {
  // These tests verify the spec-mandated empty state messages.
  // They rely on fresh user accounts or empty bookshelves.
  // The hint text is in Components.EmptyBookshelf.hintText and the
  // message is passed from each page module.

  test("Library empty state matches US-1.6.5 wording", async ({ page }) => {
    await signInAndNavigate(page, "/library");
    await page.waitForSelector(".shelf-library", { timeout: 10000 });
    const emptyShelf = page.locator(".empty-shelf");
    if ((await emptyShelf.count()) > 0) {
      await expect(page.locator(".empty-shelf__message")).toContainText(
        "Your library is waiting. Move a book here when you've finished reading it."
      );
    }
  });

  test("AntiLibrary empty state matches US-1.6.5 wording", async ({
    page,
  }) => {
    await signInAndNavigate(page, "/antilibrary");
    await page.waitForSelector(".shelf-antilibrary", { timeout: 10000 });
    const emptyShelf = page.locator(".empty-shelf");
    if ((await emptyShelf.count()) > 0) {
      await expect(page.locator(".empty-shelf__message")).toContainText(
        "Books you own but haven't read yet. Upload a photo to start building your collection."
      );
    }
  });

  test("WishList empty state matches US-1.6.5 wording", async ({ page }) => {
    await signInAndNavigate(page, "/wishlist");
    await page.waitForSelector(".shelf-wishlist", { timeout: 10000 });
    const emptyShelf = page.locator(".empty-shelf");
    if ((await emptyShelf.count()) > 0) {
      await expect(page.locator(".empty-shelf__message")).toContainText(
        "Books you're dreaming about. Add one from a photo, a screenshot, or an ISBN."
      );
    }
  });

  test("Reading Pile empty state matches US-1.6.5 wording", async ({
    page,
  }) => {
    await signInAndNavigate(page, "/reading-pile");
    await page.waitForSelector(".shelf-reading-pile", { timeout: 10000 });
    const emptyShelf = page.locator(".empty-shelf");
    if ((await emptyShelf.count()) > 0) {
      await expect(page.locator(".empty-shelf__message")).toContainText(
        "Nothing on the pile right now. Move a book from your AntiLibrary to start reading."
      );
    }
  });
});
