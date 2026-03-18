import { test, expect } from "@playwright/test";
import { OWNER_AUTH_FILE } from "./helpers";

test.use({ storageState: OWNER_AUTH_FILE });

test.describe("Shelf actions — move book between shelves", () => {
  test("move a book from library to wishlist via book detail", async ({
    page,
  }) => {
    // Go to the library shelf
    await page.goto("/library");
    await page.waitForSelector(".bookcase", { timeout: 10000 });

    // Click the first book to open detail
    const bookButton = page.locator(".book-button").first();
    if ((await bookButton.count()) === 0) {
      console.log("No books on library — skipping");
      return;
    }
    await bookButton.evaluate((el) => (el as HTMLElement).click());

    // Wait for book detail to load
    await page.waitForSelector(".book-detail__parchment", { timeout: 10000 });

    // Verify the shelf title shows "from Library"
    const shelfTitle = page.locator(".book-detail__section-title", {
      hasText: "Move to Shelf from Library",
    });
    await expect(shelfTitle).toBeVisible({ timeout: 5000 });

    // Open the shelf mover
    await page.click('button:has-text("Choose Bookshelf")');
    await expect(page.locator(".shelf-mover")).toBeVisible();

    // Select Wish List from the dropdown
    await page.selectOption(".shelf-mover__select", "wishlist");

    // Click Move
    await page.click('button:has-text("Move")');

    // Wait for success message
    await expect(
      page.locator(".book-detail__status--success")
    ).toBeVisible({ timeout: 5000 });

    // Verify the title updated to show "from Wish List"
    const updatedTitle = page.locator(".book-detail__section-title", {
      hasText: "Move to Shelf from Wish List",
    });
    await expect(updatedTitle).toBeVisible();
  });
});

test.describe("Shelf actions — add book from catalogue", () => {
  test("add an unplaced book to a shelf from the catalogue", async ({
    page,
  }) => {
    await page.goto("/catalogue");
    await page.waitForSelector(".catalogue__grid", { timeout: 10000 });

    // Wait for placements to load (badges appear)
    await page.waitForTimeout(1000);

    // Count initial badges
    const initialBadges = await page.locator(".catalogue__card-badge").count();

    // Find an "Add to Shelf" button (only appears on unplaced books)
    const addButton = page.locator(".catalogue__card-add").first();
    if ((await addButton.count()) === 0) {
      console.log("No unplaced books visible — skipping");
      return;
    }

    // Click "Add to Shelf" to open the picker
    await addButton.click();

    // The shelf picker should appear
    await expect(
      page.locator(".catalogue__card-picker").first()
    ).toBeVisible({ timeout: 3000 });

    // Click "Library" in the picker
    await page
      .locator('.catalogue__card-picker-option:has-text("Library")')
      .first()
      .click();

    // Wait for the API call to complete and badge to appear
    await page.waitForTimeout(2000);

    // Badge count should have increased
    const finalBadges = await page.locator(".catalogue__card-badge").count();
    expect(finalBadges).toBeGreaterThanOrEqual(initialBadges + 1);
  });
});

test.describe("Shelf actions — add unplaced book from detail page", () => {
  test("filter to unplaced books, open detail, and add to collection", async ({
    page,
  }) => {
    // Go to catalogue and filter to unplaced books
    await page.goto("/catalogue");
    await page.waitForSelector(".catalogue__grid", { timeout: 10000 });
    await page.waitForTimeout(1000);

    // Click "Not in my collection" filter
    await page.click('button:has-text("Not in my collection")');
    await page.waitForTimeout(500);

    // All visible cards should have "Add to Shelf" (no badges)
    await expect(page.locator(".catalogue__card-badge")).toHaveCount(0);

    // Click the first book card link to navigate to its detail page
    const firstCard = page.locator(".catalogue__card-link").first();
    await firstCard.click();

    // Wait for book detail to load
    await page.waitForSelector(".book-detail__parchment", { timeout: 10000 });

    // Should NOT show "Remove from collection" (book is unplaced)
    await expect(
      page.locator('button:has-text("Remove from collection")')
    ).not.toBeVisible();

    // Should show "Add to Collection"
    const addSection = page.locator(".book-detail__section-title", {
      hasText: "Add to Collection",
    });
    await expect(addSection).toBeVisible({ timeout: 5000 });

    // Click "Choose Bookshelf"
    await page.click('button:has-text("Choose Bookshelf")');
    await expect(page.locator(".shelf-mover")).toBeVisible();

    // Select "Antilibrary" and click Move (which triggers ConfirmPlace)
    await page.selectOption(".shelf-mover__select", "antilibrary");
    await page.click('.shelf-mover__btn:has-text("Move")');

    // Should show success and switch to "Move to Shelf from Antilibrary"
    await expect(
      page.locator(".book-detail__status--success")
    ).toBeVisible({ timeout: 5000 });
    await expect(
      page.locator(".book-detail__section-title", {
        hasText: "Move to Shelf from Antilibrary",
      })
    ).toBeVisible();
  });
});

test.describe("Shelf actions — remove book from collection", () => {
  test("remove button only visible when book has a placement", async ({
    page,
  }) => {
    // Navigate to a book from the library (has placement)
    await page.goto("/library");
    await page.waitForSelector(".bookcase", { timeout: 10000 });

    const bookButton = page.locator(".book-button").first();
    if ((await bookButton.count()) === 0) {
      console.log("No books on library — skipping");
      return;
    }
    await bookButton.evaluate((el) => (el as HTMLElement).click());
    await page.waitForSelector(".book-detail__parchment", { timeout: 10000 });

    // The remove button should be visible since the book is placed
    await expect(
      page.locator('button:has-text("Remove from collection")')
    ).toBeVisible({ timeout: 5000 });
  });

  test("remove button triggers modal and confirm removes the book", async ({
    page,
  }) => {
    await page.goto("/library");
    await page.waitForSelector(".bookcase", { timeout: 10000 });

    const bookButton = page.locator(".book-button").first();
    if ((await bookButton.count()) === 0) {
      console.log("No books on library — skipping");
      return;
    }
    await bookButton.evaluate((el) => (el as HTMLElement).click());
    await page.waitForSelector(".book-detail__parchment", { timeout: 10000 });

    // Click remove
    await page.click('button:has-text("Remove from collection")');

    // Modal should appear
    await expect(page.locator(".modal-overlay")).toBeVisible({ timeout: 3000 });

    // Click "Remove" in the modal (not "Keep It")
    const confirmBtn = page.locator('.modal__actions button.btn--danger:has-text("Remove")');
    await expect(confirmBtn).toBeVisible();
    await confirmBtn.click();

    // Should navigate back to the library
    await page.waitForURL("**/library", { timeout: 10000 });
  });
});
