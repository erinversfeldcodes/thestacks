import { test, expect } from "@playwright/test";

/**
 * The public routes, loaded cold and signed out — the way a shared link arrives.
 *
 * Every other spec for these pages authenticates first, so "the suite is green"
 * has never said anything about what someone sees when they follow a link from
 * outside. A book link is the clearest case: it exists to be sent to someone who
 * does not have an account.
 *
 * Each test asserts the page's real content AND that the loading placeholder is
 * gone. Asserting only the content would pass on a page that renders its title
 * from the route while its body never resolves; asserting the placeholder is
 * absent is what makes "it finished loading" a claim rather than a hope.
 */

test.use({ storageState: { cookies: [], origins: [] } });

/** A real book from the public catalogue — signed out, as a stranger sees it. */
async function firstPublicBook(page: import("@playwright/test").Page) {
  await page.goto("/");
  const book = await page.evaluate(async () => {
    const resp = await fetch("/api/catalogue?per_page=1");
    const data = await resp.json();
    return data.books?.[0]
      ? { id: data.books[0].id, title: data.books[0].title }
      : null;
  });
  expect(book, "public catalogue returned no books to link to").not.toBeNull();
  return book as { id: string; title: string };
}

test.describe("Public routes — signed out", () => {
  test("the catalogue lists books to a signed-out visitor", async ({ page }) => {
    await page.goto("/catalogue");

    await expect(page.getByTestId("catalogue-grid")).toBeVisible({
      timeout: 15000,
    });
    await expect(
      page.locator(".catalogue__card-link").first()
    ).toBeVisible();
    await expect(page.getByText("Loading catalogue...")).toHaveCount(0);
  });

  test("a book link opens the full-page route and shows the book", async ({
    page,
  }) => {
    const book = await firstPublicBook(page);

    // The full-page route, reached by URL — not the overlay the catalogue opens.
    await page.goto(`/books/${book.id}`);

    const title = page.getByTestId("book-title");
    await expect(title).toBeVisible({ timeout: 15000 });
    await expect(title).toHaveText(book.title);
    await expect(page.getByText("Loading book...")).toHaveCount(0);
    await expect(page.locator(".page--book-detail")).toBeVisible();
  });

  // These two assert their OWN heading rather than "a title is visible" — every
  // page here has a `.page__title`, so the generic form passes on whichever page
  // it happens to land on, including the wrong one.
  test("the about page renders its essay to a signed-out visitor", async ({
    page,
  }) => {
    await page.goto("/about");
    await expect(
      page.getByRole("heading", { name: "About The Stacks" })
    ).toBeVisible({ timeout: 15000 });
    await expect(page.locator(".about__lede")).toBeVisible();
  });

  test("the data-transparency essay renders signed out", async ({ page }) => {
    await page.goto("/transparency");
    await expect(
      page.getByRole("heading", { name: "What we agreed to, and what we didn't" })
    ).toBeVisible({ timeout: 15000 });
    await expect(page.locator(".about__lede")).toBeVisible();
  });
});
