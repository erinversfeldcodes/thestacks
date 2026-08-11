import { test, expect, type Page } from "@playwright/test";
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

test.describe("Bookshelf pages — bookcase structure (US-1.2.1/2/3)", () => {

  test.afterEach(async ({ page }) => {
    await expect(page.getByTestId("onboarding-overlay")).toHaveCount(0);
    await expect(page.locator(".shelf-label")).toBeVisible();
  });

  test("Library renders the lamplight overlay as a real gradient", async ({
    page,
  }) => {
    await page.goto("/library");
    await page.waitForSelector(".shelf-library", { timeout: 10000 });

    const lighting = page.locator(".lighting");
    await expect(lighting).toHaveCount(1);
    const styles = await lighting.evaluate((el) => {
      const s = getComputedStyle(el);
      return { backgroundImage: s.backgroundImage, blend: s.mixBlendMode };
    });
    expect(styles.backgroundImage).toContain("radial-gradient");
    expect(styles.blend).toBe("soft-light");
  });

  test("Library bookcase has 3D side panels and >= 4 shelf rows inside its inner frame", async ({
    page,
  }) => {
    await page.goto("/library");
    await page.waitForSelector(".bookcase", { timeout: 10000 });

    await expect(page.locator(".bookcase__side--left")).toHaveCount(1);
    await expect(page.locator(".bookcase__side--right")).toHaveCount(1);
    await expect(page.locator(".bookcase__inner")).toHaveCount(1);

    const rowsInInner = page.locator(".bookcase__inner .shelf-row");
    expect(await rowsInInner.count()).toBeGreaterThanOrEqual(4);
    expect(await page.locator(".shelf-row").count()).toBe(
      await rowsInInner.count()
    );
  });

  test("Library shelf rows pack books without overflowing the bookcase", async ({
    page,
  }) => {
    await ensureBookOnLibrary(page);
    await page.goto("/library");
    await page.locator(".book-button").first().waitFor({ timeout: 10000 });

    const rows = page.locator(".shelf-row__books");
    const rowCount = await rows.count();
    expect(rowCount).toBeGreaterThanOrEqual(4);

    for (let i = 0; i < rowCount; i++) {
      const metrics = await rows.nth(i).evaluate((el) => {
        const bottoms = Array.from(el.querySelectorAll(".book-button")).map(
          (b) => (b as HTMLElement).offsetTop + (b as HTMLElement).offsetHeight
        );
        return {
          scrollWidth: el.scrollWidth,
          clientWidth: el.clientWidth,
          distinctBottoms: new Set(bottoms).size,
        };
      });
      expect(metrics.scrollWidth).toBeLessThanOrEqual(metrics.clientWidth);
      expect(metrics.distinctBottoms).toBeLessThanOrEqual(1);
    }
  });

  test("AntiLibrary shelf label reads Antilibrary and the bookcase has >= 4 rows", async ({
    page,
  }) => {
    await page.goto("/antilibrary");
    await page.waitForSelector(".shelf-antilibrary", { timeout: 10000 });

    await expect(page.locator(".shelf-label")).toHaveAttribute(
      "aria-label",
      "Antilibrary"
    );
    expect(
      await page.locator(".bookcase__inner .shelf-row").count()
    ).toBeGreaterThanOrEqual(4);
  });

  test("WishList shelf label reads Wish List and the bookcase has >= 4 rows", async ({
    page,
  }) => {
    await page.goto("/wishlist");
    await page.waitForSelector(".shelf-wishlist", { timeout: 10000 });

    await expect(page.locator(".shelf-label")).toHaveAttribute(
      "aria-label",
      "Wish List"
    );
    expect(
      await page.locator(".bookcase__inner .shelf-row").count()
    ).toBeGreaterThanOrEqual(4);
  });
});

test.describe("Bookshelf pages — view mode toggle and list sorting", () => {
  const titlesInOrder = (page: Page) =>
    page.locator(".book-list__row td:nth-child(1)").allTextContents();

  test("view-mode-toggle switches the bookcase to a sortable list view", async ({
    page,
  }) => {
    await ensureBookOnLibrary(page);
    await page.goto("/library");
    await page.locator(".book-button").first().waitFor({ timeout: 10000 });

    const toggle = page.locator(".view-mode-toggle");
    await expect(toggle).toBeVisible();
    await expect(
      toggle.getByRole("button", { name: "Spine view" })
    ).toHaveAttribute("aria-pressed", "true");
    await expect(page.locator(".book-list")).toHaveCount(0);

    await toggle.getByRole("button", { name: "List view" }).click();

    await expect(page.locator(".bookcase")).toHaveCount(0);
    await expect(page.locator(".bookshelf--list-view .book-list")).toBeVisible();
    await expect(
      toggle.getByRole("button", { name: "List view" })
    ).toHaveAttribute("aria-pressed", "true");

    const headerLabels = await page
      .locator(".book-list thead th")
      .evaluateAll((ths) => ths.map((th) => th.firstChild?.textContent ?? ""));
    expect(headerLabels).toEqual([
      "Title",
      "Author",
      "Pages",
      "Date Added",
      "Formats",
    ]);
    expect(await page.locator(".book-list__row").count()).toBeGreaterThan(0);
  });

  test("clicking a column header sorts the list and toggles Asc <-> Desc", async ({
    page,
  }) => {
    await ensureBookOnLibrary(page);
    await page.goto("/library");
    await page.locator(".book-button").first().waitFor({ timeout: 10000 });
    await page
      .locator(".view-mode-toggle")
      .getByRole("button", { name: "List view" })
      .click();
    await expect(page.locator(".book-list")).toBeVisible();

    const titleHeader = page.locator(".book-list thead th", {
      hasText: "Title",
    });
    const authorHeader = page.locator(".book-list thead th", {
      hasText: "Author",
    });

    await expect(titleHeader).toHaveAttribute("aria-sort", "ascending");
    const asc = await titlesInOrder(page);
    expect(asc.length).toBeGreaterThan(1);
    expect(asc).toEqual(
      [...asc].sort((a, b) => a.toLowerCase().localeCompare(b.toLowerCase()))
    );

    await titleHeader.click();
    await expect(titleHeader).toHaveAttribute("aria-sort", "descending");
    expect(await titlesInOrder(page)).toEqual([...asc].reverse());

    await titleHeader.click();
    await expect(titleHeader).toHaveAttribute("aria-sort", "ascending");
    expect(await titlesInOrder(page)).toEqual(asc);

    await authorHeader.click();
    await expect(authorHeader).toHaveAttribute("aria-sort", "ascending");
    await expect(titleHeader).toHaveAttribute("aria-sort", "none");
    const byAuthor = await page
      .locator(".book-list__row td:nth-child(2)")
      .allTextContents();
    expect(byAuthor).toEqual(
      [...byAuthor].sort((a, b) =>
        a.toLowerCase().localeCompare(b.toLowerCase())
      )
    );
  });
});

test.describe("Bookshelf pages — error state", () => {
  test("a 500 from the library endpoint surfaces the retry message", async ({
    page,
  }) => {
    await page.route("**/api/bookshelves/library*", (route) =>
      route.fulfill({
        status: 500,
        contentType: "application/json",
        body: "{}",
      })
    );

    await page.goto("/library");
    await page.waitForSelector(".shelf-library", { timeout: 10000 });

    await expect(page.locator("p.error")).toContainText(
      "Could not load your library. Please try again.",
      { timeout: 10000 }
    );
    await expect(page.locator(".bookcase")).toHaveCount(0);
  });
});

test.describe("Bookshelf pages — empty shelf hint text (US-1.6.5)", () => {
  test.use({ storageState: suiteAuthFile("empty-shelves") });

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
    await expect(page.locator(".empty-shelf__message")).toContainText(
      "Nothing here yet — these are books looking for a new home.",
      { timeout: 10000 }
    );
  });
});
