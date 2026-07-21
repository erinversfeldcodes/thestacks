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
    await page.getByTestId('reading-pile-page').waitFor({ timeout: 10000 });
    const armchair = page.locator(".armchair");
    await expect(armchair).toHaveAttribute("aria-hidden", "true");
  });

  test("Reading Pile decorative floor has aria-hidden", async ({ page }) => {
    await page.goto("/reading-pile");
    await page.getByTestId('reading-pile-page').waitFor({ timeout: 10000 });
    const floor = page.locator(".reading-pile__floor");
    await expect(floor).toHaveAttribute("aria-hidden", "true");
  });
});

test.describe("Bookshelf pages — empty shelf hint text (US-1.6.5)", () => {
  // The `empty-shelves` suite user is seeded with five bookshelves and ZERO
  // placements (`Seeds.e2e_empty_suites/0`), so every empty state below renders
  // deterministically and is asserted unconditionally — no `count() > 0` guard.
  test.use({ storageState: suiteAuthFile("empty-shelves") });

  // A zero-placement user is exactly who `shouldShowOnboarding` (Main.elm:2845)
  // targets, so the first-run overlay would cover the very shelves under test.
  // The seed marks this user onboarded; this hook fails loudly if that regresses
  // rather than letting the assertions pass against an obscured page.
  test.afterEach(async ({ page }) => {
    await expect(page.getByTestId("onboarding-overlay")).toHaveCount(0);
  });

  test("Library empty state matches US-1.6.5 wording", async ({ page }) => {
    await page.goto("/library");
    await page.waitForSelector(".shelf-library", { timeout: 10000 });
    const emptyText = page.locator(".shelf-row__empty-text");
    await expect(emptyText).toContainText(
      "Your library is waiting. Move a book here when you've finished reading it.",
      { timeout: 10000 }
    );
  });

  test("AntiLibrary empty state matches US-1.6.5 wording", async ({
    page,
  }) => {
    await page.goto("/antilibrary");
    await page.waitForSelector(".shelf-antilibrary", { timeout: 10000 });
    const emptyText = page.locator(".shelf-row__empty-text");
    await expect(emptyText).toContainText(
      "Books you own but haven't read yet. Upload a photo to start building your collection.",
      { timeout: 10000 }
    );
  });

  test("WishList empty state matches US-1.6.5 wording", async ({ page }) => {
    await page.goto("/wishlist");
    await page.waitForSelector(".shelf-wishlist", { timeout: 10000 });
    const emptyText = page.locator(".shelf-row__empty-text");
    await expect(emptyText).toContainText(
      "Books you're dreaming about. Add one from a photo, a screenshot, or an ISBN.",
      { timeout: 10000 }
    );
  });

  test("Reading Pile empty state matches US-1.6.5 wording", async ({
    page,
  }) => {
    await page.goto("/reading-pile");
    await page.getByTestId('reading-pile-page').waitFor({ timeout: 10000 });
    const emptyMsg = page.locator(".reading-pile__empty-msg");
    await expect(emptyMsg).toContainText(
      "Nothing on the pile right now. Move a book from your Antilibrary to start reading.",
      { timeout: 15000 }
    );
  });

  test("Looking for a Home empty state matches US-1.6.5 wording", async ({
    page,
  }) => {
    await page.goto("/looking-for-home");
    await page.getByTestId('looking-for-home-page').waitFor({ timeout: 10000 });
    // Looking-for-Home is the only page using Components.EmptyBookshelf.
    // Note the en dash in the copy (LookingForHome.elm:102).
    await expect(page.locator(".empty-shelf__message")).toContainText(
      "Nothing here yet — these are books looking for a new home.",
      { timeout: 10000 }
    );
  });
});
