import { test, expect } from "@playwright/test";
import type { APIRequestContext, Page } from "@playwright/test";
import { mintSession, injectSession } from "./helpers";

/**
 * Issue #276 — the 50-book Reading Pile cap is enforced at the write path.
 *
 * A user whose pile already holds 50 books attempts to move a 51st book onto
 * it from the Library and must see the specific full-pile message (not the
 * generic move failure, and no silent success).
 *
 * Seeding 50 placements through the UI is impractical, so the setup drives
 * the same placement API the app uses. The spec mints an ISOLATED user via
 * POST /api/test/session (STACKS_E2E_TEST_HELPERS only) so filling a pile to
 * the cap cannot pollute the shared suite users; it skips cleanly where the
 * helper is unavailable (e.g. prod-shaped targets).
 */

const PILE_CAP = 50;
const FULL_PILE_MESSAGE =
  "Your reading pile is full — finish or remove a book before adding another.";

async function apiPlace(
  request: APIRequestContext,
  token: string,
  shelf: string,
  bookId: string
): Promise<number> {
  const resp = await request.post(`/api/bookshelves/${shelf}/placements`, {
    headers: { Authorization: `Bearer ${token}` },
    data: { book_id: bookId },
  });
  return resp.status();
}

async function catalogueBookIds(
  request: APIRequestContext
): Promise<string[]> {
  const resp = await request.get("/api/catalogue?per_page=200");
  if (!resp.ok()) return [];
  const data = await resp.json();
  return (data.books ?? []).map((b: { id: string }) => b.id);
}

async function openLibraryBookOverlay(page: Page) {
  await page.goto("/library");
  await page.waitForSelector(".bookcase", { timeout: 10000 });
  const bookButton = page.getByTestId("book-spine").first();
  await expect(bookButton).toBeAttached({ timeout: 10000 });
  await bookButton.evaluate((el) => (el as HTMLElement).click());
  const overlay = page.getByTestId("book-overlay");
  await expect(overlay).toBeVisible({ timeout: 5000 });
  return overlay;
}

test.describe("Reading Pile 50-book limit (#276)", () => {
  test("moving a 51st book onto a full pile shows the full-pile message", async ({
    page,
    request,
  }) => {
    // Isolated user: this spec fills a pile to the cap, which must never
    // happen to the shared suite users.
    const session = await mintSession(request, {
      displayName: "Pile Limit Tester",
    });
    test.skip(
      session === null,
      "POST /api/test/session unavailable (STACKS_E2E_TEST_HELPERS off)"
    );
    if (!session) return;

    const bookIds = await catalogueBookIds(request);
    test.skip(
      bookIds.length < PILE_CAP + 1,
      `needs ${PILE_CAP + 1} catalogue books to stage a full pile, found ${bookIds.length}`
    );

    // Fill the pile to exactly the cap via the real placement API.
    for (const bookId of bookIds.slice(0, PILE_CAP)) {
      const status = await apiPlace(
        request,
        session.token,
        "reading_pile",
        bookId
      );
      expect(status, `seeding placement for ${bookId}`).toBe(201);
    }

    // The 51st book goes on the Library — the book the user will try to move.
    const extraBookId = bookIds[PILE_CAP];
    expect(
      await apiPlace(request, session.token, "library", extraBookId)
    ).toBe(201);

    // Boundary, API side: a 51st pile placement is rejected with the
    // documented error code (sanity-check before driving the UI).
    const overflow = await request.post(
      "/api/bookshelves/reading_pile/placements",
      {
        headers: { Authorization: `Bearer ${session.token}` },
        data: { book_id: extraBookId },
      }
    );
    expect(overflow.status()).toBe(422);
    expect((await overflow.json()).error).toBe("reading_pile_full");

    // Now the real user journey: Library → book overlay → shelf mover →
    // Reading Pile → Move → the specific full-pile message.
    await injectSession(page, session);
    const overlay = await openLibraryBookOverlay(page);

    await overlay.locator('button:has-text("Choose Bookshelf")').click();
    await expect(overlay.locator(".shelf-mover")).toBeVisible();
    await overlay.getByTestId("shelf-mover-select").selectOption("reading_pile");
    await overlay.getByTestId("shelf-mover-btn").click();

    const fullMsg = overlay.getByTestId("reading-pile-full-msg");
    await expect(fullMsg).toBeVisible({ timeout: 10000 });
    await expect(fullMsg).toHaveText(FULL_PILE_MESSAGE);

    // Distinct from the generic move failure.
    await expect(
      overlay.getByText("Failed to move book. Please try again.")
    ).toHaveCount(0);

    // And nothing snuck onto the pile: still exactly 50.
    const pileResp = await request.get("/api/bookshelves/reading_pile", {
      headers: { Authorization: `Bearer ${session.token}` },
    });
    expect(pileResp.ok()).toBeTruthy();
    const pileData = await pileResp.json();
    const pileCount = (pileData.shelves ?? []).flatMap(
      (s: { placements?: unknown[] }) => s.placements ?? []
    ).length;
    expect(pileCount).toBe(PILE_CAP);
  });
});
