import { test, expect } from "@playwright/test";

/**
 * A cover URL that does not load must fall back to the styled placeholder the
 * catalogue already uses, rather than leaving the browser's broken-image glyph
 * in a frame every neighbouring surface fills.
 *
 * The seeded books carry no cover URLs, so the failure this guards against
 * cannot occur against seed data alone. Rather than depend on a hand-edited
 * row, the test gives one book a cover through the API response and then makes
 * that image fail — both halves in the browser, so what is exercised is the
 * real Elm error handler on a real <img> error event.
 */

test.use({ storageState: { cookies: [], origins: [] } });

const BROKEN_COVER = "/images/a-cover-that-does-not-exist.jpg";

test.describe("Book cover fallback", () => {
  test("a cover that fails to load is replaced by the placeholder", async ({
    page,
  }) => {
    await page.goto("/");

    const book = await page.evaluate(async () => {
      const resp = await fetch("/api/catalogue?per_page=1");
      const data = await resp.json();
      return data.books?.[0] ? { id: data.books[0].id } : null;
    });
    expect(book, "no book to open").not.toBeNull();

    // Give the book a cover the browser will fail to fetch. Rewriting the
    // response rather than the database keeps this test true on any machine.
    await page.route(`**/api/books/${book!.id}`, async (route) => {
      const response = await route.fetch();
      const body = await response.json();
      if (body.book?.primary_edition) {
        body.book.primary_edition.cover_image_url = BROKEN_COVER;
      }
      if (Array.isArray(body.book?.editions)) {
        for (const e of body.book.editions) e.cover_image_url = BROKEN_COVER;
      }
      await route.fulfill({ response, json: body });
    });

    await page.route(`**${BROKEN_COVER}`, (route) => route.abort());

    await page.goto(`/books/${book!.id}`);
    await expect(page.getByTestId("book-title")).toBeVisible({ timeout: 15000 });

    // The placeholder appears...
    await expect(
      page.locator(".book-detail__cover-placeholder")
    ).toBeVisible({ timeout: 10000 });

    // ...and the broken <img> is GONE, not merely covered up. Leaving it in
    // place would keep the browser's broken glyph rendering underneath.
    await expect(page.getByTestId("book-cover")).toHaveCount(0);
  });
});
