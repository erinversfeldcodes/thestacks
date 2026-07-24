import { test, expect } from "@playwright/test";
import type { Page } from "@playwright/test";
import { suiteAuthFile, apiCallFromPage, assertSeedOrSkip } from "./helpers";

test.use({ storageState: suiteAuthFile("search") });

// ── Deterministic seed anchor ────────────────────────────────────────────────
// The query "Book" matches exactly three distinct seeded WORKS (single edition
// each), across three authors and three publication years — see
// apps/core/priv/repo/seeds.exs:
//
//   Title                                   Author              Year
//   The Book of Legendary Lands             Umberto Eco         2013
//   The Book of Sand                        Jorge Luis Borges   1975
//   The Book of Laughter and Forgetting     Milan Kundera       1979
//
// All three are `public`, so every viewer sees them. Because titles, authors,
// and years are all distinct, the three client-side sort orders and the year
// filter each produce a DIFFERENT, precomputable rendered order — which is what
// makes the sort/filter assertions below deterministic rather than "something
// changed".
const BOOK_QUERY = "Book";

const LEGENDARY = "The Book of Legendary Lands";
const SAND = "The Book of Sand";
const LAUGHTER = "The Book of Laughter and Forgetting";

// Default sort is ByTitle ascending (Page.Search.init → sort = ByTitle).
const TITLE_ORDER = [LAUGHTER, LEGENDARY, SAND];
// authorName ascending: "Jorge Luis Borges" < "Milan Kundera" < "Umberto Eco".
const AUTHOR_ORDER = [SAND, LAUGHTER, LEGENDARY];
// publicationYear ascending: 1975 < 1979 < 2013.
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
  const probe = await apiCallFromPage(page, "GET", `/api/search?q=${BOOK_QUERY}`);
  const data = probe.data as { count?: number } | null;
  const count = data && typeof data.count === "number" ? data.count : 0;
  assertSeedOrSkip(
    count >= 3,
    `GET /api/search?q=${BOOK_QUERY} returned count=${count}; expected >= 3 seeded "Book" works`
  );
}

/** Rendered book-result titles, in DOM order. */
async function renderedTitles(page: Page): Promise<string[]> {
  return page.locator(".search-result__title").allInnerTexts();
}

test.describe("Search page", () => {
  test("search page renders with input field and title", async ({ page }) => {
    await page.goto("/search");
    await expect(page.getByTestId("search-page")).toBeVisible({ timeout: 5000 });
    await expect(page.locator(".page__title")).toContainText("Search");
    await expect(page.getByTestId("search-input")).toBeVisible();
  });

  test("shows hint text before searching", async ({ page }) => {
    await page.goto("/search");
    await expect(page.locator(".search-hint")).toBeVisible({ timeout: 5000 });
    await expect(page.locator(".search-hint")).toHaveText(
      "Enter a search term above to find books."
    );
  });

  test("sort selector is present with options", async ({ page }) => {
    await page.goto("/search");
    await page.getByTestId("search-page").waitFor({ timeout: 5000 });

    const sortSelect = page.getByTestId("sort-selector");
    await expect(sortSelect).toBeVisible();

    const options = await sortSelect.locator("option").count();
    expect(options).toBeGreaterThanOrEqual(2);
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

    await expect(page.getByTestId("search-clear")).toBeVisible({ timeout: 2000 });
  });

  // ── Deterministic results (replaces the old fail-open "any response" guard) ──

  test("a seeded query renders matching books with title, author and year", async ({
    page,
  }) => {
    await page.goto("/search");
    await page.getByTestId("search-page").waitFor({ timeout: 5000 });
    await assertBookSeedSufficient(page);

    await page.getByTestId("search-input").fill(BOOK_QUERY);

    // Debounced (300ms) request → the three works render in the results list.
    const results = page.getByTestId("search-results");
    await expect(results).toBeVisible({ timeout: 10000 });
    await expect(page.locator(".search-result")).toHaveCount(3, { timeout: 10000 });

    // Default sort is by title ascending.
    expect(await renderedTitles(page)).toEqual(TITLE_ORDER);

    // Each row binds the correct author + publication year.
    const rowFor = (title: string) =>
      page.locator(".search-result", {
        has: page.locator(".search-result__title", { hasText: title }),
      });

    await expect(rowFor(LEGENDARY).locator(".search-result__author")).toHaveText(
      "Umberto Eco"
    );
    await expect(rowFor(LEGENDARY).locator(".search-result__year")).toHaveText("2013");

    await expect(rowFor(SAND).locator(".search-result__author")).toHaveText(
      "Jorge Luis Borges"
    );
    await expect(rowFor(SAND).locator(".search-result__year")).toHaveText("1975");

    await expect(rowFor(LAUGHTER).locator(".search-result__author")).toHaveText(
      "Milan Kundera"
    );
    await expect(rowFor(LAUGHTER).locator(".search-result__year")).toHaveText("1979");
  });

  test("empty result set shows the no-books message", async ({ page }) => {
    await page.goto("/search");
    await page.getByTestId("search-page").waitFor({ timeout: 5000 });

    await page.getByTestId("search-input").fill("zzqxwvnomatchbook0000");

    await expect(
      page.getByText("No books found matching your search.")
    ).toBeVisible({ timeout: 10000 });
    await expect(page.getByTestId("search-results")).toHaveCount(0);
  });

  test("a failing search request shows the error message", async ({ page }) => {
    // Mock ONLY the book-search route (not /api/search/users) to 500. The
    // literal `?` after `search` keeps the readers endpoint unaffected.
    await page.route(/\/api\/search\?q=/, (route) =>
      route.fulfill({
        status: 500,
        contentType: "application/json",
        body: JSON.stringify({ error: "boom" }),
      })
    );

    await page.goto("/search");
    await page.getByTestId("search-page").waitFor({ timeout: 5000 });

    await page.getByTestId("search-input").fill(BOOK_QUERY);

    await expect(
      page.getByText("Search failed. Please try again.")
    ).toBeVisible({ timeout: 10000 });
    await expect(page.getByTestId("search-results")).toHaveCount(0);
  });

  // ── Sort controls (client-side re-order of the rendered results) ────────────

  test("changing sort re-orders the rendered results deterministically", async ({
    page,
  }) => {
    await page.goto("/search");
    await page.getByTestId("search-page").waitFor({ timeout: 5000 });
    await assertBookSeedSufficient(page);

    await page.getByTestId("search-input").fill(BOOK_QUERY);
    await expect(page.locator(".search-result")).toHaveCount(3, { timeout: 10000 });

    // Default (title) order.
    expect(await renderedTitles(page)).toEqual(TITLE_ORDER);

    const titles = page.locator(".search-result__title");

    // Sort by author → Borges, Kundera, Eco.
    await page.getByTestId("sort-selector").selectOption("author");
    await expect(titles.nth(0)).toHaveText(AUTHOR_ORDER[0]);
    await expect(titles.nth(1)).toHaveText(AUTHOR_ORDER[1]);
    await expect(titles.nth(2)).toHaveText(AUTHOR_ORDER[2]);

    // Sort by year → 1975, 1979, 2013.
    await page.getByTestId("sort-selector").selectOption("year");
    await expect(titles.nth(0)).toHaveText(YEAR_ORDER[0]);
    await expect(titles.nth(1)).toHaveText(YEAR_ORDER[1]);
    await expect(titles.nth(2)).toHaveText(YEAR_ORDER[2]);

    // Back to title → default order restored.
    await page.getByTestId("sort-selector").selectOption("title");
    await expect(titles.nth(0)).toHaveText(TITLE_ORDER[0]);
    await expect(titles.nth(1)).toHaveText(TITLE_ORDER[1]);
    await expect(titles.nth(2)).toHaveText(TITLE_ORDER[2]);
  });

  // ── Year filter ─────────────────────────────────────────────────────────────

  test("a year filter narrows the results and Clear Filters restores them", async ({
    page,
  }) => {
    await page.goto("/search");
    await page.getByTestId("search-page").waitFor({ timeout: 5000 });
    await assertBookSeedSufficient(page);

    await page.getByTestId("search-input").fill(BOOK_QUERY);
    await expect(page.locator(".search-result")).toHaveCount(3, { timeout: 10000 });

    // Open the filter panel and set "Year From" = 1976 — this excludes
    // The Book of Sand (1975) and keeps Laughter (1979) + Legendary (2013).
    await page.getByTestId("filter-toggle").click();
    const yearFrom = page.locator(".filter-panel__input").first();
    await yearFrom.fill("1976");

    await expect(page.locator(".search-result")).toHaveCount(2, { timeout: 5000 });
    expect(await renderedTitles(page)).toEqual([LAUGHTER, LEGENDARY]);
    await expect(
      page.locator(".search-result__title", { hasText: SAND })
    ).toHaveCount(0);

    // Clear Filters restores all three.
    await page.locator(".filter-panel__clear").click();
    await expect(page.locator(".search-result")).toHaveCount(3, { timeout: 5000 });
    expect(await renderedTitles(page)).toEqual(TITLE_ORDER);
  });
});
