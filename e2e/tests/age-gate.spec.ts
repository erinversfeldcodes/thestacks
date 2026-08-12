import { test, expect } from "@playwright/test";
import { suiteAuthFile, suiteEmail, apiCallFromPage } from "./helpers";

/**
 * Age-gated content — DETERMINISTIC browser drive.
 *
 * The old single assertion (`.age-gate` OR `.book-detail`) proved nothing: it
 * passed whatever the seeded user's `age_verified` state happened to be. This
 * spec instead OWNS that state — it drives the age-gate suite user through both
 * sides of the gate by setting `age_verified` via the test helper and reloading:
 *
 *   unverified → the book is HIDDEN from the catalogue listing AND a
 *                direct URL shows the `.age-gate` block with content suppressed;
 *   verified   → the book APPEARS in the catalogue listing AND the same direct
 *                URL renders its content with the gate gone.
 *
 * age-verification is now PROVIDER-sourced, not self-declared — the old
 * `PUT /api/settings/age_verification` endpoint is gone. The suite instead flips
 * the suite user's `age_verified` via the STACKS_E2E_TEST_HELPERS-gated helper
 * `PUT /api/test/age-verification {email, verified}` (→ record_verification/3,
 * provider "e2e_test_helper"). Enforcement itself is flag-gated and ships dark in
 * prod: this suite only passes with AGE_GATING_ENABLED=true (set on the preview
 * stack + local test-e2e.sh).
 *
 * A single serial test toggles the flag so the phases can't race under
 * `fullyParallel`, and it restores `verified: false` at the end so the suite
 * user is left in a known state. Pinned to a KNOWN age-gated seed book (by ISBN)
 * so the gate trigger is deterministic, not "whatever sorts first".
 */

const AGE_GATED_ISBN = "9780140449242";

const SUITE_EMAIL = suiteEmail("age-gate");

type CatalogueBook = { id: string; primary_edition?: { isbn?: string } };

test.describe("Age-gated content (deterministic gate ↔ content)", () => {
  test.use({ storageState: suiteAuthFile("age-gate") });

  test("the age gate hides the book from the catalogue and detail until verified", async ({
    page,
  }) => {
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

    const setAgeVerified = (verified: boolean) =>
      apiCallFromPage(page, "PUT", "/api/test/age-verification", {
        email: SUITE_EMAIL,
        verified,
      });

    const setVerified = await setAgeVerified(true);
    expect(setVerified.status).toBe(200);

    const ageGatedBook = await findInCatalogue();
    expect(
      ageGatedBook,
      `a verified viewer's catalogue must contain the age-gated seed book ISBN ${AGE_GATED_ISBN}`
    ).toBeDefined();
    const bookId = (ageGatedBook as CatalogueBook).id;

    const ageGate = page.locator(".age-gate");
    const bookTitle = page.getByTestId("book-title");

    const unset = await setAgeVerified(false);
    expect(unset.status).toBe(200);

    expect(
      await findInCatalogue(),
      "unverified viewer's catalogue must NOT contain the age-gated book"
    ).toBeUndefined();

    await page.goto(`/books/${bookId}`);
    await expect(ageGate).toBeVisible({ timeout: 15000 });
    await expect(bookTitle).toHaveCount(0);

    const set = await setAgeVerified(true);
    expect(set.status).toBe(200);

    expect(
      await findInCatalogue(),
      "verified viewer's catalogue must contain the age-gated book again"
    ).toBeDefined();

    await page.goto(`/books/${bookId}`);
    await expect(bookTitle).toBeVisible({ timeout: 15000 });
    await expect(ageGate).toHaveCount(0);

    await setAgeVerified(false);
  });
});
