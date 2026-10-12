import { test, expect } from "@playwright/test";

/**
 * Browser E2E for the business opt-out's front door.
 *
 * The form at /listing-removal has worked for some time. What it lacked was a
 * way in: its only inbound link lived on a page that is not routed, so the form
 * was reachable by typed URL and by nothing else. A form nobody can navigate to
 * is not an opt-out, whatever its unit tests say — which is why the assertion
 * that matters here is the *journey*, not the form.
 *
 * Anonymous throughout, and deliberately so: the story's whole point is that a
 * shop owner who never asked to be listed does not have to make an account in
 * order to leave.
 */
test.describe("Business opt-out is reachable without typing a URL", () => {
  test.use({ storageState: { cookies: [], origins: [] } });

  test("anon: FAQ → the removal form", async ({ page }) => {
    await page.goto("/faq");

    const question = page.getByTestId("faq-question-business-listings");
    await question.scrollIntoViewIfNeeded();
    await expect(question).toBeVisible();
    await expect(question).toContainText("My business is listed here");

    // The answer must carry the link, not merely describe the form — describing
    // it is what the docs already did while the page stayed unreachable.
    await question.locator('a[href="/listing-removal"]').click();

    await expect(page).toHaveURL(/\/listing-removal$/);
    await expect(page.getByTestId("removal-url")).toBeVisible();
    await expect(page.getByTestId("removal-email")).toBeVisible();
    await expect(page.getByTestId("removal-submit")).toBeVisible();
  });

  test("anon: the form is usable logged-out, and says what it will do", async ({
    page,
  }) => {
    await page.goto("/listing-removal");

    // No auth wall, no redirect to /login.
    await expect(page).toHaveURL(/\/listing-removal$/);
    await expect(page.getByTestId("removal-url")).toBeVisible();

    // Submit stays disabled until the two things the page can check are given,
    // so a would-be requester is not bounced by the server for a blank field.
    const submit = page.getByTestId("removal-submit");
    await expect(submit).toBeDisabled();

    await page.getByTestId("removal-url").fill("https://booklounge.co.za");
    await page.getByTestId("removal-email").fill("owner@booklounge.co.za");
    await expect(submit).toBeEnabled();
  });

  test("anon: the FAQ answer is deep-linkable by its published id", async ({
    page,
  }) => {
    await page.goto("/faq#business-listings");

    const question = page.locator("#business-listings");
    await expect(question).toBeVisible();
    await expect(question).toContainText("no account, no sign-in");
  });
});
