import { test, expect } from "@playwright/test";
import type { APIRequestContext, Page } from "@playwright/test";
import {
  suiteAuthFile,
  apiCallFromPage,
  assertSeedOrSkip,
  mintOrSkip,
  injectSession,
} from "./helpers";

test.use({ storageState: suiteAuthFile("search") });

const BOOK_QUERY = "Book";

const LEGENDARY = "The Book of Legendary Lands";
const SAND = "The Book of Sand";
const LAUGHTER = "The Book of Laughter and Forgetting";

const TITLE_ORDER = [LAUGHTER, LEGENDARY, SAND];
const AUTHOR_ORDER = [SAND, LAUGHTER, LEGENDARY];
const YEAR_ORDER = [SAND, LAUGHTER, LEGENDARY];

/**
 * Guard the seed-dependent tests: prove the stack actually carries the three
 * "Book" works before asserting on how the UI renders them. Uses the same
 * assertSeedOrSkip contract as the rest of the suite — a loud skip on a thin
 * target, a HARD FAILURE under E2E_EXPECT_FULL_SEEDS=1. This probes the API
 * directly (not the rendered DOM), so it never masks a client-side rendering
 * bug: if the API returns the three works but the page fails to render them,
 * the gate passes and the DOM assertion is the one that fails.
 */
async function assertBookSeedSufficient(page: Page): Promise<void> {
  const probe = await apiCallFromPage(
    page,
    "GET",
    `/api/search?q=${BOOK_QUERY}`,
  );
  const data = probe.data as { count?: number } | null;
  const count = data && typeof data.count === "number" ? data.count : 0;
  assertSeedOrSkip(
    count >= 3,
    `GET /api/search?q=${BOOK_QUERY} returned count=${count}; expected >= 3 seeded "Book" works`,
  );
}

/** Rendered book-result titles, in DOM order. */
async function renderedTitles(page: Page): Promise<string[]> {
  return page.locator(".search-result__title").allInnerTexts();
}

test.describe("Search page", () => {
  test("search page renders with input field and title", async ({ page }) => {
    await page.goto("/search");
    await expect(page.getByTestId("search-page")).toBeVisible({
      timeout: 5000,
    });
    await expect(page.locator(".page__title")).toContainText("Search");
    await expect(page.getByTestId("search-input")).toBeVisible();
  });

  test("shows hint text before searching", async ({ page }) => {
    await page.goto("/search");
    await expect(page.locator(".search-hint")).toBeVisible({ timeout: 5000 });
    await expect(page.locator(".search-hint")).toHaveText(
      "Type a title, author, or ISBN to search the stacks.",
    );
  });

  test("sort selector lists Relevance/Title/Author/Year with Relevance selected by default", async ({
    page,
  }) => {
    await page.goto("/search");
    await page.getByTestId("search-page").waitFor({ timeout: 5000 });

    const sortSelect = page.getByTestId("sort-selector");
    await expect(sortSelect).toBeVisible();

    await expect(sortSelect.locator("option")).toHaveText([
      "Relevance",
      "Title",
      "Author",
      "Year",
    ]);

    await expect(sortSelect).toHaveValue("relevance");
  });

  test("filter panel toggle is present", async ({ page }) => {
    await page.goto("/search");
    await page.getByTestId("search-page").waitFor({ timeout: 5000 });

    await expect(page.getByTestId("filter-toggle")).toBeVisible();
  });

  test("clear button appears after typing", async ({ page }) => {
    await page.goto("/search");
    await page.getByTestId("search-page").waitFor({ timeout: 5000 });

    await expect(page.getByTestId("search-clear")).not.toBeVisible();

    await page.getByTestId("search-input").fill("test");

    await expect(page.getByTestId("search-clear")).toBeVisible({
      timeout: 2000,
    });
  });

  test("a seeded query renders matching books with title, author and year", async ({
    page,
  }) => {
    await page.goto("/search");
    await page.getByTestId("search-page").waitFor({ timeout: 5000 });
    await assertBookSeedSufficient(page);

    await page.getByTestId("search-input").fill(BOOK_QUERY);

    const results = page.getByTestId("search-results");
    await expect(results).toBeVisible({ timeout: 10000 });
    await expect(page.locator(".search-result")).toHaveCount(3, {
      timeout: 10000,
    });

    const rowFor = (title: string) =>
      page.locator(".search-result", {
        has: page.locator(".search-result__title", { hasText: title }),
      });

    await expect(
      rowFor(LEGENDARY).locator(".search-result__author"),
    ).toHaveText("Umberto Eco");
    await expect(rowFor(LEGENDARY).locator(".search-result__year")).toHaveText(
      "2013",
    );

    await expect(rowFor(SAND).locator(".search-result__author")).toHaveText(
      "Jorge Luis Borges",
    );
    await expect(rowFor(SAND).locator(".search-result__year")).toHaveText(
      "1975",
    );

    await expect(rowFor(LAUGHTER).locator(".search-result__author")).toHaveText(
      "Milan Kundera",
    );
    await expect(rowFor(LAUGHTER).locator(".search-result__year")).toHaveText(
      "1979",
    );

    await page.getByTestId("sort-selector").selectOption("title");
    expect(await renderedTitles(page)).toEqual(TITLE_ORDER);
  });

  test("empty result set shows the no-books message", async ({ page }) => {
    await page.goto("/search");
    await page.getByTestId("search-page").waitFor({ timeout: 5000 });

    await page.getByTestId("search-input").fill("zzqxwvnomatchbook0000");

    await expect(
      page.getByText("Nothing on the shelves matches that — yet."),
    ).toBeVisible({ timeout: 10000 });
    await expect(page.getByTestId("search-results")).toHaveCount(0);
  });

  test("a failing search request shows the error message", async ({ page }) => {
    await page.route(/\/api\/search\?q=/, (route) =>
      route.fulfill({
        status: 500,
        contentType: "application/json",
        body: JSON.stringify({ error: "boom" }),
      }),
    );

    await page.goto("/search");
    await page.getByTestId("search-page").waitFor({ timeout: 5000 });

    await page.getByTestId("search-input").fill(BOOK_QUERY);

    await expect(
      page
        .getByText(
          "We couldn't reach the shelves just now. Give it a moment and try again.",
        )
        .first(),
    ).toBeVisible({ timeout: 10000 });
    await expect(page.getByTestId("search-results")).toHaveCount(0);
  });

  test("changing sort re-orders the rendered results deterministically", async ({
    page,
  }) => {
    await page.goto("/search");
    await page.getByTestId("search-page").waitFor({ timeout: 5000 });
    await assertBookSeedSufficient(page);

    await page.getByTestId("search-input").fill(BOOK_QUERY);
    await expect(page.locator(".search-result")).toHaveCount(3, {
      timeout: 10000,
    });

    const collection = page.getByTestId("search-collection");
    await expect(collection.locator(".search-result__title")).toHaveText([
      LAUGHTER,
    ]);

    const platformTitles = page
      .getByTestId("search-platform")
      .locator(".search-result__title");

    await page.getByTestId("sort-selector").selectOption("title");
    await expect(platformTitles).toHaveText([LEGENDARY, SAND]);

    await page.getByTestId("sort-selector").selectOption("author");
    await expect(platformTitles).toHaveText([SAND, LEGENDARY]);

    await page.getByTestId("sort-selector").selectOption("year");
    await expect(platformTitles).toHaveText([SAND, LEGENDARY]);

    await page.getByTestId("sort-selector").selectOption("relevance");
    await expect(page.locator(".search-result")).toHaveCount(3);
  });

  test("a year filter narrows the results and Clear Filters restores them", async ({
    page,
  }) => {
    await page.goto("/search");
    await page.getByTestId("search-page").waitFor({ timeout: 5000 });
    await assertBookSeedSufficient(page);

    await page.getByTestId("search-input").fill(BOOK_QUERY);
    await expect(page.locator(".search-result")).toHaveCount(3, {
      timeout: 10000,
    });

    await page.getByTestId("filter-toggle").click();
    const yearFrom = page.locator(".filter-panel__input").first();
    await yearFrom.fill("1976");

    await expect(page.locator(".search-result")).toHaveCount(2, {
      timeout: 5000,
    });
    await expect(
      page.locator(".search-result__title", { hasText: SAND }),
    ).toHaveCount(0);
    await expect(
      page.locator(".search-result__title", { hasText: LAUGHTER }),
    ).toHaveCount(1);
    await expect(
      page.locator(".search-result__title", { hasText: LEGENDARY }),
    ).toHaveCount(1);

    await page.locator(".filter-panel__clear").click();
    await expect(page.locator(".search-result")).toHaveCount(3, {
      timeout: 5000,
    });
  });

  test("clicking a result opens the book detail overlay; URL unchanged; Escape returns focus", async ({
    page,
  }) => {
    await page.goto("/search");
    await page.getByTestId("search-page").waitFor({ timeout: 5000 });
    await assertBookSeedSufficient(page);

    await page.getByTestId("search-input").fill(BOOK_QUERY);
    await expect(page.locator(".search-result")).toHaveCount(3, {
      timeout: 10000,
    });

    await page.getByTestId("sort-selector").selectOption("title");
    await expect(page.locator(".search-result__title").first()).toHaveText(
      LAUGHTER,
    );

    const row = page.locator(".search-result", {
      has: page.locator(".search-result__title", { hasText: LAUGHTER }),
    });
    const rowId = await row.getAttribute("id");
    expect(rowId).toMatch(/^search-result-.+/);

    const urlBefore = page.url();

    await row.click();

    const overlay = page.getByTestId("book-overlay");
    await expect(overlay).toBeVisible({ timeout: 10000 });
    await expect(overlay.getByTestId("book-title")).toContainText(LAUGHTER, {
      timeout: 5000,
    });

    expect(page.url()).toBe(urlBefore);
    expect(new URL(page.url()).pathname).toBe("/search");

    await page.keyboard.press("Escape");
    await expect(overlay).toHaveCount(0, { timeout: 5000 });
    await expect(page.locator(`[id="${rowId}"]`)).toBeFocused({
      timeout: 5000,
    });
  });

  test("a year range that matches nothing shows the filter-aware empty state", async ({
    page,
  }) => {
    await page.goto("/search");
    await page.getByTestId("search-page").waitFor({ timeout: 5000 });
    await assertBookSeedSufficient(page);

    await page.getByTestId("search-input").fill(BOOK_QUERY);
    await expect(page.locator(".search-result")).toHaveCount(3, {
      timeout: 10000,
    });

    await page.getByTestId("filter-toggle").click();
    await page.locator(".filter-panel__input").first().fill("3000");

    await expect(
      page.getByText("No books in that year range — widen it or clear filters"),
    ).toBeVisible({ timeout: 5000 });
    await expect(page.getByTestId("search-results")).toHaveCount(0);
  });
});

test.describe("Sectioned search (#285)", () => {
  test.use({ storageState: { cookies: [], origins: [] } });

  /** First catalogue book (id + title) via the API — the deterministic anchor. */
  async function firstCatalogueBook(
    request: APIRequestContext,
  ): Promise<{ id: string; title: string }> {
    const resp = await request.get("/api/catalogue?per_page=1");
    expect(
      resp.ok(),
      "catalogue fetch for sectioned-search anchor",
    ).toBeTruthy();
    const data = await resp.json();
    const book = (
      (data.books ?? []) as Array<{ id: string; title: string }>
    )[0];
    assertSeedOrSkip(
      book !== undefined,
      "catalogue has no books to anchor a sectioned-search spec",
    );
    return { id: book.id, title: book.title };
  }

  test("a placed book renders under Your Collection with its shelf, is deduped off the platform, and opens its overlay", async ({
    page,
    request,
  }) => {
    const owner = await mintOrSkip(request);
    const book = await firstCatalogueBook(request);

    const place = await request.post("/api/bookshelves/library/placements", {
      headers: { Authorization: `Bearer ${owner.token}` },
      data: { book_id: book.id },
    });
    expect(place.status(), "place anchor book on library").toBe(201);

    await injectSession(page, owner);
    await page.goto("/search");
    await page.getByTestId("search-page").waitFor({ timeout: 5000 });
    await page.getByTestId("search-input").fill(book.title);

    const collection = page.getByTestId("search-collection");
    await expect(collection).toBeVisible({ timeout: 10000 });
    await expect(collection.locator(".search-section__title")).toHaveText(
      "Your Collection",
    );
    const ownedRow = collection.locator(".search-result", {
      has: page.locator(".search-result__title", { hasText: book.title }),
    });
    await expect(ownedRow).toHaveCount(1);
    await expect(ownedRow.locator(".search-result__label")).toHaveText(
      "On your Library shelf",
    );

    await expect(
      page
        .getByTestId("search-platform")
        .locator(".search-result__title", { hasText: book.title }),
    ).toHaveCount(0);

    await ownedRow.click();
    const overlay = page.getByTestId("book-overlay");
    await expect(overlay).toBeVisible({ timeout: 10000 });
    await expect(overlay.getByTestId("book-title")).toContainText(book.title, {
      timeout: 5000,
    });
  });

  test("an active marketplace listing renders under On the Platform with a Listed-by label", async ({
    page,
    request,
  }) => {
    const seller = await mintOrSkip(request);
    const book = await firstCatalogueBook(request);

    const place = await request.post("/api/bookshelves/library/placements", {
      headers: { Authorization: `Bearer ${seller.token}` },
      data: { book_id: book.id },
    });
    expect(place.status(), "seller places the book").toBe(201);

    const created = await request.post("/api/listings", {
      headers: { Authorization: `Bearer ${seller.token}` },
      data: {
        book_id: book.id,
        pricing_mode: "fixed",
        price_cents: 12000,
        currency: "ZAR",
        condition: "good",
      },
    });
    expect(created.status(), "create draft listing").toBe(201);
    const listingId = (await created.json()).listing.id as string;

    const activated = await request.put(`/api/listings/${listingId}/activate`, {
      headers: { Authorization: `Bearer ${seller.token}` },
    });
    expect(activated.status(), "activate listing").toBe(200);

    const viewer = await mintOrSkip(request);
    await injectSession(page, viewer);

    const probe = await apiCallFromPage(
      page,
      "GET",
      `/api/search?q=${encodeURIComponent(book.title)}`,
    );
    const hits = ((probe.data as { platform_hits?: unknown[] }).platform_hits ??
      []) as Array<{
      book: { title: string };
      source: string;
      owner_handle: string;
      price: string;
    }>;
    const listed = hits.find(
      (h) => h.book.title === book.title && h.source === "listed",
    );
    expect(listed, "a listed platform hit for the anchor book").toBeTruthy();
    expect(listed!.price).toBe("R120");
    const handle = listed!.owner_handle;
    expect(handle.length).toBeGreaterThan(0);

    await page.goto("/search");
    await page.getByTestId("search-page").waitFor({ timeout: 5000 });
    await page.getByTestId("search-input").fill(book.title);

    const platform = page.getByTestId("search-platform");
    await expect(platform).toBeVisible({ timeout: 10000 });
    await expect(platform.locator(".search-section__title")).toHaveText(
      "On the Platform",
    );
    const listedRow = platform.locator(".search-result", {
      has: page.locator(".search-result__title", { hasText: book.title }),
    });
    await expect(listedRow.locator(".search-result__label")).toHaveText(
      `Listed by ${handle} for R120`,
    );

    await expect(page.getByTestId("search-collection")).toHaveCount(0);
  });

  test("an empty-collection viewer sees only the platform section, and sort re-orders within it", async ({
    page,
    request,
  }) => {
    const viewer = await mintOrSkip(request);
    await injectSession(page, viewer);

    const probe = await apiCallFromPage(
      page,
      "GET",
      `/api/search?q=${BOOK_QUERY}`,
    );
    const count = (probe.data as { count?: number } | null)?.count ?? 0;
    assertSeedOrSkip(
      count >= 3,
      `GET /api/search?q=${BOOK_QUERY} returned count=${count}; expected >= 3 seeded "Book" works`,
    );

    await page.goto("/search");
    await page.getByTestId("search-page").waitFor({ timeout: 5000 });
    await page.getByTestId("search-input").fill(BOOK_QUERY);

    const platform = page.getByTestId("search-platform");
    await expect(platform).toBeVisible({ timeout: 10000 });
    await expect(platform.locator(".search-result")).toHaveCount(3, {
      timeout: 10000,
    });
    await expect(page.getByTestId("search-collection")).toHaveCount(0);

    const platformTitles = platform.locator(".search-result__title");

    await page.getByTestId("sort-selector").selectOption("title");
    await expect(platformTitles).toHaveText(TITLE_ORDER);

    await page.getByTestId("sort-selector").selectOption("author");
    await expect(platformTitles).toHaveText(AUTHOR_ORDER);

    await page.getByTestId("sort-selector").selectOption("year");
    await expect(platformTitles).toHaveText(YEAR_ORDER);
  });
});

test.describe("Deep search (#284)", () => {
  test.use({ storageState: { cookies: [], origins: [] } });

  /**
   * Create a public book whose DESCRIPTION carries a globally-unique term that
   * appears nowhere in its title (and vice-versa), so `scope=deep` is the only
   * way a description-term query finds it and a title-term query never yields a
   * description snippet. Returns the exact title + the two disjoint query terms.
   *
   * Skips cleanly (loud under E2E_EXPECT_FULL_SEEDS) when the helper is
   * unavailable — the same STACKS_E2E_TEST_HELPERS gate mintOrSkip rides on.
   */
  async function seedDescribedBook(
    request: APIRequestContext,
  ): Promise<{ title: string; titleTerm: string; descTerm: string }> {
    const unique = `${Date.now().toString(36)}${Math.floor(
      Math.random() * 1e6,
    ).toString(36)}`;
    const titleTerm = `Zztitle${unique}`;
    const descTerm = `Zzdesc${unique}`;
    const title = `${titleTerm} Deep Anchor`;
    const description = `A ${descTerm} creature drifts through the abyssal dark of a forgotten sea.`;

    const resp = await request.post("/api/test/book-description", {
      data: { title, description },
    });
    assertSeedOrSkip(
      resp.status() !== 404,
      "POST /api/test/book-description unavailable (STACKS_E2E_TEST_HELPERS off)",
    );
    expect(resp.status(), "create description-bearing book").toBe(201);
    return { title, titleTerm, descTerm };
  }

  /**
   * A freshly-minted, placement-free user gets the GLOBAL onboarding overlay,
   * whose backdrop intercepts every click (it would eat the toggle click). Place
   * one shared-seed catalogue book on the viewer's library to satisfy the
   * onboarding check so the overlay stays hidden — the same suppression the
   * gdpr / privacy / audit-log specs use. The placed book carries none of this
   * spec's globally-unique query terms, so it never pollutes the assertions.
   */
  async function suppressOnboarding(
    request: APIRequestContext,
    token: string,
  ): Promise<void> {
    const resp = await request.get("/api/catalogue?per_page=1");
    const data = await resp.json();
    const book = ((data.books ?? []) as Array<{ id: string }>)[0];
    assertSeedOrSkip(
      book !== undefined,
      "catalogue empty — cannot place a book to suppress onboarding",
    );
    const place = await request.post("/api/bookshelves/library/placements", {
      headers: { Authorization: `Bearer ${token}` },
      data: { book_id: book.id },
    });
    expect(place.status(), "place a book to suppress the onboarding overlay").toBe(
      201,
    );
  }

  test("a description-only match surfaces only under deep search, with a highlighted snippet and 'via deep search' label", async ({
    page,
    request,
  }) => {
    const viewer = await mintOrSkip(request);
    const { title, descTerm } = await seedDescribedBook(request);
    await suppressOnboarding(request, viewer.token);
    await injectSession(page, viewer);

    await page.goto("/search");
    await page.getByTestId("search-page").waitFor({ timeout: 5000 });
    await expect(page.getByTestId("onboarding-overlay")).not.toBeVisible();

    await page.getByTestId("search-input").fill(descTerm);
    await expect(
      page.locator(".search-result__title", { hasText: title }),
    ).toHaveCount(0, { timeout: 10000 });

    await page.getByTestId("deep-search-toggle").check();

    const row = page.locator(".search-result", {
      has: page.locator(".search-result__title", { hasText: title }),
    });
    await expect(row).toHaveCount(1, { timeout: 10000 });

    const snippet = row.locator(".search-result__snippet");
    await expect(snippet).toBeVisible();
    await expect(snippet.locator("mark").first()).toHaveText(descTerm);
    await expect(row.locator(".search-result__via-deep")).toHaveText(
      "via deep search",
    );
  });

  test("a title match under deep search carries no snippet or label", async ({
    page,
    request,
  }) => {
    const viewer = await mintOrSkip(request);
    const { title, titleTerm } = await seedDescribedBook(request);
    await suppressOnboarding(request, viewer.token);
    await injectSession(page, viewer);

    await page.goto("/search");
    await page.getByTestId("search-page").waitFor({ timeout: 5000 });
    await expect(page.getByTestId("onboarding-overlay")).not.toBeVisible();

    await page.getByTestId("deep-search-toggle").check();
    await page.getByTestId("search-input").fill(titleTerm);

    const row = page.locator(".search-result", {
      has: page.locator(".search-result__title", { hasText: title }),
    });
    await expect(row).toHaveCount(1, { timeout: 10000 });
    await expect(row.locator(".search-result__snippet")).toHaveCount(0);
    await expect(row.locator(".search-result__via-deep")).toHaveCount(0);
  });
});
