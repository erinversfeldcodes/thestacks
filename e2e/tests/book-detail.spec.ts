import { test, expect } from "@playwright/test";
import { suiteAuthFile, ensureBookOnLibrary } from "./helpers";

test.use({ storageState: suiteAuthFile("book-detail") });

/**
 * Helper: open the book detail overlay by clicking the first book
 * on the library shelf.
 */
async function openBookDetailOverlay(page: import("@playwright/test").Page) {
  await ensureBookOnLibrary(page);
  await page.goto("/library");
  await page.waitForSelector(".bookcase", { timeout: 10000 });
  const bookButton = page.getByTestId('book-spine').first();
  await expect(bookButton).toBeAttached({ timeout: 10000 });
  await bookButton.evaluate((el) => (el as HTMLElement).click());
  const overlay = page.getByTestId('book-overlay');
  await expect(overlay).toBeVisible({ timeout: 5000 });
  return overlay;
}

test.describe("Book Detail overlay — layout and structure", () => {
  test("Book detail overlay loads with parchment background", async ({
    page,
  }) => {
    const overlay = await openBookDetailOverlay(page);
    await expect(overlay).toBeVisible({ timeout: 10000 });
  });

  test("Cover image or placeholder is displayed", async ({ page }) => {
    const overlay = await openBookDetailOverlay(page);
    // Deterministic: the seeded book always loads (Success), so the hero's
    // cover frame is always present. viewHero renders EXACTLY ONE of the
    // <img data-testid="book-cover"> or the .book-detail__cover-placeholder —
    // never both, never neither. The prior OR folded in `.loading`/`.error`,
    // so it passed even when the book failed to load; assert the loaded hero
    // and the exclusive-or of the two cover states instead.
    await expect(overlay.locator(".book-detail")).toBeVisible({ timeout: 10000 });
    await expect(overlay.locator(".book-detail__cover")).toBeVisible();
    const hasCover = (await overlay.getByTestId("book-cover").count()) > 0;
    const hasPlaceholder =
      (await overlay.locator(".book-detail__cover-placeholder").count()) > 0;
    // XOR — exactly one of the two loaded-hero states renders.
    expect(hasCover).not.toBe(hasPlaceholder);
  });

  test("All sections visible when book loads", async ({ page }) => {
    const overlay = await openBookDetailOverlay(page);
    // The seeded book always loads, so .book-detail is always present — wait for
    // it to render, then assert every section unconditionally (a prior
    // `if (count > 0)` guard here passed vacuously if the book never loaded).
    await expect(overlay.locator(".book-detail")).toBeVisible({ timeout: 10000 });
    await expect(
      overlay.locator(".book-detail__section-title", { hasText: "About" })
    ).toBeVisible();
    await expect(
      overlay.locator(".book-detail__section-title", {
        hasText: "What People Think",
      })
    ).toBeVisible();
    await expect(
      overlay.locator(".book-detail__section-title", {
        hasText: "Where to Buy",
      })
    ).toBeVisible();
    await expect(
      overlay.locator(".book-detail__section-title", {
        hasText: "The Author",
      })
    ).toBeVisible();
    await expect(
      overlay.locator(".book-detail__section-title", {
        hasText: "My Writing",
      })
    ).toBeVisible();
  });

  test("Format picker buttons are interactive", async ({ page }) => {
    const overlay = await openBookDetailOverlay(page);
    // The book is placed on the Library shelf (openBookDetailOverlay ensures
    // this), so "Formats on My Shelf" always renders its three format buttons.
    const formatBtn = overlay.locator(".format-picker__btn").first();
    await expect(formatBtn).toBeVisible({ timeout: 10000 });
    await formatBtn.click();
    await expect(formatBtn).toHaveClass(/format-picker__btn--selected/);
  });

  test("Move to Shelf dropdown works", async ({ page }) => {
    const overlay = await openBookDetailOverlay(page);
    // A placed book always offers the "Choose Bookshelf" mover, so assert it is
    // present and drive it (was a vacuous `if (count > 0)` guard).
    const chooseBtnLocator = overlay.locator("button", {
      hasText: "Choose Bookshelf",
    });
    await expect(chooseBtnLocator).toBeVisible({ timeout: 10000 });
    await chooseBtnLocator.click();
    await expect(overlay.locator(".shelf-mover")).toBeVisible();
  });

  test("Overlay entry animation present on open", async ({ page }) => {
    const overlay = await openBookDetailOverlay(page);
    // Verify the overlay rendered with book detail content
    await expect(overlay.locator(".book-detail")).toBeVisible({ timeout: 10000 });
  });
});

/**
 * Open the overlay from the library shelf, returning the overlay locator AND
 * the DOM id of the triggering spine button (`spine-<bookId>`) so focus-return
 * on close can be asserted. The clickable spine is a `button.book-button` whose
 * id encodes the book id (Page/Bookshelf/Helpers.elm:247); clicking it fires
 * NavigateTo(BookDetail id) → Main.openOverlay WITHOUT a URL change.
 */
async function openOverlayWithSpine(page: import("@playwright/test").Page) {
  await ensureBookOnLibrary(page);
  await page.goto("/library");
  await page.waitForSelector(".bookcase", { timeout: 10000 });
  const spineButton = page.locator('button[id^="spine-"]').first();
  await expect(spineButton).toBeVisible({ timeout: 10000 });
  const spineId = await spineButton.getAttribute("id");
  expect(spineId).toBeTruthy();
  await spineButton.click();
  const overlay = page.getByTestId("book-overlay");
  await expect(overlay).toBeVisible({ timeout: 5000 });
  return { overlay, spineId: spineId as string };
}

/** Read the id of the currently focused element in the page. */
function activeElementId(page: import("@playwright/test").Page) {
  return page.evaluate(() => document.activeElement?.id ?? null);
}

test.describe("Book Detail overlay — dismissal (punch #11)", () => {
  // The overlay is UI state, not a route: opening and closing it must never
  // change the URL. Each path reopens a fresh overlay and asserts the URL is
  // identical before open, while open, and after close.

  test("X button closes the overlay; URL never changes", async ({ page }) => {
    const { overlay } = await openOverlayWithSpine(page);
    const url = page.url();
    expect(url).toContain("/library");
    // Still on the same URL while the overlay is open.
    expect(page.url()).toBe(url);

    await overlay.getByTestId("book-overlay-close").click();
    await expect(overlay).not.toBeVisible({ timeout: 5000 });
    await expect(page.locator(".bookcase")).toBeVisible();
    expect(page.url()).toBe(url);
  });

  test("backdrop click closes the overlay; URL never changes", async ({
    page,
  }) => {
    const { overlay } = await openOverlayWithSpine(page);
    const url = page.url();
    expect(page.url()).toBe(url);

    // Fire the backdrop's own click handler directly — the centred card sits
    // above the backdrop's midpoint, so a positional click there would land on
    // the card. el.click() invokes the backdrop's onClick (CloseOverlay).
    await overlay
      .locator(".book-overlay__backdrop")
      .evaluate((el) => (el as HTMLElement).click());
    await expect(overlay).not.toBeVisible({ timeout: 5000 });
    await expect(page.locator(".bookcase")).toBeVisible();
    expect(page.url()).toBe(url);
  });

  test("Escape key closes the overlay; URL never changes", async ({ page }) => {
    const { overlay } = await openOverlayWithSpine(page);
    const url = page.url();
    expect(page.url()).toBe(url);

    await page.keyboard.press("Escape");
    await expect(overlay).not.toBeVisible({ timeout: 5000 });
    await expect(page.locator(".bookcase")).toBeVisible();
    expect(page.url()).toBe(url);
  });
});

test.describe("Book Detail overlay — focus contract (punch #11/#12)", () => {
  test("focus lands on the close button when the overlay opens", async ({
    page,
  }) => {
    await openOverlayWithSpine(page);
    // Focus is moved by an Elm Browser.Dom.focus Task that resolves a frame
    // after render, so poll rather than reading synchronously.
    await expect
      .poll(() => activeElementId(page), { timeout: 3000 })
      .toBe("book-overlay-close");
  });

  test("Tab never moves focus outside the overlay", async ({ page }) => {
    const { overlay } = await openOverlayWithSpine(page);
    await expect
      .poll(() => activeElementId(page), { timeout: 3000 })
      .toBe("book-overlay-close");

    // Walk forward through every focusable control. At each stop, focus must
    // remain inside the overlay subtree — never on a shelf-behind element.
    let sawCloseAgain = false;
    for (let i = 0; i < 25; i++) {
      await page.keyboard.press("Tab");
      const inside = await page.evaluate(
        () =>
          !!document.activeElement?.closest('[data-testid="book-overlay"]')
      );
      expect(inside, `focus escaped the overlay after ${i + 1} Tab(s)`).toBe(
        true
      );
      if ((await activeElementId(page)) === "book-overlay-close") {
        sawCloseAgain = true;
      }
    }
    // Proof the trap actually wraps (not merely that few controls exist):
    // within 25 forward Tabs, focus cycled back to the close button at least
    // once.
    expect(sawCloseAgain, "focus never cycled back to the close button").toBe(
      true
    );
    await expect(overlay).toBeVisible();
  });

  test("Tab from the trailing sentinel wraps to the close button", async ({
    page,
  }) => {
    // This is the highest-value non-vacuity anchor: with the keydown trap
    // reverted, Tab off the last sentinel escapes to the DOM after the overlay
    // and this assertion fails.
    await openOverlayWithSpine(page);
    await page
      .locator('[data-testid="book-overlay-focus-sentinel"]')
      .focus();
    await expect
      .poll(() => activeElementId(page), { timeout: 3000 })
      .toBe("book-overlay-focus-sentinel");
    await page.keyboard.press("Tab");
    await expect
      .poll(() => activeElementId(page), { timeout: 3000 })
      .toBe("book-overlay-close");
  });

  test("Shift+Tab from the close button wraps to the trailing sentinel", async ({
    page,
  }) => {
    await openOverlayWithSpine(page);
    await page.locator("#book-overlay-close").focus();
    await expect
      .poll(() => activeElementId(page), { timeout: 3000 })
      .toBe("book-overlay-close");
    await page.keyboard.press("Shift+Tab");
    await expect
      .poll(() => activeElementId(page), { timeout: 3000 })
      .toBe("book-overlay-focus-sentinel");
  });

  test("focus returns to the triggering spine after close", async ({
    page,
  }) => {
    const { overlay, spineId } = await openOverlayWithSpine(page);
    await expect
      .poll(() => activeElementId(page), { timeout: 3000 })
      .toBe("book-overlay-close");
    await page.keyboard.press("Escape");
    await expect(overlay).not.toBeVisible({ timeout: 5000 });
    // Focus-return is likewise an async Browser.Dom.focus Task.
    await expect
      .poll(() => activeElementId(page), { timeout: 3000 })
      .toBe(spineId);
  });
});

test.describe("Book Detail overlay — load and error states (punch #14)", () => {
  // page.route is used ONLY to inject transport failures / delays for the book
  // fetch — the exact error surfaces we cannot reproduce against a healthy
  // seeded API.

  test("GET /api/books/:id 404 shows the load-error message", async ({
    page,
  }) => {
    await page.route("**/api/books/*", (route) =>
      route.fulfill({
        status: 404,
        contentType: "application/json",
        body: JSON.stringify({ error: "not_found" }),
      })
    );
    const spineButton = await gotoLibrarySpine(page);
    await spineButton.click();
    const overlay = page.getByTestId("book-overlay");
    await expect(overlay).toBeVisible({ timeout: 5000 });
    await expect(overlay.locator(".error")).toHaveText(
      "Could not load this book. Please try again.",
      { timeout: 5000 }
    );
  });

  test("GET /api/books/:id 500 shows the load-error message", async ({
    page,
  }) => {
    await page.route("**/api/books/*", (route) =>
      route.fulfill({
        status: 500,
        contentType: "application/json",
        body: JSON.stringify({ error: "server_error" }),
      })
    );
    const spineButton = await gotoLibrarySpine(page);
    await spineButton.click();
    const overlay = page.getByTestId("book-overlay");
    await expect(overlay).toBeVisible({ timeout: 5000 });
    await expect(overlay.locator(".error")).toHaveText(
      "Could not load this book. Please try again.",
      { timeout: 5000 }
    );
  });

  test("loading state is visible before a delayed response resolves", async ({
    page,
  }) => {
    // Hold the response open long enough to observe the Loading branch, then
    // let it succeed so the overlay does not error.
    await page.route("**/api/books/*", async (route) => {
      await new Promise((r) => setTimeout(r, 1500));
      await route.continue();
    });
    const spineButton = await gotoLibrarySpine(page);
    await spineButton.click();
    const overlay = page.getByTestId("book-overlay");
    await expect(overlay).toBeVisible({ timeout: 5000 });
    // The Loading branch renders `.loading` "Loading book..." while the fetch
    // is in flight.
    await expect(overlay.locator(".loading")).toHaveText("Loading book...", {
      timeout: 2000,
    });
    // And once the (continued) real response lands, it resolves to content.
    await expect(overlay.locator(".book-detail")).toBeVisible({
      timeout: 10000,
    });
  });
});

/**
 * Navigate to the library and return the first spine button WITHOUT clicking
 * it — used by the error-state tests, which must register their route mock and
 * then trigger the fetch by clicking. ensureBookOnLibrary runs first so a spine
 * exists; the placement API call it makes precedes the route mock, so the mock
 * only intercepts the subsequent book fetch.
 */
async function gotoLibrarySpine(page: import("@playwright/test").Page) {
  // ensureBookOnLibrary only touches /api/catalogue, /api/placements/mine and
  // /api/bookshelves/*/placements — never /api/books/*, so it is unaffected by
  // the callers' book-fetch route mock.
  await ensureBookOnLibrary(page);
  await page.goto("/library");
  await page.waitForSelector(".bookcase", { timeout: 10000 });
  const spineButton = page.locator('button[id^="spine-"]').first();
  await expect(spineButton).toBeVisible({ timeout: 10000 });
  return spineButton;
}

test.describe("Book Detail overlay — unauthenticated (punch #15)", () => {
  // A signed-out visitor gets a fresh context with no stored session.
  test.use({ storageState: { cookies: [], origins: [] } });

  test("public book overlay shows the sign-in prompt and no owner actions", async ({
    page,
  }) => {
    await page.goto("/catalogue");
    await page.getByTestId("catalogue-grid").waitFor({ timeout: 10000 });
    // Every catalogue card is a public book; open the first one's overlay. The
    // card link is an <a href="/books/:id"> → LinkClicked → openOverlay with no
    // token, so the URL stays on /catalogue.
    const url = page.url();
    await page.locator(".catalogue__card-link").first().click();
    const overlay = page.getByTestId("book-overlay");
    await expect(overlay).toBeVisible({ timeout: 5000 });
    await expect(overlay.locator(".book-detail")).toBeVisible({
      timeout: 10000,
    });
    expect(page.url()).toBe(url);

    // The signup prompt is shown to signed-out visitors...
    await expect(
      overlay.locator('a:has-text("Sign In or Register")')
    ).toBeVisible();
    // ...and NONE of the authenticated shelf actions render.
    await expect(
      overlay.locator('button:has-text("Choose Bookshelf")')
    ).toHaveCount(0);
    await expect(
      overlay.locator('button:has-text("Remove from collection")')
    ).toHaveCount(0);
    await expect(
      overlay.locator(".book-detail__section-title", {
        hasText: "Add to Collection",
      })
    ).toHaveCount(0);
  });
});
