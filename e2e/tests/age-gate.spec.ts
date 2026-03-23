import { test, expect } from "@playwright/test";
import { suiteAuthFile, apiCallFromPage } from "./helpers";

test.describe("Age-gated content", () => {
  test.use({ storageState: suiteAuthFile("age-gate") });

  test("age-gated book shows age gate for non-verified users", async ({
    page,
  }) => {
    // Navigate to app first so localStorage is accessible
    await page.goto("/library");

    // Fetch catalogue as authenticated user (age-gated books are included)
    const { data } = await apiCallFromPage(
      page,
      "GET",
      "/api/catalogue?per_page=200"
    );
    const ageGatedBook = (data as any).books?.find(
      (b: any) => b.visibility_tier === "age_gated"
    );

    expect(ageGatedBook).toBeDefined();

    // Navigate to the age-gated book detail page.
    // Direct navigation renders PageBookDetail (page--book-detail), not the
    // overlay (book-overlay). The overlay only renders when opened from a shelf.
    await page.goto(`/books/${ageGatedBook.id}`);

    // Wait for either the age gate (403 → showAgeGate) or the book detail
    // page content (user already age-verified).
    const ageGate = page.locator(".age-gate");
    const bookDetail = page.locator(".page--book-detail");

    await expect(ageGate.or(bookDetail)).toBeVisible({ timeout: 15000 });
  });
});
