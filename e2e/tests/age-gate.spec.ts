import { test, expect } from "@playwright/test";
import { suiteAuthFile, apiCallFromPage } from "./helpers";

/**
 * Age-gated content — DETERMINISTIC browser drive (#226 item 3, extended #229).
 *
 * The old single assertion (`.age-gate` OR `.book-detail`) proved nothing: it
 * passed whatever the seeded user's `age_verified` state happened to be. This
 * spec instead OWNS that state — it drives the age-gate suite user through both
 * sides of the gate by setting `age_verified` via the API and reloading:
 *
 *   unverified → the book is HIDDEN from the catalogue listing (#229) AND a
 *                direct URL shows the `.age-gate` block with content suppressed;
 *   verified   → the book APPEARS in the catalogue listing AND the same direct
 *                URL renders its content with the gate gone.
 *
 * A single serial test toggles the flag so the phases can't race under
 * `fullyParallel`, and it restores `age_verified: false` at the end so the
 * suite user is left in a known state. Pinned to a KNOWN age-gated seed book
 * (by ISBN) so the gate trigger is deterministic, not "whatever sorts first".
 */

// "Demons" (Dostoevsky) — seeded as age_gated (apps/core/priv/repo/seeds.exs).
const AGE_GATED_ISBN = "9780140449242";

type CatalogueBook = { id: string; primary_edition?: { isbn?: string } };

test.describe("Age-gated content (deterministic gate ↔ content)", () => {
  test.use({ storageState: suiteAuthFile("age-gate") });

  test("the age gate hides the book from the catalogue and detail until verified", async ({
    page,
  }) => {
    // Land in-app so localStorage (the bearer token) is available to the helpers.
    await page.goto("/library");

    const findInCatalogue = async (): Promise<CatalogueBook | undefined> => {
      const { data } = await apiCallFromPage(
        page,
        "GET",
        "/api/catalogue?per_page=200"
      );
      return ((data as { books?: CatalogueBook[] }).books ?? []).find(
        (b) => b.primary_edition?.isbn === AGE_GATED_ISBN
      );
    };

    // #229: the catalogue now HIDES age-gated books from an unverified viewer, so
    // we resolve the pinned book id WHILE verified — the id-lookup can no longer
    // rely on the (now-closed) leak that exposed age-gated books to any authed user.
    const setVerified = await apiCallFromPage(
      page,
      "PUT",
      "/api/settings/age_verification",
      { age_verified: true }
    );
    expect(setVerified.status).toBe(200);

    const ageGatedBook = await findInCatalogue();
    expect(
      ageGatedBook,
      `a verified viewer's catalogue must contain the age-gated seed book ISBN ${AGE_GATED_ISBN}`
    ).toBeDefined();
    const bookId = (ageGatedBook as CatalogueBook).id;

    const ageGate = page.locator(".age-gate");
    const bookTitle = page.getByTestId("book-title");

    // ── UNVERIFIED — hidden from the listing, gated on the detail ─────────────
    const unset = await apiCallFromPage(page, "PUT", "/api/settings/age_verification", {
      age_verified: false,
    });
    expect(unset.status).toBe(200);

    // #229: the age-gated book is OMITTED from the catalogue listing for an
    // authenticated-but-unverified viewer (as it already is anonymously).
    expect(
      await findInCatalogue(),
      "unverified viewer's catalogue must NOT contain the age-gated book"
    ).toBeUndefined();

    // Direct navigation still renders PageBookDetail; an age-gated book to an
    // unverified viewer 403s → showAgeGate, so `.age-gate` is shown and the
    // book title (only in the content branch) is absent.
    await page.goto(`/books/${bookId}`);
    await expect(ageGate).toBeVisible({ timeout: 15000 });
    await expect(bookTitle).toHaveCount(0);

    // ── VERIFIED — revealed in the listing, content on the detail ────────────
    const set = await apiCallFromPage(page, "PUT", "/api/settings/age_verification", {
      age_verified: true,
    });
    expect(set.status).toBe(200);

    // #229: after verification the book re-appears in the catalogue listing.
    expect(
      await findInCatalogue(),
      "verified viewer's catalogue must contain the age-gated book again"
    ).toBeDefined();

    // Reload so the SPA re-inits with the now-verified session and the
    // book-detail fetch returns 200 (content branch).
    await page.goto(`/books/${bookId}`);
    await expect(bookTitle).toBeVisible({ timeout: 15000 });
    await expect(ageGate).toHaveCount(0);

    // ── Restore the suite user to a known (unverified) state ──────────────────
    await apiCallFromPage(page, "PUT", "/api/settings/age_verification", {
      age_verified: false,
    });
  });
});
