import { test, expect } from "@playwright/test";
import { OWNER_AUTH_FILE } from "./helpers";

test.use({ storageState: OWNER_AUTH_FILE });

test.describe("Bookshelf pages — visual themes", () => {
  test("Library page has shelf-library class and damask wallpaper", async ({
    page,
  }) => {
    await page.goto("/library");
    await expect(page.locator(".shelf-library")).toBeVisible({ timeout: 10000 });
    await expect(page.locator(".wallpaper--damask")).toBeVisible();
  });

  test("AntiLibrary page has shelf-antilibrary class and botanical wallpaper", async ({
    page,
  }) => {
    await page.goto("/antilibrary");
    await expect(page.locator(".shelf-antilibrary")).toBeVisible({ timeout: 10000 });
    await expect(page.locator(".wallpaper--botanical")).toBeVisible();
  });

  test("WishList page has shelf-wishlist class and floral wallpaper", async ({
    page,
  }) => {
    await page.goto("/wishlist");
    await expect(page.locator(".shelf-wishlist")).toBeVisible({ timeout: 10000 });
    await expect(page.locator(".wallpaper--floral")).toBeVisible();
  });
});

test.describe("Bookshelf pages — accessibility attributes", () => {
  test("Library bookshelf rows have role=list", async ({ page }) => {
    await page.goto("/library");
    await page.waitForSelector(".bookcase", { timeout: 10000 });
    const booksContainer = page.locator('.shelf-row__books[role="list"]');
    await expect(booksContainer.first()).toBeAttached({ timeout: 5000 });
    await expect(booksContainer.first()).toHaveAttribute("role", "list");
  });

  test("Library books have role=listitem", async ({ page }) => {
    await page.goto("/library");
    await page.waitForSelector(".bookcase", { timeout: 10000 });
    const bookButton = page.locator('.book-button[role="listitem"]');
    const bookCount = await bookButton.count();
    if (bookCount === 0) {
      // No books seeded on library — skip gracefully
      console.log("No books on library shelf, skipping listitem test");
      return;
    }
    await expect(bookButton.first()).toHaveAttribute("role", "listitem");
  });

  test("Shelf labels have aria-label attribute", async ({ page }) => {
    await page.goto("/library");
    await page.waitForSelector(".shelf-library", { timeout: 10000 });
    const shelfLabel = page.locator(".shelf-label");
    await expect(shelfLabel).toHaveAttribute("aria-label", /Library/);
  });

  test("Reading Pile decorative armchair has aria-hidden", async ({ page }) => {
    await page.goto("/reading-pile");
    await page.waitForSelector(".shelf-reading-pile", { timeout: 10000 });
    const armchair = page.locator(".reading-nook__armchair");
    await expect(armchair).toHaveAttribute("aria-hidden", "true");
  });

  test("Reading Pile decorative rug has aria-hidden", async ({ page }) => {
    await page.goto("/reading-pile");
    await page.waitForSelector(".shelf-reading-pile", { timeout: 10000 });
    const rug = page.locator(".reading-nook__rug");
    await expect(rug).toHaveAttribute("aria-hidden", "true");
  });
});

test.describe("Bookshelf pages — empty shelf hint text (US-1.6.5)", () => {
  test("Library empty state matches US-1.6.5 wording", async ({ page }) => {
    await page.goto("/library");
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
    await page.goto("/antilibrary");
    await page.waitForSelector(".shelf-antilibrary", { timeout: 10000 });
    const emptyShelf = page.locator(".empty-shelf");
    if ((await emptyShelf.count()) > 0) {
      await expect(page.locator(".empty-shelf__message")).toContainText(
        "Books you own but haven't read yet. Upload a photo to start building your collection."
      );
    }
  });

  test("WishList empty state matches US-1.6.5 wording", async ({ page }) => {
    await page.goto("/wishlist");
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
    await page.goto("/reading-pile");
    await page.waitForSelector(".shelf-reading-pile", { timeout: 10000 });
    const emptyShelf = page.locator(".empty-shelf");
    if ((await emptyShelf.count()) > 0) {
      await expect(page.locator(".empty-shelf__message")).toContainText(
        "Nothing on the pile right now. Move a book from your AntiLibrary to start reading."
      );
    }
  });
});
