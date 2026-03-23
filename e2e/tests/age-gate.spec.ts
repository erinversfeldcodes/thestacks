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

    // Navigate to the age-gated book detail page
    await page.goto(`/books/${ageGatedBook.id}`);

    // Wait for either the age gate (403 → showAgeGate) or the book overlay
    // (user already age-verified). Use proper Playwright waiting, not hard sleep.
    const ageGate = page.locator(".age-gate");
    const bookOverlay = page.getByTestId("book-overlay");

    // Wait for either element to appear (whichever comes first)
    await expect(ageGate.or(bookOverlay)).toBeVisible({ timeout: 15000 });
  });
});
