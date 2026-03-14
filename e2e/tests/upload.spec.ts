import path from "path";
import { test, expect } from "@playwright/test";

const DEV_EMAIL = "owner@thestacks.app";
const DEV_PASSWORD = "dev-password-123";

// The vision pipeline runs classify + extract on VisionModel (A10G GPU) then
// resolves an ISBN via Open Library. Allow 5 minutes for cold-start + inference.
const PIPELINE_TIMEOUT = 300_000;

async function signIn(page: import("@playwright/test").Page) {
  // Retry login up to 3 times — rate limiting or transient errors can cause
  // 401/429 on preview deploys with many sequential tests.
  for (let attempt = 1; attempt <= 3; attempt++) {
    await page.goto("/login");
    await page.fill('input[id="email"]', DEV_EMAIL);
    await page.fill('input[id="password"]', DEV_PASSWORD);
    await page.click("button.login-form__submit");
    try {
      await page.waitForURL("/", { timeout: 15_000 });
      return; // success
    } catch {
      if (attempt < 3) {
        // Wait for rate limit window to clear before retrying
        await page.waitForTimeout(10_000);
      }
    }
  }
  // Final attempt without catch — let it throw on failure
  await page.goto("/login");
  await page.fill('input[id="email"]', DEV_EMAIL);
  await page.fill('input[id="password"]', DEV_PASSWORD);
  await page.click("button.login-form__submit");
  await page.waitForURL("/", { timeout: 60_000 });
}

test.describe("Upload pipeline — barcode pre-pass", () => {
  test(
    "identifies The Name of the Rose from barcode_isbn_clean.jpg via local OCR",
    async ({ page }) => {
      // The barcode pre-pass should short-circuit the VLM entirely.
      // 60s is generous — the pre-pass itself takes milliseconds; the rest
      // is Open Library lookup + Elm polling.
      test.setTimeout(60_000);

      await signIn(page);

      await page.click('a[href="/upload"]');
      await page.waitForURL("/upload");

      const fileChooserPromise = page.waitForEvent("filechooser");
      await page.click("button.btn--primary");
      const fileChooser = await fileChooserPromise;
      await fileChooser.setFiles(
        path.join(__dirname, "../../images/barcode_isbn_clean.jpg")
      );

      await expect(page.locator(".upload-area__loading p")).toHaveText(
        "Identifying your book...",
        { timeout: 30_000 }
      );

      await expect(page.locator(".upload-result--identified")).toBeVisible({
        timeout: 60_000,
      });

      const result = page.locator(".upload-result--identified");
      await expect(result).toContainText("Name of the Rose", {
        ignoreCase: true,
      });
      await expect(result).toContainText("Eco");

      const viewBookLink = result.locator('a[href^="/books/"]');
      await expect(viewBookLink).toBeVisible();
    }
  );
});

test.describe("Upload pipeline", () => {
  test(
    "identifies multiple books from screenshot_mixed_text.jpg",
    async ({ page }) => {
      test.setTimeout(PIPELINE_TIMEOUT);

      await signIn(page);

      await page.click('a[href="/upload"]');
      await page.waitForURL("/upload");

      const fileChooserPromise = page.waitForEvent("filechooser");
      await page.click("button.btn--primary");
      const fileChooser = await fileChooserPromise;
      await fileChooser.setFiles(
        path.join(__dirname, "../../images/screenshot_mixed_text.jpg")
      );

      await expect(page.locator(".upload-area__loading p")).toHaveText(
        "Identifying your book...",
        { timeout: 60_000 }
      );

      await expect(page.locator(".upload-result--identified")).toBeVisible({
        timeout: PIPELINE_TIMEOUT,
      });

      // All five books should appear in the results.
      const result = page.locator(".upload-result--identified");
      await expect(result).toContainText("Kite Runner");
      await expect(result).toContainText("Hosseini");
      await expect(result).toContainText("Klara");
      await expect(result).toContainText("Ishiguro");
      await expect(result).toContainText("Idiot");
      await expect(result).toContainText("Batuman");
      await expect(result).toContainText("Things I Don't Want to Know", { ignoreCase: true });
      await expect(result).toContainText("Levy");
      await expect(result).toContainText("Cost of Living", { ignoreCase: true });

      // Each identified book should have a "View Book" link.
      const viewBookLinks = result.locator('a[href^="/books/"]');
      await expect(viewBookLinks).toHaveCount(5);
    }
  );

  test(
    "identifies Train to Crystal City from screenshot_image_reversed_and_cut_off.jpg",
    async ({ page }) => {
      test.setTimeout(PIPELINE_TIMEOUT);

      await signIn(page);

      await page.click('a[href="/upload"]');
      await page.waitForURL("/upload");

      const fileChooserPromise = page.waitForEvent("filechooser");
      await page.click("button.btn--primary");
      const fileChooser = await fileChooserPromise;
      await fileChooser.setFiles(
        path.join(__dirname, "../../images/screenshot_image_reversed_and_cut_off.jpg")
      );

      await expect(page.locator(".upload-area__loading p")).toHaveText(
        "Identifying your book...",
        { timeout: 60_000 }
      );

      await expect(page.locator(".upload-result--identified")).toBeVisible({
        timeout: PIPELINE_TIMEOUT,
      });

      await expect(page.locator(".upload-result--identified")).toContainText(
        "Crystal City"
      );
      await expect(page.locator(".upload-result--identified")).toContainText(
        "Russell"
      );

      const viewBookLink = page.locator('.upload-result--identified a[href^="/books/"]');
      await expect(viewBookLink).toBeVisible();
    }
  );

  test(
    "identifies Flyboys from screenshot_image_reversed.jpg",
    async ({ page }) => {
      test.setTimeout(PIPELINE_TIMEOUT);

      await signIn(page);

      await page.click('a[href="/upload"]');
      await page.waitForURL("/upload");

      const fileChooserPromise = page.waitForEvent("filechooser");
      await page.click("button.btn--primary");
      const fileChooser = await fileChooserPromise;
      await fileChooser.setFiles(
        path.join(__dirname, "../../images/screenshot_image_reversed.jpg")
      );

      await expect(page.locator(".upload-area__loading p")).toHaveText(
        "Identifying your book...",
        { timeout: 60_000 }
      );

      await expect(page.locator(".upload-result--identified")).toBeVisible({
        timeout: PIPELINE_TIMEOUT,
      });

      await expect(page.locator(".upload-result--identified")).toContainText(
        "Flyboys"
      );
      await expect(page.locator(".upload-result--identified")).toContainText(
        "Bradley"
      );

      const viewBookLink = page.locator('.upload-result--identified a[href^="/books/"]');
      await expect(viewBookLink).toBeVisible();
    }
  );

  test(
    "identifies Born Again Bodies from screenshot_mildly_obscured.jpg",
    async ({ page }) => {
      test.setTimeout(PIPELINE_TIMEOUT);

      await signIn(page);

      // Navigate via the SPA link to keep Elm's in-memory auth state.
      await page.click('a[href="/upload"]');
      await page.waitForURL("/upload");

      // Trigger the file chooser via the "Choose Photo" button.
      const fileChooserPromise = page.waitForEvent("filechooser");
      await page.click("button.btn--primary");
      const fileChooser = await fileChooserPromise;
      await fileChooser.setFiles(
        path.join(__dirname, "../../images/screenshot_mildly_obscured.jpg")
      );

      // Upload is accepted; spinner switches to "Identifying your book..."
      await expect(page.locator(".upload-area__loading p")).toHaveText(
        "Identifying your book...",
        { timeout: 60_000 }
      );

      // Wait for the vision pipeline to complete and the result to render.
      await expect(page.locator(".upload-result--identified")).toBeVisible({
        timeout: PIPELINE_TIMEOUT,
      });

      // Title and author should match the book in the image.
      await expect(page.locator(".upload-result--identified")).toContainText(
        "Born Again Bodies"
      );
      await expect(page.locator(".upload-result--identified")).toContainText(
        "Griffith"
      );

      // "View Book" link should be present and point to a book detail page.
      const viewBookLink = page.locator('.upload-result--identified a[href^="/books/"]');
      await expect(viewBookLink).toBeVisible();
    }
  );
});
