import { test, expect } from "@playwright/test";
import { provisionBookOnShelf } from "./helpers";

/**
 * The shelf organiser (US-1.7.1 / #190, campaign G5) — organising the *physical* shelves
 * inside a bookshelf.
 *
 * ⚠️ **Why this suite exists, and why it asserts on the books rather than on the shelves.**
 *
 * The organiser shipped with 28 Elm unit tests and 35 backend tests, all green, and was
 * still broken the first time anyone clicked "Add a shelf": every book on the page
 * disappeared. `GET /api/bookshelves/:name/shelves` returned a hardcoded empty `placements`
 * list for every shelf, and the page repainted its bookcase from that response after each
 * mutation. Each half of the wire was self-consistent — the server returned what it said it
 * would, the client decoded it correctly — so no unit test on either side could see it.
 *
 * The lesson is in the assertions below: after a shelf mutation, this suite checks **the
 * books are still on the page**, not merely that the shelf count changed. A suite that only
 * counted shelf rows would have passed throughout.
 *
 * Every test mints its own fresh user and provisions its own placement
 * (`provisionBookOnShelf`), following the shelf-actions/#294 pattern — self-restoring and
 * independent.
 *
 * ⚠️ **Against a preview, run this with `--workers=1`.** The preview core VM is 512 MB, and four
 * parallel workers each minting a session 502'd the helper (`session-mint helper returned HTTP
 * 502`) on 2026-07-28 — 4 passed, 2 failed, and the two failures were capacity, not defects. The
 * same six pass serially. A 502 from `/api/test/session` here means the machine buckled, not that
 * the organiser is broken; re-run with one worker before believing anything else.
 */

/** The organiser only renders for the owner, in spine view, once shelves have loaded. */
async function openOrganiser(page: import("@playwright/test").Page) {
  await page.goto("/library");
  await page.waitForSelector(".bookcase", { timeout: 15000 });

  // Presence first, then act. A wait-for-absence here would be satisfied by the
  // pre-condition and fail open — the slower the page, the more reliably it fails open.
  const organiser = page.getByTestId("shelf-organiser");
  await expect(organiser).toBeAttached({ timeout: 15000 });
  await expect(page.getByTestId("shelf-row").first()).toBeAttached({
    timeout: 15000,
  });
  return organiser;
}

test.describe("Shelf organiser — a mutation must not lose the books", () => {
  test("adding a shelf leaves every book on the page", async ({
    page,
    request,
  }) => {
    await provisionBookOnShelf(page, request, "library");
    await openOrganiser(page);

    const spines = page.getByTestId("book-spine");
    const spinesBefore = await spines.count();
    expect(
      spinesBefore,
      "provisioning put a book on the library shelf, so the bookcase must render at least one spine — if this is 0 the rest of the test proves nothing",
    ).toBeGreaterThan(0);

    const rowsBefore = await page.getByTestId("shelf-row").count();

    await page.getByTestId("shelf-add").click();

    // The new shelf arrives...
    await expect(page.getByTestId("shelf-row")).toHaveCount(rowsBefore + 1, {
      timeout: 15000,
    });

    // ...and — the actual regression — the books are still there.
    await expect(
      spines,
      "the books vanished from the bookcase after adding a shelf: the reload path is repainting from a payload that carries no placements",
    ).toHaveCount(spinesBefore);
  });

  test("a shelf holding books still reports them after a mutation", async ({
    page,
    request,
  }) => {
    // The same root cause with a different face: a full shelf that reads as "empty" also
    // *enables* Remove, offering a destructive action the server refuses with 422.
    await provisionBookOnShelf(page, request, "library");
    await openOrganiser(page);

    const occupied = page.getByTestId("shelf-row").first();
    await expect(occupied).toContainText("book", { timeout: 15000 });
    await expect(occupied).not.toContainText("empty");

    await page.getByTestId("shelf-add").click();
    await expect(page.getByTestId("shelf-row")).toHaveCount(2, {
      timeout: 15000,
    });

    await expect(
      page.getByTestId("shelf-row").first(),
      'the occupied shelf reads as "empty" after adding a shelf, so Remove is now offered on a shelf the server will refuse to delete',
    ).not.toContainText("empty");

    await expect(
      page.getByTestId("shelf-row").first().getByTestId("shelf-remove"),
      "Remove is enabled on a shelf that still holds books",
    ).toBeDisabled();
  });

  test("reordering with the arrows keeps the books and moves the shelf", async ({
    page,
    request,
  }) => {
    await provisionBookOnShelf(page, request, "library");
    await openOrganiser(page);

    const spinesBefore = await page.getByTestId("book-spine").count();
    expect(spinesBefore).toBeGreaterThan(0);

    // Need two shelves before an order exists to change.
    await page.getByTestId("shelf-add").click();
    await expect(page.getByTestId("shelf-row")).toHaveCount(2, {
      timeout: 15000,
    });

    // The occupied shelf is first; move it down. Its label is index-based ("Shelf 1"), so
    // assert on the book count, which travels with the shelf.
    const secondRowBefore = await page
      .getByTestId("shelf-row")
      .nth(1)
      .innerText();
    expect(
      secondRowBefore,
      "the freshly added shelf should be the empty one",
    ).toContain("empty");

    await page
      .getByTestId("shelf-row")
      .first()
      .getByTestId("shelf-move-down")
      .click();

    // The empty shelf is now first and the occupied one second.
    await expect(page.getByTestId("shelf-row").first()).toContainText("empty", {
      timeout: 15000,
    });
    await expect(page.getByTestId("shelf-row").nth(1)).toContainText("book");

    await expect(
      page.getByTestId("book-spine"),
      "the books vanished after a reorder",
    ).toHaveCount(spinesBefore);
  });

  test("dragging a row reorders it", async ({ page, request }) => {
    // ⛔ The bug this covers: `dragover` carried a `DragEnd` message, which cleared the
    // drag state. Since `dragover` fires continuously while a row is hovered, `dragging`
    // was always `Nothing` by the time `drop` arrived and every drop was a silent no-op.
    // Drag-and-drop could not work in any browser, and 28 unit tests passed throughout
    // because they all exercised the pure move functions rather than the event wiring.
    //
    // `dragTo` issues real HTML5 drag events, so this is the assertion that closes the
    // gap the unit tests leave — the arrows and the drag are separate code paths into the
    // same functions, and only one of them was broken.
    await provisionBookOnShelf(page, request, "library");
    await openOrganiser(page);

    const spinesBefore = await page.getByTestId("book-spine").count();
    expect(spinesBefore).toBeGreaterThan(0);

    await page.getByTestId("shelf-add").click();
    await expect(page.getByTestId("shelf-row")).toHaveCount(2, {
      timeout: 15000,
    });

    // The occupied shelf is first, the new empty one second. Drag the empty one onto the
    // occupied one's position; the occupied shelf should end up second.
    await expect(page.getByTestId("shelf-row").nth(1)).toContainText("empty");

    await page
      .getByTestId("shelf-row")
      .nth(1)
      .dragTo(page.getByTestId("shelf-row").first());

    await expect(
      page.getByTestId("shelf-row").first(),
      "the drop did not reorder anything — check that dragover is not cancelling the drag",
    ).toContainText("empty", { timeout: 15000 });
    await expect(page.getByTestId("shelf-row").nth(1)).toContainText("book");

    await expect(
      page.getByTestId("book-spine"),
      "the books vanished after a drag",
    ).toHaveCount(spinesBefore);
  });

  /*
   * ⚠️ Deliberately NOT covered here: "the organiser is absent on someone else's bookshelf".
   * It needs the viewer's own handle, and there is no `/api/me` route — `MintedSession`
   * carries only email/token/userId/displayName. Rather than add an endpoint for a test, the
   * guarantee lives where it belongs, as a SECURITY assertion in
   * `frontend/tests/Page/BookshelfReadOnlyTest.elm` (`noAddShelfControl` /
   * `noShelfOrganiserPanel`) — which is also where it was found to be *vacuous*: it matched
   * on the text "Add shelf" while the button says "Add a shelf", so it passed by matching
   * nothing. Now anchored on testIds.
   */
});
