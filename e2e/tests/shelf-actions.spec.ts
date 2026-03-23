import { test, expect } from "@playwright/test";
import { suiteAuthFile, ensureBookOnLibrary } from "./helpers";

test.use({ storageState: suiteAuthFile("shelf-actions") });

// All shelf-actions tests share the same DB user and mutate placement state.
// Serial mode prevents race conditions between describe blocks when
// fullyParallel: true is set globally.
test.describe.configure({ mode: "serial" });

test.describe("Shelf actions — move book between shelves", () => {
  test("move a book from library to wishlist via book detail overlay", async ({
    page,
  }) => {
    await ensureBookOnLibrary(page);

    // Go to the library shelf
    await page.goto("/library");
    await page.waitForSelector(".bookcase", { timeout: 10000 });

    // Click the first book to open detail overlay
    const bookButton = page.getByTestId('book-spine').first();
    await expect(bookButton).toBeAttached({ timeout: 10000 });
    await bookButton.evaluate((el) => (el as HTMLElement).click());

    // Wait for overlay to appear
    const overlay = page.getByTestId('book-overlay');
    await expect(overlay).toBeVisible({ timeout: 10000 });

    // Verify the shelf title shows "from Library"
    const shelfTitle = overlay.locator(".book-detail__section-title", {
      hasText: "Move to Shelf from Library",
    });
    await expect(shelfTitle).toBeVisible({ timeout: 5000 });

    // Open the shelf mover
    await overlay.locator('button:has-text("Choose Bookshelf")').click();
    await expect(overlay.locator(".shelf-mover")).toBeVisible();

    // Select Wish List from the dropdown
    await overlay.getByTestId('shelf-mover-select').selectOption("wishlist");

    // Click Move (exact match to avoid matching "Remove")
    await overlay.locator('button:text-is("Move")').click();

    // Wait for success message
    await expect(
      overlay.locator(".book-detail__status--success")
    ).toBeVisible({ timeout: 5000 });

    // Verify the title updated to show "from Wish List"
    const updatedTitle = overlay.locator(".book-detail__section-title", {
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
    await page.getByTestId('catalogue-grid').waitFor({ timeout: 10000 });

    // Wait for placements to load (badges appear)
    await page.waitForTimeout(1000);

    // Count initial badges
    const initialBadges = await page.locator(".catalogue__card-badge").count();

    // Find an "Add to Shelf" button (only appears on unplaced books)
    const addButton = page.locator(".catalogue__card-add").first();
    test.skip((await addButton.count()) === 0, "No unplaced books visible in catalogue");

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

test.describe("Shelf actions — add unplaced book from detail overlay", () => {
  test("open an unplaced book detail overlay and add to collection", async ({
    page,
  }) => {
    // Find an unplaced book via API (reliable, no UI race conditions)
    await page.goto("/catalogue");
    const unplacedBookId = await page.evaluate(async () => {
      const auth = JSON.parse(localStorage.getItem("stacks-auth") || "{}");
      const placementsResp = await fetch("/api/placements/mine", {
        headers: { Authorization: `Bearer ${auth.token}` },
      });
      const placementsData = placementsResp.ok
        ? await placementsResp.json()
        : { placements: [] };
      const placedIds = new Set(
        placementsData.placements.map((p: any) => p.book_id)
      );
      const catResp = await fetch("/api/catalogue?per_page=200");
      const catData = await catResp.json();
      const book = catData.books.find((b: any) => !placedIds.has(b.id));
      return book?.id ?? null;
    });

    test.skip(!unplacedBookId, "No unplaced books available in catalogue");

    // Open the unplaced book's detail via the catalogue overlay
    await page.getByTestId('catalogue-grid').waitFor({ timeout: 10000 });
    const cardLink = page.locator(`.catalogue__card-link[href="/books/${unplacedBookId}"]`).first();
    if (await cardLink.count() > 0) {
      await cardLink.click();
    } else {
      // Fallback: click any card link for an unplaced book
      await page.locator(".catalogue__card-link").first().click();
    }

    const overlay = page.getByTestId('book-overlay');
    await expect(overlay).toBeVisible({ timeout: 10000 });

    // Should NOT show "Remove from collection" (book is unplaced)
    await expect(
      overlay.locator('button:has-text("Remove from collection")')
    ).not.toBeVisible();

    // Should show "Add to Collection"
    const addSection = overlay.locator(".book-detail__section-title", {
      hasText: "Add to Collection",
    });
    await expect(addSection).toBeVisible({ timeout: 10000 });

    // Click "Choose Bookshelf"
    await overlay.locator('button:has-text("Choose Bookshelf")').click();
    await expect(overlay.locator(".shelf-mover")).toBeVisible();

    // Select "Antilibrary" and click Move (which triggers ConfirmPlace)
    await overlay.getByTestId('shelf-mover-select').selectOption("antilibrary");
    await overlay.getByTestId('shelf-mover-btn').click();

    // Should show success and switch to "Move to Shelf from Antilibrary"
    await expect(
      overlay.locator(".book-detail__status--success")
    ).toBeVisible({ timeout: 5000 });
    await expect(
      overlay.locator(".book-detail__section-title", {
        hasText: "Move to Shelf from Antilibrary",
      })
    ).toBeVisible();
  });
});

test.describe("Shelf actions — remove book from collection", () => {
  test("remove button only visible when book has a placement", async ({
    page,
  }) => {
    await ensureBookOnLibrary(page);
    await page.goto("/library");
    await page.waitForSelector(".bookcase", { timeout: 10000 });

    const bookButton = page.getByTestId('book-spine').first();
    await expect(bookButton).toBeVisible({ timeout: 10000 });
    await bookButton.evaluate((el) => (el as HTMLElement).click());

    const overlay = page.getByTestId('book-overlay');
    await expect(overlay).toBeVisible({ timeout: 10000 });

    // The remove button should be visible since the book is placed
    await expect(
      overlay.locator('button:has-text("Remove from collection")')
    ).toBeVisible({ timeout: 5000 });
  });

  test("remove button triggers modal and confirm removes the book", async ({
    page,
  }) => {
    await ensureBookOnLibrary(page);
    await page.goto("/library");
    await page.waitForSelector(".bookcase", { timeout: 10000 });

    const bookButton = page.getByTestId('book-spine').first();
    await expect(bookButton).toBeVisible({ timeout: 10000 });
    await bookButton.evaluate((el) => (el as HTMLElement).click());

    const overlay = page.getByTestId('book-overlay');
    await expect(overlay).toBeVisible({ timeout: 10000 });

    // Click remove
    await overlay.locator('button:has-text("Remove from collection")').click();

    // Modal should appear (may be outside the dialog overlay)
    await expect(page.getByTestId('remove-book-modal')).toBeVisible({ timeout: 3000 });

    // Click "Remove" in the modal (not "Keep It")
    const confirmBtn = page.getByTestId('remove-book-confirm');
    await expect(confirmBtn).toBeVisible();
    await confirmBtn.click();

    // Overlay should close and we should be back on the library page
    await expect(overlay).not.toBeVisible({ timeout: 10000 });
    await expect(page).toHaveURL(/\/library/, { timeout: 10000 });
  });
});
