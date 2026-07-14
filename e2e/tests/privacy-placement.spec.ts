import { test, expect } from "@playwright/test";
import type { Page } from "@playwright/test";
import { suiteAuthFile, ensureBookOnShelf } from "./helpers";

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
 * NON-DESTRUCTIVE-USER CHOICE (mirrors gdpr.spec.ts rationale): this only
 * mutates the user's OWN placement/shelf visibility, so it rides the SEEDED
 * `settings` suite user rather than minting a throwaway. That user already has
 * placements, so it never triggers the global onboarding overlay (which
 * intercepts pointer events everywhere), and it adds ZERO load to the shared
 * `:auth` rate bucket (no register/login round-trip). We still call
 * `ensureBookOnShelf` so a spine exists to click before opening the overlay.
 *
 * SHARED-USER SAFETY: the suite runs `fullyParallel`, but these tests mutate
 * shared placement/shelf-ceiling state on ONE user, so the file runs SERIAL to
 * avoid intra-file races, and each test restores the state it changed (shelf
 * ceiling back to `public`, placement back to `platform`/Members) in a finally.
 *
 * CANNOT BE RUN LIVE HERE: no preview stack is available in this worktree, and
 * #201/#202 are not yet merged onto `feat/122-e2e`. Parse + discovery are
 * validated via `npx playwright test privacy-placement.spec.ts --list`; the live
 * run is deferred to the #122 epic-finalization E2E gate. Selectors below were
 * lifted verbatim from the built source (commits 49027a4 / b37c1ec), not
 * guessed — see the spec report for the exact provenance and any residual risk.
 */

test.use({ storageState: suiteAuthFile("settings") });
test.describe.configure({ mode: "serial" });

const SHELF = "library";

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
  }) => {
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
  }) => {
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
  }) => {
    // Make the shelf public so every placement option is selectable — the
    // shared seeded shelf may have been left tighter by a concurrent spec, which
    // would otherwise disable "platform"/"public" and break the restore below.
    expect(await setShelfCeiling(page, SHELF, "public")).toBe(200);
    const overlay = await openFirstBookOverlay(page, SHELF);
    const title = (await overlay.getByTestId("book-title").textContent())?.trim();
    expect(title, "book-detail overlay should expose a title").toBeTruthy();

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
    const hiddenSpine = page.locator('[data-testid="book-spine"].book--hidden');
    await expect(hiddenSpine.first()).toBeAttached({ timeout: 10000 });
    await expect(hiddenSpine.first()).toHaveAttribute(
      "aria-label",
      new RegExp(escapeRegExp(HIDDEN_ARIA_HINT))
    );
    if (title) {
      await expect(hiddenSpine.first()).toHaveAttribute(
        "aria-label",
        new RegExp(escapeRegExp(title))
      );
    }

    // Restore the placement to Members so the seeded user is left as found.
    await hiddenSpine
      .first()
      .evaluate((el) => (el as HTMLElement).click());
    const reopened = page.getByTestId("book-overlay");
    await expect(reopened).toBeVisible({ timeout: 5000 });
    await reopened.getByTestId("placement-visibility-select").selectOption("platform");
    await expect(
      reopened.locator(".book-detail__status--success")
    ).toBeVisible({ timeout: 10000 });
  });
});

/** Escape a string for safe interpolation into a RegExp. */
function escapeRegExp(s: string): string {
  return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}
