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

// Ceiling helper copy — from Types.Visibility.ceilingHelperText. Uses a curly
// apostrophe (’) and em dash (—) in the real string; we assert on ASCII-safe
// substrings that straddle those glyphs so a copy tweak to the punctuation
// doesn't spuriously fail the test.
const HELPER_PREFIX = "This shelf is set to Members";
const HELPER_SUFFIX = "more visible than its shelf";

// Faint owner-only spine — from Components.Spine: `class "book book--hidden"`
// plus an aria-label suffix `, hidden (only visible to you)`.
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
  // localStorage (the auth token) is only readable once the app origin is
  // loaded — a fresh page starts on about:blank, where access is denied.
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
      // A parallel spec may have tightened the shared seeded user's PROFILE to
      // "owner", which (per the #195 ceiling) forces every shelf to "owner" and
      // would 422 this shelf update. Loosen the profile to "platform" first so
      // the target shelf visibility is within the ceiling.
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
    // Precondition: tighten the shelf ceiling to Members(platform) so that the
    // more-permissive "Public" option must be greyed out and the ceiling helper
    // text appears. A public shelf greys nothing, so no helper text would show.
    expect(await setShelfCeiling(page, SHELF, "platform")).toBe(200);

    try {
      const overlay = await openFirstBookOverlay(page, SHELF);

      const select = overlay.getByTestId("placement-visibility-select");
      await expect(select).toBeVisible();

      // The dropdown reflects the placement's current stored visibility.
      await expect(select).toHaveValue(/^(public|platform|owner)$/);

      // "Public" is more visible than the Members ceiling → disabled/greyed.
      const publicOption = select.locator('option[value="public"]');
      await expect(publicOption).toBeDisabled();

      // Options AT or BELOW the ceiling stay selectable.
      await expect(select.locator('option[value="platform"]')).toBeEnabled();
      await expect(select.locator('option[value="owner"]')).toBeEnabled();

      // The ceiling is explained by visible HELPER TEXT below the select
      // (not a per-option tooltip).
      const helper = overlay.locator(".book-detail__visibility-help");
      await expect(helper).toBeVisible();
      await expect(helper).toContainText(HELPER_PREFIX);
      await expect(helper).toContainText(HELPER_SUFFIX);
    } finally {
      // Restore the default so parallel/subsequent tests see a public shelf.
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

    // The platform tier is relabelled "Members" for readers.
    await expect(select.locator("option", { hasText: "Members" })).toHaveCount(1);
    // The raw enum name must not leak into the UI.
    await expect(
      select.locator("option", { hasText: /^Platform$/ })
    ).toHaveCount(0);
    // "Only me" is the owner-tier label used in the next test.
    await expect(
      select.locator("option", { hasText: "Only me" })
    ).toHaveCount(1);
  });

  test('setting a placement to "Only me" renders the spine faint/hidden on the shelf', async ({
    page,
    request,
  }) => {
    await landAsFreshUser(page, request);
    // Set the shelf to the most permissive VALID bookshelf visibility so both
    // the "owner" and "platform" placement options this test uses are selectable.
    // (Bookshelves are owner/group/platform — "public" is a placement-only tier,
    // so it would 422 on invalid-inclusion.) setShelfCeiling loosens the fresh
    // user's default "owner" profile to platform first so this is within ceiling.
    expect(await setShelfCeiling(page, SHELF, "platform")).toBe(200);
    const overlay = await openFirstBookOverlay(page, SHELF);

    // Identify the book by the SPINE's own title, read from the shelf behind the
    // overlay — NOT by the overlay's heading.
    //
    // ⚠️ They are deliberately different strings. `Page.BookDetail` renders
    // `Types.Book.displayTitle`, which reads "Not yet identified" whenever the primary
    // edition is `barcode_unverified`; `Components.Spine` labels the spine with the raw
    // `book.title`. 99 of the 100 catalogue books on a seeded stack are
    // `barcode_unverified`, so using the overlay heading as an identity token compared
    // two different contracts and failed on essentially every book.
    const spineTitle = (
      await page.getByTestId("book-spine").first().locator(".book__title").textContent()
    )?.trim();
    expect(spineTitle, "the shelf spine exposes a title").toBeTruthy();

    const select = overlay.getByTestId("placement-visibility-select");
    await select.selectOption("owner");

    // Optimistic save confirms with a status line.
    await expect(
      overlay.locator(".book-detail__status--success")
    ).toBeVisible({ timeout: 10000 });

    // Close the overlay and return to the shelf.
    await overlay.getByTestId("book-overlay-close").click();
    await expect(page.getByTestId("book-overlay")).toBeHidden();
    await page.goto(`/${SHELF}`);
    await page.waitForSelector(".bookcase", { timeout: 10000 });

    // The owner-only book now renders as a faint outline (opacity 0.35 via the
    // `book--hidden` class) and its aria-label carries the private-book hint.
    //
    // The count assertion is what makes the single read below sound: this fresh user
    // owns exactly ONE placement, so exactly one spine may be hidden. Asserting on
    // `.first()` of a class that can legitimately match several elements would prove
    // nothing about WHICH spine got hidden — it would pass while the wrong book was
    // suppressed and the intended one left visible.
    const hiddenSpine = page.locator('[data-testid="book-spine"].book--hidden');
    await expect(hiddenSpine).toHaveCount(1, { timeout: 10000 });
    // Assert the aria-label CONTAINS the hint and the title. Read the attribute and
    // use toContain rather than a dynamically-built RegExp (avoids the
    // non-literal-RegExp scan finding and any ReDoS surface).
    const hiddenLabel = await hiddenSpine.getAttribute("aria-label");
    expect(hiddenLabel).toContain(HIDDEN_ARIA_HINT);
    expect(hiddenLabel).toContain(spineTitle as string);

    // Restore the placement to Members so the seeded user is left as found.
    await hiddenSpine.evaluate((el) => (el as HTMLElement).click());
    const reopened = page.getByTestId("book-overlay");
    await expect(reopened).toBeVisible({ timeout: 5000 });
    await reopened.getByTestId("placement-visibility-select").selectOption("platform");
    await expect(
      reopened.locator(".book-detail__status--success")
    ).toBeVisible({ timeout: 10000 });
  });
});
