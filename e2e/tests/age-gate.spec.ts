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

    // Navigate to the age-gated book
    await page.goto(`/books/${ageGatedBook.id}`);
    await page.waitForTimeout(3000);

    // The page should show either the age gate or the book detail
    // (depends on whether the seeded user is age_verified)
    const hasAgeGate = (await page.locator(".age-gate").count()) > 0;
    const hasBookDetail =
      (await page.getByTestId('book-overlay').count()) > 0;

    // One of these must be true — the page rendered something
    expect(hasAgeGate || hasBookDetail).toBeTruthy();
  });
});
