import { test, expect } from "@playwright/test";

/**
 * Arriving at a new page should put you at the top of it.
 *
 * In a single-page app the browser does not reset the scroll position for you:
 * the document never changes, so a reader who scrolls halfway down the
 * catalogue and then follows a link lands halfway down the next page, usually
 * in the middle of a paragraph with the heading somewhere above them.
 *
 * This is asserted in a real browser rather than by counting `window.scroll`
 * calls. An earlier attempt at this measured the call count from the console
 * and read zero, which turned out to say nothing — the console-driven click was
 * performing a full page load, giving a fresh document and a fresh counter
 * every time. Reading the scroll position after a genuine in-app navigation is
 * the thing the reader actually experiences, and it cannot be faked by the
 * measurement.
 *
 * Note on how the reset currently happens: nothing in the app calls
 * `setViewport`. A routed page paints a short loading state first, which
 * collapses the document below the viewport, and the browser clamps the offset
 * to zero on its own. That is incidental rather than designed — it holds only
 * while every routed destination starts short. No navigation between two
 * instantly-rendered pages exists in the UI today (the static pages do not link
 * to each other), so there is nothing to assert about that case yet; if one is
 * ever added, this is the test that should grow a second case.
 */

test.use({ storageState: { cookies: [], origins: [] } });

/** Scroll far enough down that landing at this offset would be obvious. */
async function scrollDown(page: import("@playwright/test").Page) {
  await page.evaluate(() => window.scrollTo(0, 1200));
  const y = await page.evaluate(() => window.scrollY);
  expect(y, "the page must be scrollable for this test to mean anything").toBeGreaterThan(0);
  return y;
}

test.describe("Scroll position on navigation", () => {
  test("following a link lands at the top of the new page", async ({ page }) => {
    await page.goto("/catalogue");
    await expect(page.getByTestId("catalogue-grid")).toBeVisible({
      timeout: 15000,
    });

    await scrollDown(page);

    // Plant a marker on the window. If it survives the click, the navigation
    // really was in-app; if it is gone, the browser reloaded the document and
    // reset the scroll for us — which would make this whole test vacuous.
    await page.evaluate(() => {
      (window as unknown as { __spaMarker?: number }).__spaMarker = 1;
    });

    await page.getByRole("link", { name: "About", exact: true }).first().click();
    await expect(page).toHaveURL(/\/about$/);

    const stayedInApp = await page.evaluate(
      () => (window as unknown as { __spaMarker?: number }).__spaMarker === 1,
    );
    expect(stayedInApp, "navigation was a document load, not an SPA transition").toBe(true);

    // And the destination has to be tall enough to HOLD a scroll offset,
    // otherwise landing at 0 says nothing about any reset.
    const room = await page.evaluate(
      () => document.documentElement.scrollHeight - window.innerHeight,
    );
    expect(room, "destination is too short to preserve a scroll offset").toBeGreaterThan(600);
    await expect(
      page.getByRole("heading", { name: "About The Stacks" })
    ).toBeVisible();

    await expect
      .poll(() => page.evaluate(() => window.scrollY), { timeout: 5000 })
      .toBe(0);
  });
});
