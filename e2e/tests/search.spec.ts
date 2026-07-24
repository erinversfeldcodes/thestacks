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
//
// NOTE: the DEFAULT sort is now Relevance (#290) — a passthrough of the
// backend's `plainto_tsquery` rank order, which is NOT client-side
// deterministic for three equally-matching titles. So every ORDER assertion
// below first selects an explicit sort (title/author/year); only membership and
// count are asserted against the default (relevance) order.
const BOOK_QUERY = "Book";

const LEGENDARY = "The Book of Legendary Lands";
const SAND = "The Book of Sand";
const LAUGHTER = "The Book of Laughter and Forgetting";

// Title ascending: "The Book of Laughter…" < "The Book of Legendary…" < "The Book of Sand".
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

    // Truthful option set — no silent no-op "Date Added" (#290).
    await expect(sortSelect.locator("option")).toHaveText([
      "Relevance",
      "Title",
      "Author",
      "Year",
    ]);

    // Controlled dropdown: the default sort (Relevance) is reflected as selected.
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
    await expect(page.locator(".search-result")).toHaveCount(3, {
      timeout: 10000,
    });

    // Each row binds the correct author + publication year (order-independent,
    // so this holds under the default relevance order).
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

    // Explicit title sort gives the deterministic title-ascending order.
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
    // Mock ONLY the book-search route (not /api/search/users) to 500. The
    // literal `?` after `search` keeps the readers endpoint unaffected.
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

  // ── Sort controls (re-order WITHIN each section, #285) ──────────────────────

  test("changing sort re-orders the rendered results deterministically", async ({
    page,
  }) => {
    await page.goto("/search");
    await page.getByTestId("search-page").waitFor({ timeout: 5000 });
    await assertBookSeedSufficient(page);

    await page.getByTestId("search-input").fill(BOOK_QUERY);
    // Three works match; the search suite user OWNS one of them ("The Book of
    // Laughter and Forgetting", seeded onto their library shelf), so post-#285 it
    // renders in "Your Collection" and the other two render in "On the Platform".
    // Total rendered rows stay 3 across both sections.
    await expect(page.locator(".search-result")).toHaveCount(3, {
      timeout: 10000,
    });

    // The owned work stays in "Your Collection" regardless of sort.
    const collection = page.getByTestId("search-collection");
    await expect(collection.locator(".search-result__title")).toHaveText([
      LAUGHTER,
    ]);

    // Sort re-orders WITHIN the platform section. Its two works are Legendary
    // (Eco, 2013) and Sand (Borges, 1975): title asc → Legendary, Sand; author
    // asc → Sand, Legendary (Borges < Eco); year asc → Sand, Legendary. Title
    // differing from author/year proves the re-order is real and deterministic.
    const platformTitles = page
      .getByTestId("search-platform")
      .locator(".search-result__title");

    await page.getByTestId("sort-selector").selectOption("title");
    await expect(platformTitles).toHaveText([LEGENDARY, SAND]);

    await page.getByTestId("sort-selector").selectOption("author");
    await expect(platformTitles).toHaveText([SAND, LEGENDARY]);

    await page.getByTestId("sort-selector").selectOption("year");
    await expect(platformTitles).toHaveText([SAND, LEGENDARY]);

    // Back to relevance → the backend order returns (all three still present).
    await page.getByTestId("sort-selector").selectOption("relevance");
    await expect(page.locator(".search-result")).toHaveCount(3);
  });

  // ── Year filter ─────────────────────────────────────────────────────────────

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

    // Open the filter panel and set "Year From" = 1976 — this excludes
    // The Book of Sand (1975) and keeps Laughter (1979) + Legendary (2013).
    // Assert membership (not order): the default sort is relevance.
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

    // Clear Filters restores all three.
    await page.locator(".filter-panel__clear").click();
    await expect(page.locator(".search-result")).toHaveCount(3, {
      timeout: 5000,
    });
  });

  // ── Result click-through to the book detail overlay (#289) ──────────────────

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

    // Explicit title sort so the target row is deterministic (relevance order
    // is not client-deterministic, per #290) — first row is LAUGHTER.
    await page.getByTestId("sort-selector").selectOption("title");
    await expect(page.locator(".search-result__title").first()).toHaveText(
      LAUGHTER,
    );

    // The row is a real <button> carrying the stable focus-return id
    // (`search-result-<bookId>`). Capture that id before clicking so we can
    // assert focus lands back on this exact element after Escape.
    const row = page.locator(".search-result", {
      has: page.locator(".search-result__title", { hasText: LAUGHTER }),
    });
    const rowId = await row.getAttribute("id");
    expect(rowId).toMatch(/^search-result-.+/);

    const urlBefore = page.url();

    await row.click();

    // Overlay opens over /search showing the clicked book's title.
    const overlay = page.getByTestId("book-overlay");
    await expect(overlay).toBeVisible({ timeout: 10000 });
    await expect(overlay.getByTestId("book-title")).toContainText(LAUGHTER, {
      timeout: 5000,
    });

    // Overlay convention (ADR-005): opening the overlay does NOT change the URL.
    expect(page.url()).toBe(urlBefore);
    expect(new URL(page.url()).pathname).toBe("/search");

    // Escape closes the overlay and returns focus to the clicked row (#114).
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

    // A "Year From" bound past every seeded year empties the list via the
    // filter (not the query) → filter-aware copy, not the plain no-match copy.
    await page.getByTestId("filter-toggle").click();
    await page.locator(".filter-panel__input").first().fill("3000");

    await expect(
      page.getByText("No books in that year range — widen it or clear filters"),
    ).toBeVisible({ timeout: 5000 });
    await expect(page.getByTestId("search-results")).toHaveCount(0);
  });
});

// ── Sectioned search: "Your Collection" vs "On the Platform" (#285) ───────────
//
// The sectioned response splits a query into the viewer's own active-placement
// matches ("Your Collection", each tagged with the shelf it sits on) and the
// platform-visible books ("On the Platform", some carrying a discovery label).
// These specs build the exact placement/listing state they assert against with
// freshly-minted throwaway users (isolated from the shared search seed), so each
// run is deterministic regardless of shared-seed drift or prior runs.
//
// LABEL REACHABILITY (investigated 2026-07-24): the "listed" platform label
// (active marketplace listing → "Listed by <handle> for <price>") is reachable
// end-to-end via the public API (place → POST /api/listings → PUT …/activate).
// The "looking_for_home" label ("Looking for a home on <handle>'s shelf") is
// NOT independently reachable: it requires a looking_for_home placement whose
// `listing_status = "active"`, and the ONLY writer of that column is
// `Marketplace.activate_listing/2`, which simultaneously creates the active
// Listing row that WINS `SearchController.discovery_labels` (Map.merge favours
// "listed"). Seeds set `listing_mode`/`listing_price_cents` on LFH placements but
// never `listing_status`. So the reachable platform label is "listed", asserted
// below; the LFH label is covered at the Elm layer (SearchProgramTest), not here.
test.describe("Sectioned search (#285)", () => {
  // Fresh, unauthenticated context — each spec mints its own user and injects
  // that session, so the shared search-suite storageState must not apply.
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

    // "Your Collection" renders the owned book with its humanised shelf line.
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

    // Deduped: a book already in the viewer's collection never re-appears in the
    // platform section (SearchController rejects collection ids from platform_hits).
    await expect(
      page
        .getByTestId("search-platform")
        .locator(".search-result__title", { hasText: book.title }),
    ).toHaveCount(0);

    // Composition (#289): the collection row is a real button → overlay opens.
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

    // Seller: place → draft listing (fixed R120) → activate. Activation
    // denormalises listing_status = "active" and surfaces the "listed" label.
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

    // A fresh viewer who does NOT own the book — the listing is discovery-visible.
    const viewer = await mintOrSkip(request);
    await injectSession(page, viewer);

    // Bind the DOM assertion to the live wire truth: probe the sectioned API as
    // the viewer for the winning active listing's seller handle + formatted price.
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

    // "On the Platform" renders the listed book with its full discovery label.
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

    // A non-owner viewer has no "Your Collection" section for this query.
    await expect(page.getByTestId("search-collection")).toHaveCount(0);
  });

  test("an empty-collection viewer sees only the platform section, and sort re-orders within it", async ({
    page,
    request,
  }) => {
    const viewer = await mintOrSkip(request);
    await injectSession(page, viewer);

    // The three public "Book" works must be present for this fresh viewer.
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

    // Platform section carries the three works; the fresh viewer owns none, so
    // there is NO "Your Collection" section (it hides entirely when empty).
    const platform = page.getByTestId("search-platform");
    await expect(platform).toBeVisible({ timeout: 10000 });
    await expect(platform.locator(".search-result")).toHaveCount(3, {
      timeout: 10000,
    });
    await expect(page.getByTestId("search-collection")).toHaveCount(0);

    // Sort applies WITHIN the platform section. A fresh viewer owns none of the
    // three works, so all three sort together — the full deterministic re-order
    // (title / author / year each produce a distinct, precomputed order).
    const platformTitles = platform.locator(".search-result__title");

    await page.getByTestId("sort-selector").selectOption("title");
    await expect(platformTitles).toHaveText(TITLE_ORDER);

    await page.getByTestId("sort-selector").selectOption("author");
    await expect(platformTitles).toHaveText(AUTHOR_ORDER);

    await page.getByTestId("sort-selector").selectOption("year");
    await expect(platformTitles).toHaveText(YEAR_ORDER);
  });
});
