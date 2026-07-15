import { test, expect } from "@playwright/test";
import { suiteAuthFile, apiCallFromPage } from "./helpers";

/**
 * Age-gated content — DETERMINISTIC browser drive (#226 item 3).
 *
 * The old single assertion (`.age-gate` OR `.book-detail`) proved nothing: it
 * passed whatever the seeded user's `age_verified` state happened to be. This
 * spec instead OWNS that state — it drives the age-gate suite user through both
 * sides of the gate by setting `age_verified` via the API and reloading:
 *
 *   unverified → the age gate is shown and the book content is suppressed;
 *   verified   → the same book renders its content and the gate is gone.
 *
 * A single serial test toggles the flag so the two phases can't race under
 * `fullyParallel`, and it restores `age_verified: false` at the end so the
 * suite user is left in a known state. Pinned to a KNOWN age-gated seed book
 * (by ISBN) so the gate trigger is deterministic, not "whatever sorts first".
 */

// "Demons" (Dostoevsky) — seeded as age_gated (apps/core/priv/repo/seeds.exs).
const AGE_GATED_ISBN = "9780140449242";

test.describe("Age-gated content (deterministic gate ↔ content)", () => {
  test.use({ storageState: suiteAuthFile("age-gate") });

  test("the age gate hides content until the viewer is age-verified", async ({
    page,
  }) => {
    // Land in-app so localStorage (the bearer token) is available to the helpers.
    await page.goto("/library");

    // Resolve the pinned age-gated book id. The catalogue includes age-gated
    // books for an authenticated browser, so this find is stable.
    const { data } = await apiCallFromPage(
      page,
      "GET",
      "/api/catalogue?per_page=200"
    );
    const ageGatedBook = ((data as { books?: Array<{ id: string; primary_edition?: { isbn?: string } }> }).books ?? []).find(
      (b) => b.primary_edition?.isbn === AGE_GATED_ISBN
    );
    expect(
      ageGatedBook,
      `catalogue must contain the age-gated seed book ISBN ${AGE_GATED_ISBN}`
    ).toBeDefined();
    const bookId = (ageGatedBook as { id: string }).id;

    const ageGate = page.locator(".age-gate");
    const bookTitle = page.getByTestId("book-title");

    // ── UNVERIFIED — the gate is shown, the content is suppressed ─────────────
    const unset = await apiCallFromPage(page, "PUT", "/api/settings/age_verification", {
      age_verified: false,
    });
    expect(unset.status).toBe(200);

    // Direct navigation renders PageBookDetail; an age-gated book to an
    // unverified viewer 403s → showAgeGate, so `.age-gate` is shown and the
    // book title (only in the content branch) is absent.
    await page.goto(`/books/${bookId}`);
    await expect(ageGate).toBeVisible({ timeout: 15000 });
    await expect(bookTitle).toHaveCount(0);

    // ── VERIFIED — the same book now renders its content, gate gone ───────────
    const set = await apiCallFromPage(page, "PUT", "/api/settings/age_verification", {
      age_verified: true,
    });
    expect(set.status).toBe(200);

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
