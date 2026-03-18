import { test, expect } from "@playwright/test";
import { suiteAuthFile, ensureBookOnLibrary } from "./helpers";

test.use({ storageState: suiteAuthFile("bookshelf") });

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
    await ensureBookOnLibrary(page);
    await page.goto("/library");
    await page.waitForSelector(".bookcase", { timeout: 10000 });
    const bookButton = page.locator('.book-button[role="listitem"]');
    await expect(bookButton.first()).toBeVisible({ timeout: 10000 });
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
    const armchair = page.locator(".armchair");
    await expect(armchair).toHaveAttribute("aria-hidden", "true");
  });

  test("Reading Pile decorative floor has aria-hidden", async ({ page }) => {
    await page.goto("/reading-pile");
    await page.waitForSelector(".shelf-reading-pile", { timeout: 10000 });
    const floor = page.locator(".reading-pile__floor");
    await expect(floor).toHaveAttribute("aria-hidden", "true");
  });
});

test.describe("Bookshelf pages — empty shelf hint text (US-1.6.5)", () => {
  test("Library empty state matches US-1.6.5 wording", async ({ page }) => {
    await page.goto("/library");
    await page.waitForSelector(".shelf-library", { timeout: 10000 });
    const emptyText = page.locator(".shelf-row__empty-text");
    if ((await emptyText.count()) > 0) {
      await expect(emptyText).toContainText(
        "Your library is waiting"
      );
    }
  });

  test("AntiLibrary empty state matches US-1.6.5 wording", async ({
    page,
  }) => {
    await page.goto("/antilibrary");
    await page.waitForSelector(".shelf-antilibrary", { timeout: 10000 });
    const emptyText = page.locator(".shelf-row__empty-text");
    if ((await emptyText.count()) > 0) {
      await expect(emptyText).toContainText(
        "Books you own but haven't read yet"
      );
    }
  });

  test("WishList empty state matches US-1.6.5 wording", async ({ page }) => {
    await page.goto("/wishlist");
    await page.waitForSelector(".shelf-wishlist", { timeout: 10000 });
    const emptyText = page.locator(".shelf-row__empty-text");
    if ((await emptyText.count()) > 0) {
      await expect(emptyText).toContainText(
        "Books you're dreaming about"
      );
    }
  });

  test("Reading Pile empty state matches US-1.6.5 wording", async ({
    page,
  }) => {
    await page.goto("/reading-pile");
    await page.waitForSelector(".shelf-reading-pile", { timeout: 10000 });
    // Wait for loading to finish — either books appear or the empty message shows
    await page.waitForFunction(
      () => {
        const loading = document.querySelector(".loading");
        const loadingMsg = document.querySelector(".reading-pile__empty-msg");
        const isLoading =
          loading !== null ||
          (loadingMsg !== null &&
            loadingMsg.textContent?.includes("Loading"));
        return !isLoading;
      },
      { timeout: 15000 }
    );
    const emptyMsg = page.locator(".reading-pile__empty-msg");
    if ((await emptyMsg.count()) > 0) {
      await expect(emptyMsg).toContainText(
        "Nothing on the pile right now"
      );
    }
  });
});
