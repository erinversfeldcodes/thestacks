import { test, expect } from "@playwright/test";
import type { APIRequestContext, Locator, Page } from "@playwright/test";
import {
  mintOrSkip,
  injectSession,
  assertSeedOrSkip,
  seedBookWriting,
} from "./helpers";

/**
 * Issue #113 Phase 3 — the spine-rendering flagship Playwright suite (US-1.3.1
 * spine thickness, US-1.3.2 spine wear at the aria level), driven in a real
 * browser against a live stack.
 *
 * Each test mints its OWN isolated, confirmed user via POST /api/test/session
 * (STACKS_E2E_TEST_HELPERS=1 only; skips cleanly where the helper is off) and
 * places specific seeded catalogue books onto specific shelves via the normal
 * placement API. Minting per test keeps the specs fully parallel with no
 * cross-contamination, and choosing the books by page_count gives deterministic,
 * known spine widths — the dev-fixture seed does not guarantee any given book is
 * on any given shelf, so we build the exact shelf state we assert against.
 *
 * WIDTH is read as `offsetWidth` on the `.book` spine element (data-testid
 * "book-spine"). `.book` inherits the global `box-sizing: border-box` and sets
 * no border/padding, and its at-rest transform is identity, so offsetWidth is
 * exactly the inline pixel width Components.Spine.spineWidth computed — a live
 * proof that page_count flowed through the Elm formula into the DOM. The formula
 * mirrored here (`expectedSpineWidth`) is Components.Spine.spineWidth:57-59.
 *
 * WEAR reaches only the aria-label suffix (", well-loved" for Softened; nothing
 * for Pristine — Spine.elm:264-270); visual wear CSS is de-scoped to #288. A
 * minted user's placements are owner-private by default, so the spine also
 * appends ", hidden (only visible to you)" (Spine.elm:272-277) AFTER the wear
 * suffix. We therefore assert wear by robust substring (`toContain(", well-loved")`
 * / `not.toContain(...)`), never by full-string or endsWith equality, so the
 * hidden suffix composes cleanly. Every negative wear assertion is anchored by a
 * positive `toContain(title)` on the same element first, so a wrong selector
 * (which would make `.not.toContain` pass vacuously against a null label) fails
 * loudly instead.
 *
 * BANNED PATTERNS (scripts/check-e2e-vacuous-guards.sh): no `if (count > 0)`
 * guards, no wait-for-absence gating, no OR-chain fail-open assertions. Seed
 * sufficiency is gated with assertSeedOrSkip (hard-fails under
 * E2E_EXPECT_FULL_SEEDS=1, skips loudly otherwise).
 */

type ShelfKey = "library" | "antilibrary" | "wishlist" | "reading_pile";

const SHELF_PATH: Record<ShelfKey, string> = {
  library: "/library",
  antilibrary: "/antilibrary",
  wishlist: "/wishlist",
  reading_pile: "/reading-pile",
};

interface CatBook {
  id: string;
  title: string;
  pageCount: number | null;
}

/** Mirror of Components.Spine.spineWidth (Spine.elm:57-59). */
function expectedSpineWidth(pageCount: number): number {
  return Math.max(35, Math.min(55, Math.round(pageCount / 12)));
}

/**
 * Fetch the WHOLE catalogue. The endpoint caps per_page at 100 server-side, and
 * the books we target ("The …") sort onto page 2, so a single per_page=200 call
 * (which silently returns only the first 100) would miss them — we page until we
 * have `total`. Age-gated books are excluded for a fresh (un-age-verified) user;
 * every book this spec uses is public, so it is always within the returned set.
 */
async function fetchAllCatalogue(
  request: APIRequestContext,
): Promise<CatBook[]> {
  const perPage = 100;
  let page = 1;
  let total = Infinity;
  const acc: CatBook[] = [];
  while (acc.length < total) {
    const resp = await request.get(
      `/api/catalogue?per_page=${perPage}&page=${page}`,
    );
    expect(resp.ok(), `catalogue page ${page} fetch`).toBeTruthy();
    const data = await resp.json();
    total = data.total ?? 0;
    const books = (data.books ?? []) as {
      id: string;
      title: string;
      primary_edition?: { page_count?: number | null };
    }[];
    if (books.length === 0) break;
    for (const b of books) {
      acc.push({
        id: b.id,
        title: b.title,
        pageCount: b.primary_edition?.page_count ?? null,
      });
    }
    page += 1;
  }
  return acc;
}

/** Resolve target titles to catalogue books, or null when a title is absent. */
function lookup(all: CatBook[], titles: string[]): (CatBook | null)[] {
  return titles.map((t) => all.find((b) => b.title === t) ?? null);
}

async function apiPlace(
  request: APIRequestContext,
  token: string,
  shelf: ShelfKey,
  bookId: string,
  label: string,
): Promise<void> {
  const resp = await request.post(`/api/bookshelves/${shelf}/placements`, {
    headers: { Authorization: `Bearer ${token}` },
    data: { book_id: bookId },
  });
  expect(resp.status(), `place "${label}" on ${shelf}`).toBe(201);
}

/**
 * Navigate to a shelf and wait for its browse GET to resolve, so the SPA has the
 * real placement list before any spine assertion. The response promise is
 * registered BEFORE goto so it can't be missed.
 */
async function gotoShelf(page: Page, shelf: ShelfKey): Promise<void> {
  const settled = page.waitForResponse(
    (r) =>
      r.url().includes(`/api/bookshelves/${shelf}`) &&
      r.request().method() === "GET" &&
      r.status() === 200,
    { timeout: 20000 },
  );
  await page.goto(SHELF_PATH[shelf]);
  await settled;
}

/** The `.book` spine element inside a specific book button on a spine bookcase. */
function spineEl(page: Page, bookId: string): Locator {
  return page.locator(`#spine-${bookId} [data-testid="book-spine"]`);
}

async function spineWidthPx(page: Page, bookId: string): Promise<number> {
  const el = spineEl(page, bookId);
  await expect(el).toBeAttached({ timeout: 10000 });
  return el.evaluate((e) => (e as HTMLElement).offsetWidth);
}

async function ariaLabelOf(el: Locator): Promise<string> {
  await expect(el).toBeAttached({ timeout: 10000 });
  const aria = await el.getAttribute("aria-label");
  expect(aria, "spine exposes an aria-label").toBeTruthy();
  return aria as string;
}

const WEAR_SUFFIX = ", well-loved";

// Books chosen for known, distinct spine widths (primary-edition page_count →
// expectedSpineWidth): Dreamtigers 95→35 (clamped min), Queen Loana 480→40,
// Name of the Rose 536→45, Selected Non-Fictions 576→48, Brothers Karamazov
// 796→55 (clamped max). All public (no age gate).
const WIDTH_TITLES = [
  "Dreamtigers",
  "The Mysterious Flame of Queen Loana",
  "The Name of the Rose",
  "Selected Non-Fictions",
  "The Brothers Karamazov",
];

test.describe("Spine rendering (US-1.3.1 thickness, US-1.3.2 wear)", () => {
  test("spine width is computed from page count across the clamp range", async ({
    page,
    request,
  }) => {
    const all = await fetchAllCatalogue(request);
    const found = lookup(all, WIDTH_TITLES);
    assertSeedOrSkip(
      found.every((b) => b !== null),
      `spine width test needs seeded books: ${WIDTH_TITLES.join(", ")}`,
    );
    const books = found as CatBook[];

    const session = await mintOrSkip(request);
    for (const b of books) {
      expect(
        b.pageCount,
        `"${b.title}" has a seeded page_count`,
      ).not.toBeNull();
      await apiPlace(request, session.token, "library", b.id, b.title);
    }
    await injectSession(page, session);
    await gotoShelf(page, "library");

    const measured: Record<string, number> = {};
    for (const b of books) {
      const w = await spineWidthPx(page, b.id);
      measured[b.title] = w;
      expect(w, `"${b.title}" (${b.pageCount}pp) rendered spine width`).toBe(
        expectedSpineWidth(b.pageCount as number),
      );
    }

    // Explicit bucket coverage required by the plan: a clamped-to-35, a
    // mid-range exact value, and a clamped-to-55.
    expect(measured["Dreamtigers"], "95pp clamps to the 35px minimum").toBe(35);
    expect(
      measured["The Name of the Rose"],
      "536pp is an exact interior value (round(536/12)=45)",
    ).toBe(45);
    expect(
      measured["The Brothers Karamazov"],
      "796pp clamps to the 55px maximum",
    ).toBe(55);
    // Prove the mid value is a genuine interior point, not a clamp coincidence.
    expect(measured["The Name of the Rose"]).toBeGreaterThan(35);
    expect(measured["The Name of the Rose"]).toBeLessThan(55);
  });

  test("a heavier book renders a strictly wider spine (continuity)", async ({
    page,
    request,
  }) => {
    const all = await fetchAllCatalogue(request);
    const [thin, thick] = lookup(all, [
      "The Mysterious Flame of Queen Loana", // 480 → 40
      "The Name of the Rose", // 536 → 45
    ]);
    assertSeedOrSkip(
      thin !== null && thick !== null,
      "continuity test needs Queen Loana (480pp) and The Name of the Rose (536pp)",
    );
    expect((thick as CatBook).pageCount).toBeGreaterThan(
      (thin as CatBook).pageCount as number,
    );

    const session = await mintOrSkip(request);
    await apiPlace(request, session.token, "library", thin!.id, thin!.title);
    await apiPlace(request, session.token, "library", thick!.id, thick!.title);
    await injectSession(page, session);
    await gotoShelf(page, "library");

    const wThin = await spineWidthPx(page, thin!.id);
    const wThick = await spineWidthPx(page, thick!.id);
    // Both are interior (un-clamped), so the comparison reflects the formula
    // rather than a shared clamp ceiling/floor.
    for (const w of [wThin, wThick]) {
      expect(w).toBeGreaterThan(35);
      expect(w).toBeLessThan(55);
    }
    expect(
      wThick,
      "heavier book (536pp) is strictly wider than 480pp",
    ).toBeGreaterThan(wThin);
  });

  test("a book with no page_count falls back to the 35px minimum", async ({
    page,
    request,
  }) => {
    const all = await fetchAllCatalogue(request);
    const nullBook = all.find((b) => b.pageCount === null) ?? null;
    // The dev-fixture seed populates page_count on every edition, so there is no
    // catalogue book to drive the null→default→35px path at the E2E layer, and
    // the placement API cannot construct one. This fallback IS proven at the
    // unit layer (BookcaseHelpersTest.elm renders a page_count-less book at the
    // 35px floor, punch #5). We skip loudly here rather than fake it; if a
    // page_count-less book is ever seeded, this test activates automatically.
    // FLAGGED in the Phase-3 report.
    test.skip(
      nullBook === null,
      "no seeded catalogue book has a null page_count — the null→35px default is covered at the Elm unit layer (BookcaseHelpersTest.elm); E2E cannot construct one without a seed/helper change (FLAGGED)",
    );

    const session = await mintOrSkip(request);
    await apiPlace(
      request,
      session.token,
      "library",
      nullBook!.id,
      nullBook!.title,
    );
    await injectSession(page, session);
    await gotoShelf(page, "library");

    expect(await spineWidthPx(page, nullBook!.id)).toBe(35);
    const aria = await ariaLabelOf(spineEl(page, nullBook!.id));
    // Missing page_count renders via Maybe.withDefault 200 (Helpers.elm), so the
    // spine reports "200 pages" even though the edition carries none.
    expect(aria).toContain("200 pages");
  });

  test("wear suffix distinguishes Softened shelves from Pristine shelves", async ({
    page,
    request,
  }) => {
    const all = await fetchAllCatalogue(request);
    const [libBook, pileBook, wishBook, antiBook] = lookup(all, [
      "The Name of the Rose", // Library — Softened
      "The Goldfinch", // Reading Pile — Softened
      "The Idiot", // Wish List — Pristine
      "Crime and Punishment", // AntiLibrary — Pristine
    ]);
    assertSeedOrSkip(
      [libBook, pileBook, wishBook, antiBook].every((b) => b !== null),
      "wear-by-shelf test needs Name of the Rose, The Goldfinch, The Idiot, Crime and Punishment",
    );

    const session = await mintOrSkip(request);
    await apiPlace(
      request,
      session.token,
      "library",
      libBook!.id,
      libBook!.title,
    );
    await apiPlace(
      request,
      session.token,
      "reading_pile",
      pileBook!.id,
      pileBook!.title,
    );
    await apiPlace(
      request,
      session.token,
      "wishlist",
      wishBook!.id,
      wishBook!.title,
    );
    await apiPlace(
      request,
      session.token,
      "antilibrary",
      antiBook!.id,
      antiBook!.title,
    );
    await injectSession(page, session);

    // Library — Softened → wear suffix present.
    await gotoShelf(page, "library");
    const aLib = await ariaLabelOf(spineEl(page, libBook!.id));
    expect(aLib, "reading the real Library spine").toContain(libBook!.title);
    expect(aLib).toContain(WEAR_SUFFIX);

    // Wish List — Pristine → no wear suffix (the title anchor makes the negative
    // assertion non-vacuous even though owner-privacy appends ", hidden …").
    await gotoShelf(page, "wishlist");
    const aWish = await ariaLabelOf(spineEl(page, wishBook!.id));
    expect(aWish, "reading the real Wish List spine").toContain(
      wishBook!.title,
    );
    expect(aWish).not.toContain(WEAR_SUFFIX);

    // AntiLibrary — Pristine → no wear suffix.
    await gotoShelf(page, "antilibrary");
    const aAnti = await ariaLabelOf(spineEl(page, antiBook!.id));
    expect(aAnti, "reading the real AntiLibrary spine").toContain(
      antiBook!.title,
    );
    expect(aAnti).not.toContain(WEAR_SUFFIX);

    // Reading Pile — Softened → wear suffix present. The pile uses a different
    // DOM (.book-pile, no #spine-<id>), so match the spine by its accessible name.
    await gotoShelf(page, "reading_pile");
    const pileSpine = page
      .locator(".book-pile")
      .getByLabel(`Book: ${pileBook!.title} by`, { exact: false });
    const aPile = await ariaLabelOf(pileSpine);
    expect(aPile, "reading the real Reading Pile spine").toContain(
      pileBook!.title,
    );
    expect(aPile).toContain(WEAR_SUFFIX);
  });

  test("a Softened shelf spine carries a muted worn filter a Pristine one lacks", async ({
    page,
    request,
  }) => {
    // Issue #288: wear is visible, not just audible. A Library (Softened) spine
    // gets the .book--softened treatment — a `filter` on its .book__spine face
    // (saturate/brightness) plus a corner-wear vignette — while a Wish List
    // (Pristine) spine gets none. We read the computed `filter` on the spine
    // face: Softened resolves to a non-"none" filter string, Pristine to "none".
    const all = await fetchAllCatalogue(request);
    const [libBook, wishBook] = lookup(all, [
      "The Name of the Rose", // Library — Softened
      "The Idiot", // Wish List — Pristine
    ]);
    assertSeedOrSkip(
      libBook !== null && wishBook !== null,
      "wear-CSS test needs The Name of the Rose (Library) and The Idiot (Wish List)",
    );

    const session = await mintOrSkip(request);
    await apiPlace(
      request,
      session.token,
      "library",
      libBook!.id,
      libBook!.title,
    );
    await apiPlace(
      request,
      session.token,
      "wishlist",
      wishBook!.id,
      wishBook!.title,
    );
    await injectSession(page, session);

    // Softened (Library): the spine face carries a real, non-"none" filter.
    await gotoShelf(page, "library");
    const libSpineFace = page.locator(
      `#spine-${libBook!.id} [data-testid="book-spine"] .book__spine`,
    );
    await expect(libSpineFace).toBeAttached({ timeout: 10000 });
    const libFilter = await libSpineFace.evaluate(
      (e) => getComputedStyle(e as HTMLElement).filter,
    );
    expect(
      libFilter,
      "Softened (Library) spine has a muted worn filter",
    ).not.toBe("none");
    expect(libFilter).toContain("saturate");

    // Pristine (Wish List): the same spine face carries no filter.
    await gotoShelf(page, "wishlist");
    const wishSpineFace = page.locator(
      `#spine-${wishBook!.id} [data-testid="book-spine"] .book__spine`,
    );
    await expect(wishSpineFace).toBeAttached({ timeout: 10000 });
    const wishFilter = await wishSpineFace.evaluate(
      (e) => getComputedStyle(e as HTMLElement).filter,
    );
    expect(wishFilter, "Pristine (Wish List) spine has no wear filter").toBe(
      "none",
    );

    // The distinction is real, not a coincidence of equal values.
    expect(libFilter).not.toBe(wishFilter);
  });

  test("each spine exposes its title, page count, and list semantics", async ({
    page,
    request,
  }) => {
    const all = await fetchAllCatalogue(request);
    const [b] = lookup(all, ["The Name of the Rose"]); // 536 pages
    assertSeedOrSkip(
      b !== null,
      "aria-content test needs The Name of the Rose",
    );
    expect((b as CatBook).pageCount).not.toBeNull();

    const session = await mintOrSkip(request);
    await apiPlace(request, session.token, "library", b!.id, b!.title);
    await injectSession(page, session);
    await gotoShelf(page, "library");

    const aria = await ariaLabelOf(spineEl(page, b!.id));
    expect(aria).toContain(b!.title);
    expect(aria).toContain(`${b!.pageCount} pages`);

    // role="listitem" on the spine button; role="list" on the shelf-row
    // container that holds it (extends bookshelf.spec.ts, which asserts the
    // roles on the shared suite user, by tying them to a specific known book).
    const button = page.locator(`#spine-${b!.id}`);
    await expect(button).toHaveAttribute("role", "listitem");
    const container = page.locator(".shelf-row__books", {
      has: page.locator(`#spine-${b!.id}`),
    });
    await expect(container).toHaveAttribute("role", "list");
  });

  test("a populated shelf renders at least two distinct spine textures", async ({
    page,
    request,
  }) => {
    const all = await fetchAllCatalogue(request);
    const found = lookup(all, WIDTH_TITLES);
    assertSeedOrSkip(
      found.every((b) => b !== null),
      `texture-variety test needs seeded books: ${WIDTH_TITLES.join(", ")}`,
    );
    const books = found as CatBook[];

    const session = await mintOrSkip(request);
    for (const b of books) {
      await apiPlace(request, session.token, "library", b.id, b.title);
    }
    await injectSession(page, session);
    await gotoShelf(page, "library");

    // Wait for our specific books (not a global count) before reading textures.
    for (const b of books) {
      await expect(spineEl(page, b.id)).toBeAttached({ timeout: 10000 });
    }
    const backgrounds = await page
      .locator(".book__spine")
      .evaluateAll((els) =>
        els.map((e) => getComputedStyle(e as HTMLElement).backgroundImage),
      );
    const textures = new Set(backgrounds.filter((bg) => bg && bg !== "none"));
    expect(
      backgrounds.length,
      "all five placed spines rendered",
    ).toBeGreaterThanOrEqual(5);
    expect(
      textures.size,
      "shelf uses more than one spine texture",
    ).toBeGreaterThanOrEqual(2);
  });

  test("a book the owner has written about shows a bookmark ribbon; one without does not (US-1.3.2, #287)", async ({
    page,
    request,
  }) => {
    // Two public books placed on the SAME Library shelf by one minted user, only
    // the first given a visible blog-post association. The ribbon (a `.book__ribbon`
    // child) and the ", with your notes" aria suffix must appear on the first and
    // NOT the second — proving the has_user_writing flag flows through the payload
    // and Components.Spine into the DOM per placement, not per shelf.
    const all = await fetchAllCatalogue(request);
    const [written, plain] = lookup(all, ["The Name of the Rose", "The Idiot"]);
    assertSeedOrSkip(
      written !== null && plain !== null,
      "ribbon test needs The Name of the Rose and The Idiot",
    );

    const session = await mintOrSkip(request);
    await apiPlace(
      request,
      session.token,
      "library",
      written!.id,
      written!.title,
    );
    await apiPlace(request, session.token, "library", plain!.id, plain!.title);
    // Only the first book gets a visible writing association.
    await seedBookWriting(request, session.email, written!.id);

    await injectSession(page, session);
    await gotoShelf(page, "library");

    // Written-about book: the accessible name carries ", with your notes"
    // (anchored by the title so the substring assertion can't pass against a
    // wrong/empty label), and a `.book__ribbon` child is present.
    const writtenAria = await ariaLabelOf(spineEl(page, written!.id));
    expect(writtenAria, "reading the written-about spine").toContain(
      written!.title,
    );
    expect(writtenAria).toContain(", with your notes");
    const ribbon = page.locator(`#spine-${written!.id} .book__ribbon`);
    await expect(
      ribbon,
      "written-about spine renders a bookmark ribbon",
    ).toHaveCount(1);
    // Not a phantom node: the `.book__ribbon` rule actually matched (its
    // signature `position: absolute` overrides the default `static`) and the
    // element is laid out (non-zero box), so the ribbon is genuinely visible —
    // the same computed-style proof #288 uses for the wear filter.
    const ribbonStyle = await ribbon.evaluate((e) => {
      const cs = getComputedStyle(e as HTMLElement);
      const r = (e as HTMLElement).getBoundingClientRect();
      return {
        position: cs.position,
        display: cs.display,
        w: r.width,
        h: r.height,
      };
    });
    expect(ribbonStyle.position, "ribbon CSS rule matched").toBe("absolute");
    expect(ribbonStyle.display).not.toBe("none");
    expect(ribbonStyle.w, "ribbon has a rendered width").toBeGreaterThan(0);
    expect(ribbonStyle.h, "ribbon has a rendered height").toBeGreaterThan(0);

    // Plain book on the SAME shelf: no ribbon and no notes suffix. The positive
    // title read first makes both negatives non-vacuous — a wrong selector would
    // fail the title assertion loudly rather than let the negatives pass empty.
    const plainAria = await ariaLabelOf(spineEl(page, plain!.id));
    expect(plainAria, "reading the un-written spine").toContain(plain!.title);
    expect(plainAria).not.toContain(", with your notes");
    await expect(
      page.locator(`#spine-${plain!.id} .book__ribbon`),
      "un-written spine renders no bookmark ribbon",
    ).toHaveCount(0);
  });
});
