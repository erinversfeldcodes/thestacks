import { expect, test } from "@playwright/test";

/**
 * Following a link puts you at the top of the next page.
 *
 * ⛔ Nothing in the app makes this happen. There is no `Browser.Dom.setViewport`
 * anywhere in `frontend/src`, and `Nav.pushUrl` does not reset scroll either.
 * It holds because a route change swaps the page content, and the destination's
 * DOM is briefly short enough that the browser clamps the carried offset to
 * zero before the new content grows. That is incidental, not designed — which
 * is exactly why it is worth pinning: the day someone makes the swap preserve
 * height, a reader will start landing mid-page and no unit test would notice.
 *
 * The residue ledger carried this as an open defect ("scroll is STILL not reset")
 * on the strength of a console reading taken in a hidden Chrome tab, where the
 * Elm view is frozen by suspended rAF and every measurement is meaningless. A
 * real browser says otherwise. An earlier `setViewport` fix was written, shipped
 * and reverted for "claiming a behaviour it did not deliver"; a second one was
 * written while closing this out and deleted unshipped, because the behaviour
 * was already there and the code would have taken credit for it.
 *
 * ⚠️ Two ways this spec could pass while proving nothing, both guarded inline:
 * a full page load (resets scroll natively, exercising none of the app), and a
 * destination too short to hold the carried offset (clamps to 0 regardless).
 * The first version of this spec had both.
 *
 * Public routes only — no auth needed, so it runs anywhere the app is served.
 */
test.describe("scroll on navigation", () => {
  test("following a link from deep in a long page lands at the top", async ({ page }) => {
    await page.goto("/architecture");

    // The defect is only observable if the page is genuinely long: the browser
    // clamps a carried-over offset to the destination's height, so on a short
    // page the bug hides itself.
    const height = await page.evaluate(() => document.body.scrollHeight);
    expect(height, "the essay must be long enough for the carried offset to show").toBeGreaterThan(2000);

    await page.evaluate(() => window.scrollTo(0, 1500));
    await expect.poll(() => page.evaluate(() => Math.round(window.scrollY))).toBe(1500);

    // Plant a marker on window. A FULL page load destroys it — and a full load
    // resets scroll natively, which would make this test pass without the app
    // doing anything. The first version of this spec did exactly that.
    await page.evaluate(() => {
      (window as unknown as { __spa: boolean }).__spa = true;
    });

    await page.getByRole("link", { name: /about/i }).first().click();
    await page.waitForURL("**/about");

    // Wait for the destination to actually render before reading the offset —
    // reading too early measures the old page.
    await expect(page.locator("h1")).not.toHaveText(/free lunch/i);

    const stayedInApp = await page.evaluate(
      () => (window as unknown as { __spa?: boolean }).__spa === true,
    );
    expect(stayedInApp, "this must be an in-app route change, not a full page load").toBe(true);

    // And the destination must be tall enough to HOLD the carried offset,
    // or the browser clamps it to 0 and the assertion below is vacuous.
    const destHeight = await page.evaluate(() => document.body.scrollHeight - window.innerHeight);
    expect(destHeight, "destination must be scrollable past the carried offset").toBeGreaterThan(1500);

    await expect
      .poll(() => page.evaluate(() => Math.round(window.scrollY)), {
        message: "a new route should start at the top, not at the previous page's offset",
      })
      .toBe(0);
  });

  test("an in-page anchor jump is left alone", async ({ page }) => {
    // The reset must key on the ROUTE, not on every UrlChanged: the fragment
    // moving is how in-page anchors work, and resetting there would fight them.
    await page.goto("/architecture");
    await page.evaluate(() => window.scrollTo(0, 1200));
    await expect.poll(() => page.evaluate(() => Math.round(window.scrollY))).toBe(1200);

    await page.evaluate(() => {
      history.pushState({}, "", "/architecture#somewhere");
      window.dispatchEvent(new PopStateEvent("popstate"));
    });

    await expect
      .poll(() => page.evaluate(() => Math.round(window.scrollY)), {
        message: "a fragment change is not a route change and must not reset scroll",
      })
      .toBe(1200);
  });
});
