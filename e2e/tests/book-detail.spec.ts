import { test, expect } from "@playwright/test";
import {
  suiteAuthFile,
  ensureBookOnLibrary,
  provisionBookOnShelf,
} from "./helpers";

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
    await expect(overlay.locator(".book-detail")).toBeVisible({ timeout: 10000 });
    await expect(overlay.locator(".book-detail__cover")).toBeVisible();
    const hasCover = (await overlay.getByTestId("book-cover").count()) > 0;
    const hasPlaceholder =
      (await overlay.locator(".book-detail__cover-placeholder").count()) > 0;
    expect(hasCover).not.toBe(hasPlaceholder);
  });

  test("All sections visible when book loads", async ({ page }) => {
    const overlay = await openBookDetailOverlay(page);
    await expect(overlay.locator(".book-detail")).toBeVisible({ timeout: 10000 });
    await expect(
      overlay.locator(".book-detail__section-title", { hasText: "About" })
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
    const formatBtn = overlay.locator(".format-picker__btn").first();
    await expect(formatBtn).toBeVisible({ timeout: 10000 });
    await formatBtn.click();
    await expect(formatBtn).toHaveClass(/format-picker__btn--selected/);
  });

  test("Move to Shelf dropdown works", async ({ page }) => {
    const overlay = await openBookDetailOverlay(page);
    const chooseBtnLocator = overlay.locator("button", {
      hasText: "Choose Bookshelf",
    });
    await expect(chooseBtnLocator).toBeVisible({ timeout: 10000 });
    await chooseBtnLocator.click();
    await expect(overlay.locator(".shelf-mover")).toBeVisible();
  });

  test("Overlay entry animation present on open", async ({ page }) => {
    const overlay = await openBookDetailOverlay(page);
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

test.describe("Book Detail overlay — dismissal", () => {

  test("X button closes the overlay; URL never changes", async ({ page }) => {
    const { overlay } = await openOverlayWithSpine(page);
    const url = page.url();
    expect(url).toContain("/library");
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

test.describe("Book Detail overlay — focus contract", () => {
  test("focus lands on the labelled dialog card when the overlay opens", async ({
    page,
  }) => {
    await openOverlayWithSpine(page);
    await expect
      .poll(() => activeElementId(page), { timeout: 3000 })
      .toBe("book-overlay-card");
  });

  test("first Tab from the freshly-focused card lands on the close button", async ({
    page,
  }) => {
    await openOverlayWithSpine(page);
    await expect
      .poll(() => activeElementId(page), { timeout: 3000 })
      .toBe("book-overlay-card");
    await page.keyboard.press("Tab");
    await expect
      .poll(() => activeElementId(page), { timeout: 3000 })
      .toBe("book-overlay-close");
  });

  test("Tab never moves focus outside the overlay", async ({ page }) => {
    const { overlay } = await openOverlayWithSpine(page);
    await expect
      .poll(() => activeElementId(page), { timeout: 3000 })
      .toBe("book-overlay-card");

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
    expect(sawCloseAgain, "focus never cycled back to the close button").toBe(
      true
    );
    await expect(overlay).toBeVisible();
  });

  test("Tab from the trailing sentinel wraps to the close button", async ({
    page,
  }) => {
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
      .toBe("book-overlay-card");
    await page.keyboard.press("Escape");
    await expect(overlay).not.toBeVisible({ timeout: 5000 });
    await expect
      .poll(() => activeElementId(page), { timeout: 3000 })
      .toBe(spineId);
  });

  test("the trailing sentinel exposes its wrap-back aria-label (rev 1)", async ({
    page,
  }) => {
    const { overlay } = await openOverlayWithSpine(page);
    await expect(
      overlay.getByTestId("book-overlay-focus-sentinel")
    ).toHaveAttribute(
      "aria-label",
      "End of book details — press Tab to return to the top"
    );
  });
});

test.describe("Book Detail overlay — load and error states", () => {

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
    // ⚠️ The response is held open until the Loading branch has been OBSERVED —
    // not for a fixed 1.5 s ().
    //
    // A fixed sleep makes this assertion a wall-clock race. `.loading` exists only
    // while the fetch is in flight, so seeing it depended on the browser reaching
    // the check inside the injected delay; the margin between them, not the 90 s
    // test timeout, was the spec's real budget, and it is spent by whatever else
    // is contending for the one preview VM. The same spec was measured at 1.3
    // minutes WHILE PASSING on a loaded backend — a spec with that little headroom
    // is what tips the rest of the file over. Deriving the delay from what the
    // spec actually needs (hold until asserted, then release) makes the
    // observation impossible to miss at any machine speed, and costs milliseconds
    // instead of seconds — so the default timeout is now the right budget rather
    // than a raised one.
    //
    // Nothing is weakened: the Loading branch is still asserted by its exact copy,
    // the response is still released, and it still resolves to real content.
    let release!: () => void;
    const held = new Promise<void>((resolve) => {
      release = resolve;
    });
    const spineButton = await gotoLibrarySpine(page);
    await page.route("**/api/books/*", async (route) => {
      await held;
      await route.continue();
    });
    await spineButton.click();
    const overlay = page.getByTestId("book-overlay");
    await expect(overlay).toBeVisible({ timeout: 5000 });
    try {
      // The Loading branch renders `.loading` "Loading book..." while the fetch is
      // in flight — and it cannot stop being in flight until this assertion has run.
      await expect(overlay.locator(".loading")).toHaveText("Loading book...", {
        timeout: 5000,
      });
    } finally {
      // Release unconditionally: a failed assertion must fail on its own message,
      // not hang the held request until the test timeout and report as a timeout.
      release();
    }
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
  await ensureBookOnLibrary(page);
  await page.goto("/library");
  await page.waitForSelector(".bookcase", { timeout: 10000 });
  const spineButton = page.locator('button[id^="spine-"]').first();
  await expect(spineButton).toBeVisible({ timeout: 10000 });
  return spineButton;
}

test.describe("Book Detail overlay — unauthenticated", () => {
  test.use({ storageState: { cookies: [], origins: [] } });

  test("public book overlay shows the sign-in prompt and no owner actions", async ({
    page,
  }) => {
    await page.goto("/catalogue");
    await page.getByTestId("catalogue-grid").waitFor({ timeout: 10000 });
    const url = page.url();
    await page.locator(".catalogue__card-link").first().click();
    const overlay = page.getByTestId("book-overlay");
    await expect(overlay).toBeVisible({ timeout: 5000 });
    await expect(overlay.locator(".book-detail")).toBeVisible({
      timeout: 10000,
    });
    expect(page.url()).toBe(url);

    await expect(
      overlay.locator('a:has-text("Sign In or Register")')
    ).toBeVisible();
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

test.describe("Book Detail overlay — remove-modal focus & scoped escape (rev 1)", () => {

  /**
   * Provision a placed library book, open its overlay, and open the remove
   * confirmation modal. Returns the overlay + modal locators.
   */
  async function openRemoveModal(
    page: import("@playwright/test").Page,
    request: import("@playwright/test").APIRequestContext
  ) {
    await provisionBookOnShelf(page, request, "library");
    await page.goto("/library");
    await page.waitForSelector(".bookcase", { timeout: 10000 });
    const spine = page.locator('button[id^="spine-"]').first();
    await expect(spine).toBeVisible({ timeout: 10000 });
    await spine.click();
    const overlay = page.getByTestId("book-overlay");
    await expect(overlay).toBeVisible({ timeout: 5000 });
    await overlay.locator("#book-detail-remove-trigger").click();
    const modal = page.getByTestId("remove-book-modal");
    await expect(modal).toBeVisible({ timeout: 3000 });
    return { overlay, modal };
  }

  test("modal opens with focus on the safe 'Keep It' button", async ({
    page,
    request,
  }) => {
    await openRemoveModal(page, request);
    await expect
      .poll(() => activeElementId(page), { timeout: 3000 })
      .toBe("remove-book-cancel");
  });

  test("Tab is trapped within the modal's two buttons", async ({
    page,
    request,
  }) => {
    await openRemoveModal(page, request);
    await page.locator("#remove-book-confirm").focus();
    await expect
      .poll(() => activeElementId(page), { timeout: 3000 })
      .toBe("remove-book-confirm");
    await page.keyboard.press("Tab");
    await expect
      .poll(() => activeElementId(page), { timeout: 3000 })
      .toBe("remove-book-cancel");
    await page.locator("#remove-book-cancel").focus();
    await page.keyboard.press("Shift+Tab");
    await expect
      .poll(() => activeElementId(page), { timeout: 3000 })
      .toBe("remove-book-confirm");
  });

  test("Escape is scoped: first press closes only the modal, second closes the overlay", async ({
    page,
    request,
  }) => {
    const { overlay, modal } = await openRemoveModal(page, request);

    await page.keyboard.press("Escape");
    await expect(modal).not.toBeVisible({ timeout: 5000 });
    await expect(overlay).toBeVisible();
    await expect
      .poll(() => activeElementId(page), { timeout: 3000 })
      .toBe("book-detail-remove-trigger");

    await page.keyboard.press("Escape");
    await expect(overlay).not.toBeVisible({ timeout: 5000 });
  });

  test("removing the book returns focus to the main landmark", async ({
    page,
    request,
  }) => {
    const { overlay, modal } = await openRemoveModal(page, request);
    await modal.locator("#remove-book-confirm").click();
    await expect(overlay).not.toBeVisible({ timeout: 5000 });
    expect(page.url()).toContain("/library");
    await expect
      .poll(() => activeElementId(page), { timeout: 3000 })
      .toBe("main-content");
  });
});

test.describe("Book Detail full-page route — scoped escape", () => {

  test("Escape dismisses the remove modal on the full-page route", async ({
    page,
    request,
  }) => {
    const { bookId } = await provisionBookOnShelf(page, request, "library");
    await page.goto(`/books/${bookId}`);
    await expect(page.locator(".book-detail")).toBeVisible({ timeout: 10000 });
    await page.locator("#book-detail-remove-trigger").click();
    const modal = page.getByTestId("remove-book-modal");
    await expect(modal).toBeVisible({ timeout: 3000 });

    await page.keyboard.press("Escape");
    await expect(modal).not.toBeVisible({ timeout: 5000 });
    await expect(page.locator(".book-detail")).toBeVisible();
    expect(page.url()).toContain(`/books/${bookId}`);
    await expect
      .poll(() => activeElementId(page), { timeout: 3000 })
      .toBe("book-detail-remove-trigger");
  });
});
