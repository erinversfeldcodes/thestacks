import { test, expect } from "@playwright/test";
import type { APIRequestContext, Page } from "@playwright/test";
import {
  ensureBookOnShelf,
  uniqueEmail,
  mintOrSkip,
  injectSession,
} from "./helpers";

/**
 * Browser E2E for per-placement visibility on the book-detail overlay
 * (US-10.2.2 "Override Placement Visibility", Issue #122 punch #16).
 *
 * Covers the placement-visibility surface shipped by:
 *   - #194 frontend  — the "Who can see this book" dropdown + ceiling greying,
 *                      and the faint/hidden owner-only spine on the shelf.
 *   - #201 serializer — `visibility` + `bookshelf_visibility` on the placement
 *                       payload, which seed the select's current value + ceiling.
 *   - #202 polish    — the "Members" label (wire value stays `platform`), the
 *                      ceiling HELPER TEXT below the select (not a per-option
 *                      tooltip — browsers don't render `title` on disabled
 *                      <option>s), and optimistic rollback on a failed save.
 *
 * Server-side visibility enforcement is well-covered at the Elixir layer
 * (visibility_test.exs + controller tests); this fills the browser-flow gap the
 * #122 audit flagged: a UI regression that renders a hidden placement, drops the
 * "Members" relabel, or greys the wrong option would slip every current test.
 *
 * REAL API — no route mocking. Assertions are driven against the live stack.
 *
 * ISOLATED THROWAWAY USER (Issue #208): a fresh user per test. These flows mutate
 * profile + shelf + placement visibility, and `privacy.spec` / `settings.spec`
 * mutate the SAME state on the seeded `settings` user in parallel — that race
 * (a concurrent spec tightening the profile to `owner` forces every shelf to
 * `owner` and disables the options this test needs) intermittently broke the
 * faint-spine test. A dedicated user removes all sharing. `setShelfCeiling`
 * loosens the fresh user's profile (default `owner`) to `platform` first so a
 * `public`/`platform` shelf is within the ceiling; `ensureBookOnShelf` places a
 * book (and suppresses the placement-free onboarding overlay).
 */

test.describe.configure({ mode: "serial" });

const SHELF = "library";

/**
 * Mint an isolated, confirmed throwaway user via POST /api/test/session
 * (Issue #280) and inject its session so `page` holds a live session — outside
 * the `:auth` rate bucket, so this non-auth-testing spec no longer competes with
 * the parallel suite. `test.skip`s cleanly when the helper is off
 * (STACKS_E2E_TEST_HELPERS).
 */
async function landAsFreshUser(page: Page, request: APIRequestContext): Promise<void> {
  const session = await mintOrSkip(request, { email: uniqueEmail("e2e-placement") });
  await injectSession(page, session);
}

const HELPER_PREFIX = "This shelf is set to Members";
const HELPER_SUFFIX = "more visible than its shelf";

const HIDDEN_ARIA_HINT = "hidden (only visible to you)";

/**
 * Set a bookshelf's visibility ceiling via the real API (PUT
 * /api/bookshelves/:name/visibility). Returns the HTTP status so the caller can
 * assert the precondition actually took.
 */
async function setShelfCeiling(
  page: Page,
  shelfName: string,
  visibility: string
): Promise<number> {
  if (!page.url().startsWith("http")) {
    await page.goto("/");
  }
  return page.evaluate(
    async ({ shelfName, visibility }) => {
      const auth = JSON.parse(localStorage.getItem("stacks-auth") || "{}");
      const headers = {
        Authorization: `Bearer ${auth.token}`,
        "Content-Type": "application/json",
      };
      await fetch(`/api/settings/profile_visibility`, {
        method: "PUT",
        headers,
        body: JSON.stringify({ profile_visibility: "platform" }),
      });
      const resp = await fetch(`/api/bookshelves/${shelfName}/visibility`, {
        method: "PUT",
        headers,
        body: JSON.stringify({ visibility }),
      });
      return resp.status;
    },
    { shelfName, visibility }
  );
}

/**
 * Open the detail overlay for the first book on the given shelf and return the
 * overlay locator. Ensures a placed book exists first (seeded user usually has
 * one, but ensureBookOnShelf makes it deterministic).
 */
async function openFirstBookOverlay(page: Page, shelfName: string) {
  await ensureBookOnShelf(page, shelfName);
  await page.goto(`/${shelfName}`);
  await page.waitForSelector(".bookcase", { timeout: 10000 });
  const spine = page.getByTestId("book-spine").first();
  await expect(spine).toBeAttached({ timeout: 10000 });
  await spine.evaluate((el) => (el as HTMLElement).click());
  const overlay = page.getByTestId("book-overlay");
  await expect(overlay).toBeVisible({ timeout: 5000 });
  return overlay;
}

test.describe("Placement visibility — book-detail overlay (live browser)", () => {
  test("dropdown shows current visibility and greys sub-ceiling options with helper text", async ({
    page,
    request,
  }) => {
    await landAsFreshUser(page, request);
    expect(await setShelfCeiling(page, SHELF, "platform")).toBe(200);

    try {
      const overlay = await openFirstBookOverlay(page, SHELF);

      const select = overlay.getByTestId("placement-visibility-select");
      await expect(select).toBeVisible();

      await expect(select).toHaveValue(/^(public|platform|owner)$/);

      const publicOption = select.locator('option[value="public"]');
      await expect(publicOption).toBeDisabled();

      await expect(select.locator('option[value="platform"]')).toBeEnabled();
      await expect(select.locator('option[value="owner"]')).toBeEnabled();

      const helper = overlay.locator(".book-detail__visibility-help");
      await expect(helper).toBeVisible();
      await expect(helper).toContainText(HELPER_PREFIX);
      await expect(helper).toContainText(HELPER_SUFFIX);
    } finally {
      await setShelfCeiling(page, SHELF, "public");
    }
  });

  test('the visibility label reads "Members", never "Platform"', async ({
    page,
    request,
  }) => {
    await landAsFreshUser(page, request);
    const overlay = await openFirstBookOverlay(page, SHELF);
    const select = overlay.getByTestId("placement-visibility-select");
    await expect(select).toBeVisible();

    await expect(select.locator("option", { hasText: "Members" })).toHaveCount(1);
    await expect(
      select.locator("option", { hasText: /^Platform$/ })
    ).toHaveCount(0);
    await expect(
      select.locator("option", { hasText: "Only me" })
    ).toHaveCount(1);
  });

  test('setting a placement to "Only me" renders the spine faint/hidden on the shelf', async ({
    page,
    request,
  }) => {
    await landAsFreshUser(page, request);
    expect(await setShelfCeiling(page, SHELF, "platform")).toBe(200);
    const overlay = await openFirstBookOverlay(page, SHELF);

    const spineTitle = (
      await page.getByTestId("book-spine").first().locator(".book__title").textContent()
    )?.trim();
    expect(spineTitle, "the shelf spine exposes a title").toBeTruthy();

    const select = overlay.getByTestId("placement-visibility-select");
    await select.selectOption("owner");

    await expect(
      overlay.locator(".book-detail__status--success")
    ).toBeVisible({ timeout: 10000 });

    await overlay.getByTestId("book-overlay-close").click();
    await expect(page.getByTestId("book-overlay")).toBeHidden();
    await page.goto(`/${SHELF}`);
    await page.waitForSelector(".bookcase", { timeout: 10000 });

    const hiddenSpine = page.locator('[data-testid="book-spine"].book--hidden');
    await expect(hiddenSpine).toHaveCount(1, { timeout: 10000 });
    const hiddenLabel = await hiddenSpine.getAttribute("aria-label");
    expect(hiddenLabel).toContain(HIDDEN_ARIA_HINT);
    expect(hiddenLabel).toContain(spineTitle as string);

    await hiddenSpine.evaluate((el) => (el as HTMLElement).click());
    const reopened = page.getByTestId("book-overlay");
    await expect(reopened).toBeVisible({ timeout: 5000 });
    await reopened.getByTestId("placement-visibility-select").selectOption("platform");
    await expect(
      reopened.locator(".book-detail__status--success")
    ).toBeVisible({ timeout: 10000 });
  });
});
