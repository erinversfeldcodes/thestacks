import { test, expect } from "@playwright/test";
import { suiteAuthFile, ensureBookOnLibrary, assertSeedOrSkip } from "./helpers";

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

    // Find an "Add to Shelf" button (only appears on unplaced books). A seed
    // gate rather than a silent guard: with E2E_EXPECT_FULL_SEEDS=1 (preview/CI)
    // the absence of an unplaced book on the first page is a HARD FAILURE — the
    // full dev-fixture seed always leaves this suite user with unplaced books —
    // while a prod-shaped/thin target skips loudly instead of passing vacuously.
    const addButton = page.locator(".catalogue__card-add").first();
    assertSeedOrSkip(
      (await addButton.count()) > 0,
      "No unplaced books visible in catalogue"
    );

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
    // Register the placements response listener BEFORE navigating so we cannot miss it.
    // Elm fetches /api/placements/mine on catalogue init; we must wait for it to complete
    // before querying .catalogue__card-add, otherwise the race condition causes us to click
    // a placed book that temporarily shows an add button while placements are still loading.
    const placementsLoaded = page.waitForResponse(
      (resp) =>
        resp.url().includes("/api/placements/mine") && resp.status() === 200,
      { timeout: 15000 }
    );

    await page.goto("/catalogue");
    await page.getByTestId("catalogue-grid").waitFor({ timeout: 10000 });

    // Wait for Elm's placements fetch to complete so maybePlacement is accurate for all cards.
    await placementsLoaded;

    // Cross-reference the rendered DOM with a fresh API call to find a card that:
    //   (a) Elm renders with .catalogue__card-add (maybePlacement = Nothing), AND
    //   (b) the /api/placements/mine endpoint also reports as unplaced.
    // This eliminates any residual inconsistency between the two data sources.
    const unplacedHref = await page.evaluate(async () => {
      const auth = JSON.parse(localStorage.getItem("stacks-auth") || "{}");
      if (!auth.token) return null;
      const resp = await fetch("/api/placements/mine", {
        headers: { Authorization: `Bearer ${auth.token}` },
      });
      const data = resp.ok ? await resp.json() : { placements: [] };
      const placedIds = new Set(
        (data.placements as Array<{ book_id: string }>).map((p) => p.book_id)
      );
      const cards = document.querySelectorAll(
        ".catalogue__card:has(.catalogue__card-add)"
      );
      for (const card of Array.from(cards)) {
        const link = card.querySelector(
          ".catalogue__card-link"
        ) as HTMLAnchorElement | null;
        if (!link) continue;
        const href = link.getAttribute("href") ?? "";
        const bookId = href.split("/books/")[1];
        if (bookId && !placedIds.has(bookId)) return href;
      }
      return null;
    });

    assertSeedOrSkip(
      unplacedHref !== null,
      "No unplaced books visible in catalogue"
    );

    await page
      .locator(`.catalogue__card-link[href="${unplacedHref}"]`)
      .click();

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
